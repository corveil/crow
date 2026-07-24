import Foundation
import Network
import CrowCore

/// Lightweight OTLP HTTP/JSON receiver using Network.framework.
///
/// Listens on localhost for OTLP metric and log export requests from Claude Code
/// and stores them via `TelemetryDatabase`.
public final class OTLPReceiver: Sendable {
    private let port: UInt16
    private let listener: NWListener
    private let database: TelemetryDatabase
    private let queue = DispatchQueue(label: "com.corveil.crow.otlp-receiver")
    private let decodeFailures = FailureThrottle(interval: 60)

    /// Callback invoked on the main actor when new data arrives for a Crow session.
    /// The UUID is the Crow session ID.
    public let onDataReceived: @Sendable @MainActor (UUID) -> Void

    public init(
        port: UInt16,
        database: TelemetryDatabase,
        onDataReceived: @escaping @Sendable @MainActor (UUID) -> Void
    ) throws {
        self.port = port
        self.database = database
        self.onDataReceived = onDataReceived

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        params.acceptLocalOnly = true

        self.listener = try NWListener(using: params)
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("[OTLPReceiver] Listening on localhost:%d", self?.port ?? 0)
            case .failed(let error):
                NSLog("[OTLPReceiver] Listener failed: %@", error.localizedDescription)
            case .cancelled:
                NSLog("[OTLPReceiver] Listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(on: connection, buffer: Data())
    }

    private func receiveData(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in

            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            if let error {
                NSLog("[OTLPReceiver] Receive error: %@", error.localizedDescription)
                connection.cancel()
                return
            }

            // Try to parse
            switch HTTPParser.parse(accumulated) {
            case .complete(let request):
                self.handleRequest(request, connection: connection)
            case .needsMore:
                if isComplete {
                    // Connection closed before complete request
                    connection.cancel()
                } else {
                    self.receiveData(on: connection, buffer: accumulated)
                }
            case .error(let message):
                NSLog("[OTLPReceiver] Parse error: %@", message)
                self.sendResponse(HTTPResponse.badRequest(message: message), on: connection)
            }
        }
    }

    private func handleRequest(_ request: HTTPRequest, connection: NWConnection) {
        guard request.method == "POST" else {
            sendResponse(HTTPResponse.badRequest(message: "Only POST supported"), on: connection)
            return
        }

        let db = self.database
        let onData = self.onDataReceived

        switch request.path {
        case "/v1/metrics":
            Task {
                do {
                    let payload = try self.decode(OTLPMetricsPayload.self, from: request)
                    let affectedSessions = await self.processMetrics(payload, database: db)
                    self.sendResponse(HTTPResponse.ok(), on: connection)
                    for sessionID in affectedSessions {
                        await onData(sessionID)
                    }
                } catch {
                    self.reportDecodeFailure(error, request: request)
                    self.sendResponse(HTTPResponse.badRequest(message: "Invalid metrics payload"), on: connection)
                }
            }

        case "/v1/logs":
            Task {
                do {
                    let payload = try self.decode(OTLPLogsPayload.self, from: request)
                    let affectedSessions = await self.processLogs(payload, database: db)
                    self.sendResponse(HTTPResponse.ok(), on: connection)
                    for sessionID in affectedSessions {
                        await onData(sessionID)
                    }
                } catch {
                    self.reportDecodeFailure(error, request: request)
                    self.sendResponse(HTTPResponse.badRequest(message: "Invalid logs payload"), on: connection)
                }
            }

        default:
            sendResponse(HTTPResponse.notFound(), on: connection)
        }
    }

    // MARK: - Decoding & Diagnostics

    /// Decode an OTLP payload, reporting any records tolerant decoding dropped.
    private func decode<T: Decodable>(_ type: T.Type, from request: HTTPRequest) throws -> T {
        let diagnostics = OTLPDecodeDiagnostics()
        let decoder = JSONDecoder()
        decoder.userInfo[.otlpDiagnostics] = diagnostics
        let payload = try decoder.decode(T.self, from: request.body)
        if let summary = diagnostics.summary {
            NSLog("[OTLPReceiver] %@: skipped malformed %@", request.path, summary)
        }
        return payload
    }

