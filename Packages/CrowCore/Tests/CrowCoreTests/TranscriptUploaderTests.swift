import Foundation
import Testing
import CrowCore

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest / URLError live here on Linux
#endif

/// Records requests and replays scripted outcomes so the uploader is testable
/// without a live server.
final class MockUploadTransport: TranscriptUploadTransport, @unchecked Sendable {
    private let outcomes: [Result<Int, Error>]
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private var callIndex = 0

    init(outcomes: [Result<Int, Error>]) { self.outcomes = outcomes }

    var callCount: Int { lock.withLock { callIndex } }

    func perform(_ request: URLRequest) async throws -> Int {
        let outcome: Result<Int, Error> = lock.withLock {
            requests.append(request)
            let o = outcomes[min(callIndex, outcomes.count - 1)]
            callIndex += 1
            return o
        }
        switch outcome {
        case .success(let status): return status
        case .failure(let error): throw error
        }
    }
}

@Suite struct TranscriptUploaderTests {
    private let transcript = NormalizedTranscript(
        data: Data("{\"a\":1}\n".utf8), eventCount: 1, toolCallCount: 0, truncated: false)

    private func meta() -> LogSyncSessionMetadata {
        LogSyncSessionMetadata(
            name: "Fix thing", status: "completed", agentKind: "claude-code",
            ticketURL: "https://github.com/o/r/issues/5", ticketNumber: 5,
            repo: "o/r", orgGoal: "ship")
    }

    @Test func makeRequestBuildsContractURLAndHeaders() throws {
        let req = TranscriptUploader.makeRequest(
            baseURL: "https://api.corveil.io/", apiKey: "sk-citadel-abc",
            sessionUID: "SID-1", harness: .claude, kind: .sessionTranscript, format: .jsonl,
            transcript: transcript, metadata: meta(), agentSessionID: "claude-uuid")!

        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        #expect(comps.scheme == "https")
        #expect(comps.host == "api.corveil.io")
        // Trailing slash on baseURL is trimmed (no doubled slash).
        #expect(comps.path == "/api/crow-sessions/SID-1/artifacts")

        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["harness"] == "claude")
        #expect(items["kind"] == "session_transcript")
        #expect(items["format"] == "jsonl")
        #expect(items["truncated"] == "false")
        #expect(items["event_count"] == "1")
        #expect(items["agent_session_id"] == "claude-uuid")
        #expect(items["ticket_url"] == "https://github.com/o/r/issues/5")
        #expect(items["ticket_number"] == "5")
        #expect(items["repo"] == "o/r")
        #expect(items["org_goal"] == "ship")

        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-citadel-abc")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")
        #expect(req.httpBody == transcript.data)
    }

    @Test func makeRequestOmitsEmptySidecarHints() throws {
        let req = TranscriptUploader.makeRequest(
            baseURL: "https://api.x", apiKey: "k", sessionUID: "S", harness: .unknown,
            kind: .sessionTranscript, format: .jsonl, transcript: transcript,
            metadata: LogSyncSessionMetadata(), agentSessionID: nil)!
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let names = Set((comps.queryItems ?? []).map(\.name))
        #expect(!names.contains("name"))
        #expect(!names.contains("ticket_url"))
        #expect(!names.contains("agent_session_id"))
        #expect(names.contains("harness")) // required ones stay
    }

    @Test func makeRequestNilWhenMisconfigured() {
        #expect(TranscriptUploader.makeRequest(
            baseURL: "", apiKey: "k", sessionUID: "S", harness: .claude, kind: .sessionTranscript,
            format: .jsonl, transcript: transcript, metadata: meta(), agentSessionID: nil) == nil)
        #expect(TranscriptUploader.makeRequest(
            baseURL: "https://api.x", apiKey: "  ", sessionUID: "S", harness: .claude,
            kind: .sessionTranscript, format: .jsonl, transcript: transcript,
            metadata: meta(), agentSessionID: nil) == nil)
    }

    @Test func classifyMapsStatuses() {
        #expect(TranscriptUploader.classify(status: 201) == .created)
        #expect(TranscriptUploader.classify(status: 200) == .created)
        #expect(TranscriptUploader.classify(status: 409) == .alreadyExists)
        #expect(TranscriptUploader.classify(status: 413) == .tooLarge)
        #expect(TranscriptUploader.classify(status: 500) == .transient)
        #expect(TranscriptUploader.classify(status: 404) == .rejected(status: 404))
        #expect(TranscriptUploader.classify(status: 401) == .rejected(status: 401))
    }

    private func doUpload(_ transport: MockUploadTransport) async -> TranscriptUploadResult {
        await TranscriptUploader(transport: transport).upload(
            baseURL: "https://api.x", apiKey: "k", sessionUID: "S", harness: .claude,
            kind: .sessionTranscript, format: .jsonl, transcript: transcript,
            metadata: meta(), agentSessionID: nil)
    }

    @Test func createdOnFirstTry() async {
        let t = MockUploadTransport(outcomes: [.success(201)])
        #expect(await doUpload(t) == .created)
        #expect(t.callCount == 1)
    }

    @Test func conflictTreatedAsSuccess() async {
        let t = MockUploadTransport(outcomes: [.success(409)])
        let r = await doUpload(t)
        #expect(r == .alreadyExists)
        #expect(r.isSuccess)
    }

    @Test func retriesOnceOnTransientThenSucceeds() async {
        let t = MockUploadTransport(outcomes: [.success(503), .success(201)])
        #expect(await doUpload(t) == .created)
        #expect(t.callCount == 2)
    }

    @Test func twoTransientsGiveUp() async {
        let t = MockUploadTransport(outcomes: [.success(503), .success(500)])
        let r = await doUpload(t)
        #expect(r == .transient)
        #expect(t.callCount == 2)
    }

    @Test func retriesOnceOnThrownTransportError() async {
        let t = MockUploadTransport(outcomes: [.failure(URLError(.timedOut)), .success(201)])
        #expect(await doUpload(t) == .created)
        #expect(t.callCount == 2)
    }

    @Test func tooLargeAndRejectedArePermanentAndNotRetried() async {
        let big = MockUploadTransport(outcomes: [.success(413)])
        let r1 = await doUpload(big)
        #expect(r1 == .tooLarge)
        #expect(r1.isPermanentFailure)
        #expect(big.callCount == 1) // no retry on a permanent failure

        let bad = MockUploadTransport(outcomes: [.success(404)])
        let r2 = await doUpload(bad)
        #expect(r2 == .rejected(status: 404))
        #expect(bad.callCount == 1)
    }
}
