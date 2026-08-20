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
}
