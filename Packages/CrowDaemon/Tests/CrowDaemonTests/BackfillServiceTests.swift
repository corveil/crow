import Foundation
import Testing
import CrowCore
@testable import CrowDaemon

/// A fake upload transport that returns a fixed HTTP status (mirrors the
/// approach in `TranscriptUploaderTests`).
private struct FixedStatusTransport: TranscriptUploadTransport {
    let status: Int
    func perform(_ request: URLRequest) async throws -> Int { status }
}

/// A `ShellRunner` answering from a closure, for the ticket validator.
private struct StubRunner: ShellRunner {
    let answer: @Sendable ([String]) -> Result<String, Error>
    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        switch answer(args) {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

@Suite struct BackfillServiceTests {
    private func tempDevRoot() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func writeTranscript(_ devRoot: String, uid: String, lines: Int = 3) throws -> String {
        let dir = URL(fileURLWithPath: devRoot).appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(uid).jsonl")
        let body = (0..<lines).map { #"{"type":"user","i":\#($0)}"# }.joined(separator: "\n")
        try body.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func service(_ devRoot: String, status: Int, ticket: Result<String, Error>) -> BackfillService {
        BackfillService(
            devRoot: devRoot,
            uploader: TranscriptUploader(transport: FixedStatusTransport(status: status)),
            validator: TicketValidator(runner: StubRunner { _ in ticket }),
            resolveSecret: { _ in nil },
            now: { Date(timeIntervalSince1970: 1000) })
    }

    private func session(_ devRoot: String, uid: String, path: String) -> BackfillSession {
        BackfillSession(
            claudeSessionUID: uid, filePath: path, slug: "t",
            workspace: "RadiusMethod", worktreeName: "crow-12-x", repoName: "crow",
            ownerRepo: "corveil/crow", host: "github.com", ticketNumber: 12,
            confidence: .high, uploadStatus: .new)
    }

    @Test func uploadsAndLinksValidatedTicket() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "UID-A")
        let svc = service(devRoot, status: 201, ticket: .success(#"{"number":12}"#))

        let outcome = await svc.upload(
            session: session(devRoot, uid: "UID-A", path: path),
            upload: (baseURL: "https://corveil.io", apiKey: "k"), maxUploadBytes: 8_000_000)

        #expect(outcome.result == .uploaded)
        #expect(outcome.linked == true)
        #expect(outcome.ticketKind == .issue)
        #expect(outcome.ticketNumber == 12)

        // Ledger recorded — a second attempt is an idempotent no-op.
        let again = await svc.upload(
            session: session(devRoot, uid: "UID-A", path: path),
            upload: (baseURL: "https://corveil.io", apiKey: "k"), maxUploadBytes: 8_000_000)
        #expect(again.result == .alreadyUploaded)
    }

    @Test func unvalidatedTicketUploadsRepoOnly() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "UID-B")
        // Provider says 404 → no link asserted.
        let svc = service(devRoot, status: 201,
                          ticket: .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "Not Found")))
        let outcome = await svc.upload(
            session: session(devRoot, uid: "UID-B", path: path),
            upload: (baseURL: "https://corveil.io", apiKey: "k"), maxUploadBytes: 8_000_000)
        #expect(outcome.result == .uploaded)
        #expect(outcome.linked == false)
        #expect(outcome.ownerRepo == "corveil/crow") // repo-only still carries the repo
    }