    /// Log a decode failure with enough context to identify the offending field.
    ///
    /// The bare `localizedDescription` of a `DecodingError` is the same
    /// "isn't in the correct format" string for every cause, which left the
    /// receiver undiagnosable (#823). The coding path pinpoints the field.
    /// Failures are throttled so a systematic mismatch cannot drown the log.
    private func reportDecodeFailure(_ error: Error, request: HTTPRequest) {
        guard let suppressed = decodeFailures.claim(request.path) else { return }

        var message = "[OTLPReceiver] \(request.path) decode failed: \(Self.describe(error))"
        message += "\n  content-type=\(request.header("Content-Type") ?? "-")"
        message += " content-length=\(request.header("Content-Length") ?? "-")"
        message += " transfer-encoding=\(request.header("Transfer-Encoding") ?? "-")"
        message += " content-encoding=\(request.header("Content-Encoding") ?? "-")"
        message += " bodybytes=\(request.body.count)"
        if suppressed > 0 {
            message += "\n  (\(suppressed) further failures suppressed since the last report)"
        }
        // Bodies carry account IDs, emails and event attributes, so the raw
        // prefix is opt-in; the coding path above is enough to diagnose shape.
        if Self.logRawBodies {
            let prefix = request.body.prefix(512)
            let text = String(decoding: prefix, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            message += "\n  body[0..<\(prefix.count)]: \(text)"
        }
        NSLog("%@", message)
    }

    private static var logRawBodies: Bool {
        ProcessInfo.processInfo.environment["CROW_TELEMETRY_LOG_RAW_BODIES"] == "1"
    }

    /// Render a `DecodingError` as case, coding path, and underlying reason.
    static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let rendered = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
            }.joined()
            let trimmed = rendered.hasPrefix(".") ? String(rendered.dropFirst()) : rendered
            return trimmed.isEmpty ? "<root>" : trimmed
        }

        guard let error = error as? DecodingError else {
            return "\(type(of: error)): \(error.localizedDescription)"
        }
        switch error {
        case let .typeMismatch(type, context):
            return "typeMismatch(\(type)) at \(path(context)) — \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "valueNotFound(\(type)) at \(path(context)) — \(context.debugDescription)"
        case let .keyNotFound(key, context):
            return "keyNotFound(\(key.stringValue)) at \(path(context)) — \(context.debugDescription)"
        case let .dataCorrupted(context):
            return "dataCorrupted at \(path(context)) — \(context.debugDescription)"
        @unknown default:
            return "DecodingError: \(error.localizedDescription)"
        }
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Payload Processing

    private func processMetrics(_ payload: OTLPMetricsPayload, database: TelemetryDatabase) async -> Set<UUID> {
        var affectedSessions = Set<UUID>()

        for resourceMetrics in payload.resourceMetrics {
            let crowSessionIDStr = resourceMetrics.resource?.crowSessionID
            guard let crowSessionIDStr, let crowSessionID = UUID(uuidString: crowSessionIDStr) else {
                continue
            }

            // Register session mapping if we have both IDs
            if let claudeSessionID = resourceMetrics.resource?.sessionID {
                await database.registerSessionMapping(
                    claudeSessionID: claudeSessionID,
                    crowSessionID: crowSessionID
                )
            }

            guard let scopeMetrics = resourceMetrics.scopeMetrics else { continue }

            for scope in scopeMetrics {
                guard let metrics = scope.metrics else { continue }
                for metric in metrics {
                    if let sum = metric.sum {
                        for point in sum.dataPoints ?? [] {
                            await database.insertMetric(
                                crowSessionID: crowSessionID,
                                metricName: metric.name,
                                value: point.numericValue,
                                attributesJSON: encodeAttributes(point.attributes),
                                timestampNs: point.timeUnixNano,
                                temporality: sum.temporality,
                                isMonotonic: sum.isMonotonic
                            )
                        }
                    } else if let gauge = metric.gauge {
                        for point in gauge.dataPoints ?? [] {
                            await database.insertMetric(
                                crowSessionID: crowSessionID,
                                metricName: metric.name,
                                value: point.numericValue,
                                attributesJSON: encodeAttributes(point.attributes),
                                timestampNs: point.timeUnixNano
                            )
                        }
                    }
                }
            }
            affectedSessions.insert(crowSessionID)
        }

        return affectedSessions
    }

    private func processLogs(_ payload: OTLPLogsPayload, database: TelemetryDatabase) async -> Set<UUID> {
        var affectedSessions = Set<UUID>()

        for resourceLogs in payload.resourceLogs {
            let crowSessionIDStr = resourceLogs.resource?.crowSessionID
            guard let crowSessionIDStr, let crowSessionID = UUID(uuidString: crowSessionIDStr) else {
                continue
            }

            if let claudeSessionID = resourceLogs.resource?.sessionID {
                await database.registerSessionMapping(
                    claudeSessionID: claudeSessionID,
                    crowSessionID: crowSessionID
                )
            }

            guard let scopeLogs = resourceLogs.scopeLogs else { continue }

            for scope in scopeLogs {
                guard let logRecords = scope.logRecords else { continue }
                for record in logRecords {
                    let eventName = record.resolvedEventName ?? "unknown"
                    let body = record.body?.asString
                    let attributesJSON = encodeAttributes(record.attributes)

                    await database.insertEvent(
                        crowSessionID: crowSessionID,
                        eventName: eventName,
                        body: body,
                        attributesJSON: attributesJSON,
                        severityNumber: record.severityNumber,
                        timestampNs: record.timeUnixNano
                    )
                }
            }
            affectedSessions.insert(crowSessionID)
        }

        return affectedSessions
    }

    private func encodeAttributes(_ attributes: [OTLPAttribute]?) -> String? {
        guard let attributes, !attributes.isEmpty else { return nil }
        var dict: [String: String] = [:]
        for attr in attributes {
            dict[attr.key] = attr.value.asString ?? ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Failure Throttling

/// Rate-limits a repeating failure to one report per `interval`, per key.
///
/// A systematic payload mismatch fires on every export (~every 5s per session),
/// which is how #823 drowned the daemon log. The first failure always reports
/// in full; later ones are counted and folded into the next report.
final class FailureThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var lastReported: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Claim the right to report a failure for `key`.
    ///
    /// - Returns: the number of failures suppressed since the last report, or
    ///   `nil` if this one should stay silent.
    func claim(_ key: String, now: Date = Date()) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        if let last = lastReported[key], now.timeIntervalSince(last) < interval {
            suppressed[key, default: 0] += 1
            return nil
        }
        lastReported[key] = now
        return suppressed.removeValue(forKey: key) ?? 0
    }
}
