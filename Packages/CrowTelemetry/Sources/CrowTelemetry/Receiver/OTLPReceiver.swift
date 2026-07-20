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
                    let payload = try JSONDecoder().decode(OTLPMetricsPayload.self, from: request.body)
                    let affectedSessions = await self.processMetrics(payload, database: db)
                    self.sendResponse(HTTPResponse.ok(), on: connection)
                    for sessionID in affectedSessions {
                        await onData(sessionID)
                    }
                } catch {
                    NSLog("[OTLPReceiver] Metrics decode error: %@", error.localizedDescription)
                    self.sendResponse(HTTPResponse.badRequest(message: "Invalid metrics payload"), on: connection)
                }
            }

        case "/v1/logs":
            Task {
                do {
                    let payload = try JSONDecoder().decode(OTLPLogsPayload.self, from: request.body)
                    let affectedSessions = await self.processLogs(payload, database: db)
                    self.sendResponse(HTTPResponse.ok(), on: connection)
                    for sessionID in affectedSessions {
                        await onData(sessionID)
                    }
                } catch {
                    NSLog("[OTLPReceiver] Logs decode error: %@", error.localizedDescription)
                    self.sendResponse(HTTPResponse.badRequest(message: "Invalid logs payload"), on: connection)
                }
            }

        default:
            sendResponse(HTTPResponse.notFound(), on: connection)
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
                    let eventName = record.eventName ?? "unknown"
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