    @Test func emptyTranscriptIsSkipped() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "UID-C", lines: 0)
        let svc = service(devRoot, status: 201, ticket: .success(#"{"number":12}"#))
        let outcome = await svc.upload(
            session: session(devRoot, uid: "UID-C", path: path),
            upload: (baseURL: "https://corveil.io", apiKey: "k"), maxUploadBytes: 8_000_000)
        #expect(outcome.result == .skipped)
        #expect(outcome.reason == "empty_or_unreadable")
    }

    @Test func serverConflictIsIdempotentSuccess() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "UID-D")
        let svc = service(devRoot, status: 409, ticket: .success(#"{"number":12}"#))
        let outcome = await svc.upload(
            session: session(devRoot, uid: "UID-D", path: path),
            upload: (baseURL: "https://corveil.io", apiKey: "k"), maxUploadBytes: 8_000_000)
        #expect(outcome.result == .alreadyUploaded)
    }

    @Test func remoteHelperSplitsOwnerRepo() {
        #expect(BackfillService.remote(ownerRepo: "corveil/crow", host: "github.com")
                == RepoRemote(host: "github.com", owner: "corveil", repo: "crow"))
        #expect(BackfillService.remote(ownerRepo: "noslash", host: "github.com") == nil)
    }

    // MARK: Codex harness (CROW-1089)

    @Test func harnessMappingHelpers() {
        #expect(BackfillService.uploadFormat(for: .claude) == .jsonl)
        #expect(BackfillService.uploadFormat(for: .codex) == .logDir)
        #expect(BackfillService.uploadFormat(for: .grok) == .jsonl) // single NDJSON transcript
        #expect(BackfillService.uploadFormat(for: .cursor) == .sqlite)
        #expect(BackfillService.uploadFormat(for: .opencode) == .openCodeStore)
        #expect(BackfillService.uploadFormat(for: .antigravity) == .jsonl) // single NDJSON transcript
        #expect(BackfillService.uploadFormat(for: .muse) == .logDir) // matches the live .logDir stamp
        #expect(BackfillService.agentKindRawValue(for: .claude) == AgentKind.claudeCode.rawValue)
        #expect(BackfillService.agentKindRawValue(for: .codex) == AgentKind.codex.rawValue)
        #expect(BackfillService.agentKindRawValue(for: .grok) == AgentKind.grok.rawValue)
        #expect(BackfillService.agentKindRawValue(for: .cursor) == AgentKind.cursor.rawValue)
        #expect(BackfillService.agentKindRawValue(for: .opencode) == AgentKind.openCode.rawValue)
        #expect(BackfillService.agentKindRawValue(for: .antigravity) == AgentKind.antigravity.rawValue)
        #expect(BackfillService.agentKindRawValue(for: .muse) == AgentKind.muse.rawValue)
    }

    @Test func codexSessionUploadsUnderCodexHarnessSlot() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "CDX-1")
        let svc = service(devRoot, status: 201, ticket: .success(#"{"number":12}"#))
        var s = session(devRoot, uid: "CDX-1", path: path)
        s.harness = .codex

        let outcome = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(outcome.result == .uploaded)
        #expect(outcome.harness == .codex) // the outcome carries its harness for UI keying

        // Idempotent within the codex slot: a re-run is a no-op...
        let again = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(again.result == .alreadyUploaded)

        // ...but the SAME uid under the Claude harness is a distinct slot that has
        // not been uploaded, so it proceeds (the harness disambiguates the ledger).
        var claudeTwin = s
        claudeTwin.harness = .claude
        let twin = await svc.upload(
            session: claudeTwin, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(twin.result == .uploaded)
    }

    // MARK: Grok harness (CROW-1098)

    @Test func grokSessionUploadsUnderGrokHarnessSlot() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "GRK-1")
        let svc = service(devRoot, status: 201, ticket: .success(#"{"number":12}"#))
        var s = session(devRoot, uid: "GRK-1", path: path)
        s.harness = .grok

        let outcome = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(outcome.result == .uploaded)
        #expect(outcome.harness == .grok) // the outcome carries its harness for UI keying

        // Idempotent within the grok slot.
        let again = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(again.result == .alreadyUploaded)
    }

    // MARK: OpenCode harness (CROW-1096)

#if canImport(SQLite3)
    /// Build a minimal `opencode.db` with one session (+ message + part) at
    /// `devRoot/oc/opencode.db` and return its path — the shared `filePath` an
    /// OpenCode backfill row carries.
    private func writeOpenCodeDatabase(_ devRoot: String, uid: String) throws -> String {
        let db = URL(fileURLWithPath: devRoot).appendingPathComponent("oc/opencode.db")
        try FileManager.default.createDirectory(
            at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OpenCodeDBFixture.write(
            at: db.path,
            sessions: [(id: uid, cwd: "/dev/ws/repo-1", parentID: nil)],
            messages: [(id: "msg_1", sessionID: uid, created: 1, data: #"{"role":"user"}"#)],
            parts: [(id: "prt_1", messageID: "msg_1", sessionID: uid, data: #"{"type":"text"}"#)])
        return db.path
    }

    @Test func openCodeSessionUploadsUnderOpenCodeHarness() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeOpenCodeDatabase(devRoot, uid: "ses_OC")
        let svc = service(devRoot, status: 201, ticket: .success(#"{"number":12}"#))
        var s = session(devRoot, uid: "ses_OC", path: path)
        s.harness = .opencode

        // The session is reassembled from `opencode.db` (by id) and uploaded — proves
        // the OpenCode SQLite normalization path is wired through BackfillService.
        let outcome = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(outcome.result == .uploaded)
        #expect(outcome.harness == .opencode)

        // Idempotent within the opencode slot.
        let again = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(again.result == .alreadyUploaded)
    }
#endif

    // MARK: Muse harness (CROW-1106)

    @Test func museSessionUploadsUnderMuseHarnessSlot() async throws {
        let devRoot = try tempDevRoot()
        let path = try writeTranscript(devRoot, uid: "MUSE-1")
        let svc = service(devRoot, status: 201, ticket: .success(#"{"number":12}"#))
        var s = session(devRoot, uid: "MUSE-1", path: path)
        s.harness = .muse

        let outcome = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(outcome.result == .uploaded)
        #expect(outcome.harness == .muse) // the outcome carries its harness for UI keying

        // Idempotent within the muse slot: a re-run is a no-op...
        let again = await svc.upload(
            session: s, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(again.result == .alreadyUploaded)

        // ...but the SAME uid under the Grok harness is a distinct slot — the
        // harness disambiguates the ledger.
        var grokTwin = s
        grokTwin.harness = .grok
        let twin = await svc.upload(
            session: grokTwin, upload: (baseURL: "https://corveil.io", apiKey: "k"),
            maxUploadBytes: 8_000_000)
        #expect(twin.result == .uploaded)
    }
}
