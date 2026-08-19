import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of one transcript upload attempt, categorized so the collector knows
/// whether to record it done, skip it permanently, or retry later (CROW-1056).
public enum TranscriptUploadResult: Sendable, Equatable {
    /// 201 — stored.
    case created
    /// 409 — a transcript of this `(session, harness, kind)` already exists.
    /// Write-once is by design (corveil#2426); treat as an idempotent success so
    /// backfill re-runs converge.
    case alreadyExists
    /// 413 — over the server's size cap. Permanent for this body; don't retry.
    case tooLarge
    /// Any other non-retryable response (400/401/403/404/other 4xx). Permanent —
    /// retrying an auth/tenancy/validation error just hammers the endpoint.
    case rejected(status: Int)
    /// 5xx or a transport error. Transient — retry on a later sweep.
    case transient

    /// Whether the artifact is now stored (or already was).
    public var isSuccess: Bool { self == .created || self == .alreadyExists }

    /// Whether re-attempting can never succeed with the same body, so the
    /// collector should stop trying (records it and moves on).
    public var isPermanentFailure: Bool {
        switch self {
        case .tooLarge, .rejected: return true
        case .created, .alreadyExists, .transient: return false
        }
    }
}

/// Performs one HTTP request and returns its status code, or throws on a
/// transport error. Injected so the uploader is testable without a live server.
public protocol TranscriptUploadTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> Int
}

/// The default transport, backed by `URLSession`.
public struct URLSessionUploadTransport: TranscriptUploadTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func perform(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return http.statusCode
    }
}

/// Uploads a normalized session transcript to the Corveil session-artifact
/// endpoint (corveil#2426): `POST {baseURL}/api/crow-sessions/{sessionUID}/artifacts`.
///
/// Authenticated with the developer's own Corveil API key
/// (`Authorization: Bearer …`) — the server derives attribution from the key and
/// uploads to object storage itself, so **no AWS credential is on the laptop**.
/// Best-effort: one retry on a transient failure, then the caller records and
/// drops it. Never blocks or fails a session.
public struct TranscriptUploader: Sendable {
    private let transport: any TranscriptUploadTransport

    public init(transport: any TranscriptUploadTransport = URLSessionUploadTransport()) {
        self.transport = transport
    }

    /// Build the upload request. Pure and side-effect-free so the URL, query
    /// params, headers and body are unit-testable. Returns `nil` when `baseURL`
    /// is blank or unparseable, or the API key is blank.
    public static func makeRequest(
        baseURL: String,
        apiKey: String,
        sessionUID: String,
        harness: LogSyncHarness,
        kind: LogSyncArtifactKind,
        format: AgentLogFormat,
        transcript: NormalizedTranscript,
        metadata: LogSyncSessionMetadata,
        agentSessionID: String?
    ) -> URLRequest? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !trimmedKey.isEmpty else { return nil }
        // Strip a trailing slash so `…/api/…` isn't doubled.
        let base = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
        let encodedUID = sessionUID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionUID
        guard var components = URLComponents(string: "\(base)/api/crow-sessions/\(encodedUID)/artifacts") else {
            return nil
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "harness", value: harness.rawValue),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "format", value: format.rawValue),
            URLQueryItem(name: "truncated", value: transcript.truncated ? "true" : "false"),
            URLQueryItem(name: "event_count", value: String(transcript.eventCount)),
            URLQueryItem(name: "tool_call_count", value: String(transcript.toolCallCount)),
        ]
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }
        add("agent_session_id", agentSessionID)
        add("name", metadata.name)
        add("status", metadata.status)
        add("agent_kind", metadata.agentKind)
        add("ticket_url", metadata.ticketURL)
        if let n = metadata.ticketNumber { add("ticket_number", String(n)) }
        add("repo", metadata.repo)
        add("org_goal", metadata.orgGoal)
        components.queryItems = items

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.httpBody = transcript.data
        return request
    }

    /// Categorize an HTTP status into an upload result.
    public static func classify(status: Int) -> TranscriptUploadResult {
        switch status {
        case 200...299: return .created
        case 409: return .alreadyExists
        case 413: return .tooLarge
        // Rate limiting (429) and request timeout (408) are temporary: retrying
        // later can succeed, so they take the backoff path rather than being
        // recorded as a permanent skip that never retries.
        case 408, 429: return .transient
        case 500...599: return .transient
        default: return .rejected(status: status)
        }
    }

    /// Upload the transcript. One retry on a transient failure, then give up
    /// (returns `.transient` for the caller to record and re-attempt later).
    public func upload(
        baseURL: String,
        apiKey: String,
        sessionUID: String,
        harness: LogSyncHarness,
        kind: LogSyncArtifactKind,
        format: AgentLogFormat,
        transcript: NormalizedTranscript,
        metadata: LogSyncSessionMetadata,
        agentSessionID: String?
    ) async -> TranscriptUploadResult {
        guard let request = Self.makeRequest(
            baseURL: baseURL, apiKey: apiKey, sessionUID: sessionUID,
            harness: harness, kind: kind, format: format,
            transcript: transcript, metadata: metadata, agentSessionID: agentSessionID
        ) else {
            return .rejected(status: 0) // misconfigured — permanent, not retried
        }

        for attempt in 0..<2 {
            do {
                let status = try await transport.perform(request)
                let result = Self.classify(status: status)
                if result == .transient, attempt == 0 { continue } // one retry
                return result
            } catch {
                if attempt == 0 { continue } // one retry on transport error
                return .transient
            }
        }
        return .transient
    }
}
