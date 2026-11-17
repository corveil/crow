import CrowCore
import CrowEngine
import CrowIPC
import Foundation
import Testing

@testable import CrowDaemon

/// CROW-1462 (#1378): `backfill-scan` with `output_path` writes the full rows to
/// a 0600 file and replies with the summary only, so the CLI's reply stays
/// under the Unix socket's 1 MiB cap however large the history is. Without
/// `output_path` it replies exactly as before, which the Settings dialog reads.
@Suite struct BackfillScanRowsFileTests {
    /// `SocketServer.maxMessageSize` — internal to CrowIPC, so restated here.
    private static let socketReplyCap = 1_048_576

    private func tempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// `count` rows with long paths, so a few thousand are well past 1 MiB.
    private func rows(_ count: Int) -> [BackfillSession] {
        (0..<count).map { i in
            BackfillSession(
                claudeSessionUID: "uid-\(i)",
                filePath: "/Users/someone/.claude/projects/-Users-someone-Dev-Acme-acme-api-\(i)-a-fairly-long-worktree-slug/\(UUID().uuidString).jsonl",
                slug: "-Users-someone-Dev-Acme-acme-api-\(i)-a-fairly-long-worktree-slug",
                cwd: "/Users/someone/Dev/Acme/acme-api-\(i)-a-fairly-long-worktree-slug",
                gitBranch: "feature/acme-api-\(i)-a-fairly-long-worktree-slug",
                modifiedAt: 1_700_000_000 + Double(i), sizeBytes: 10_000 + i,
                workspace: "Acme", worktreeName: "acme-api-\(i)-a-fairly-long-worktree-slug",
                repoName: "acme-api", ownerRepo: "acme/acme-api", host: "github.com",
                ticketNumber: i, confidence: i.isMultiple(of: 3) ? .medium : .high,
                uploadStatus: i.isMultiple(of: 5) ? .uploaded : .new)
        }
    }

    /// The reply as it would cross the socket: a full JSON-RPC response line.
    private func wireBytes(_ result: [String: JSONValue]) throws -> Int {
        try JSONEncoder().encode(JSONRPCResponse.success(id: 1, result: result)).count
    }

    private func decodeFile(_ path: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    @Test func largeScanRepliesWithSummaryAndWritesEveryRowToFile() throws {
        let sessions = rows(4000)
        let inline = try backfillScanReply(sessions, outputPath: nil)
        #expect(try wireBytes(inline) > Self.socketReplyCap, "the fixture must overflow the socket to prove anything")

        let path = try tempDir() + "/scan.json"
        let reply = try backfillScanReply(sessions, outputPath: path)
        #expect(try wireBytes(reply) < Self.socketReplyCap)
        #expect(Set(reply.keys) == ["summary", "rows_file", "row_count"])
        #expect(reply["rows_file"]?.stringValue == path)
        #expect(reply["row_count"]?.intValue == 4000)
        #expect(reply["summary"]?.objectValue?["total"]?.intValue == 4000)

        // The file holds what the inline reply would have: every row, same summary.
        // (Compared by UID, not `==`: a whole-number `.double` reads back as `.int`.)
        let file = try decodeFile(path)
        let uids = { (v: [String: JSONValue]) in
            (v["sessions"]?.arrayValue ?? []).compactMap { $0.objectValue?["uid"]?.stringValue }
        }
        #expect(uids(file).count == 4000)
        #expect(uids(file) == uids(inline))
        #expect(file["summary"] == inline["summary"])
    }

    @Test func rowsFileIsMode0600EvenWhenItAlreadyExisted() throws {
        let path = try tempDir() + "/scan.json"
        // A pre-existing world-readable file must not keep its mode.
        FileManager.default.createFile(atPath: path, contents: Data("old".utf8),
                                       attributes: [.posixPermissions: 0o644])
        _ = try backfillScanReply(rows(3), outputPath: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try decodeFile(path)["sessions"]?.arrayValue?.count == 3)

        let fresh = try tempDir() + "/fresh.json"
        _ = try backfillScanReply(rows(1), outputPath: fresh)
        let freshMode = try FileManager.default.attributesOfItem(atPath: fresh)[.posixPermissions] as? Int
        #expect(freshMode == 0o600)
    }

    @Test func withoutOutputPathRepliesExactlyAsBefore() throws {
        let sessions = rows(2)
        #expect(try backfillScanOutputPath([:]) == nil)
        let reply = try backfillScanReply(sessions, outputPath: nil)
        #expect(Set(reply.keys) == ["sessions", "summary"])
        let first = try #require(reply["sessions"]?.arrayValue?.first?.objectValue)
        #expect(first["uid"]?.stringValue == "uid-0")
        #expect(first["owner_repo"]?.stringValue == "acme/acme-api")
        #expect(first["confidence"]?.stringValue == "medium")
        let summary = try #require(reply["summary"]?.objectValue)
        #expect(Set(summary.keys) == ["total", "uploaded", "linkable", "repo_only", "orphan"])
        #expect(summary["total"]?.intValue == 2)
    }

    @Test func badOutputPathFailsBeforeTheScanWithAClearError() throws {
        // A parent that doesn't exist is unwritable even for root (CI in Docker).
        let missing = try tempDir() + "/no-such-dir/scan.json"
        do {
            _ = try backfillScanOutputPath(["output_path": .string(missing)])
            Issue.record("expected an error for \(missing)")
        } catch let RPCError.invalidParams(message) {
            #expect(message.contains("not writable"))
            #expect(message.contains(missing))
        }

        let dir = try tempDir()
        #expect(throws: RPCError.self) { _ = try backfillScanOutputPath(["output_path": .string(dir)]) }
        #expect(throws: RPCError.self) { _ = try backfillScanOutputPath(["output_path": .string("scan.json")]) }
        #expect(throws: RPCError.self) { _ = try backfillScanOutputPath(["output_path": .string("")]) }
        #expect(throws: RPCError.self) { _ = try backfillScanOutputPath(["output_path": .int(1)]) }

        let ok = dir + "/scan.json"
        #expect(try backfillScanOutputPath(["output_path": .string(ok)]) == ok)
    }

    @Test func writeFailureAfterTheScanIsAnErrorNotAReceipt() throws {
        // The directory vanished between the up-front check and the write.
        let path = try tempDir() + "/gone/scan.json"
        #expect(throws: RPCError.self) { _ = try backfillScanReply(rows(1), outputPath: path) }
    }

    @Test func outputPathIsLocalOnlyOnRPC() {
        let devRoot = NSTemporaryDirectory()
        let withPath = JSONRPCRequest(id: 1, method: "backfill-scan", params: ["output_path": .string("/tmp/x.json")])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: withPath, devRoot: devRoot)
                == "backfill-scan output_path is local-only")
        // The Settings dialog's plain scan stays reachable remotely.
        let plain = JSONRPCRequest(id: 2, method: "backfill-scan", params: [:])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: plain, devRoot: devRoot) == nil)
    }
}
