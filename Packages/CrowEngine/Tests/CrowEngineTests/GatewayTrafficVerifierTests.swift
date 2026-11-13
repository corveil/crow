import Foundation
import Testing
@testable import CrowCore
@testable import CrowEngine

/// CROW-1423: the gateway-traffic verifier's read loop and matching,
/// with fake log sources (no network, no real keys).
@Suite struct GatewayTrafficVerifierTests {
    static let now = Date(timeIntervalSince1970: 2_000_000)
    static let base = "https://gw.test"

    static func page(_ entries: [(id: String, conv: String, org: String, key: String)], cursor: String?) -> Data {
        let logs = entries.map { e -> [String: Any] in
            ["id": e.id, "created_at": "1970-01-24T03:32:00Z",  // = now - 80s
             "api_key_id": e.key, "api_key_name": "key \(e.key)", "organization_id": e.org,
             "metadata": ["request_body_claude_code_session": e.conv]]
        }
        var root: [String: Any] = ["logs": logs]
        if let cursor { root["next_cursor"] = cursor }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ s: String) { lock.withLock { urls.append(s) } }
        var all: [String] { lock.withLock { urls } }
    }

    /// Two connection orgs. The Client A key is refused (403); the
    /// Corveil key reads two pages. The "bad" Manager is tagged with the
    /// Client A workspace, yet its conversation shows up under Corveil.
    @Test func mismatchPagingAndRefusedKeyFallback() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let cwd = "/dev/root/.crow/managers/bad"
        let projectDir = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
            .appendingPathComponent(AgentLogSource.posixPathSlug(cwd))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projectDir.appendingPathComponent("conv-bad.jsonl"))
        defer { try? FileManager.default.removeItem(atPath: home) }

        let rmWorkspace = WorkspaceInfo(
            name: "rm", uploadSessionLogs: true,
            gateway: WorkspaceGateway(baseURL: Self.base, customHeaders: ["x-citadel-api-key": "sk-test-rm"]))
        var config = AppConfig(workspaces: [rmWorkspace])
        config.corveilConnection = CorveilConnection(
            baseURL: Self.base, clientID: "client",
            orgKeys: [CorveilOrgKey(orgID: "org-rm", orgName: "Client A", keyID: "key-rm", keyPrefix: "sk-test-r"),
                      CorveilOrgKey(orgID: "org-c", orgName: "Corveil, Inc.", keyID: "key-c", keyPrefix: "sk-test-c")],
            orgKeySecrets: ["org-rm": "sk-test-rm", "org-c": "sk-test-corveil"])

        var bad = Session(name: "bad", kind: .manager, workspaceID: rmWorkspace.id)
        bad.harnessConversationID = "conv-bad"
        var quiet = Session(name: "quiet", kind: .manager, workspaceID: rmWorkspace.id)
        quiet.harnessConversationID = "conv-quiet"

        let calls = Calls()
        let verifier = GatewayTrafficVerifier(
            http: { url, key in
                calls.add(url.absoluteString)
                if key == "sk-test-rm" { return (403, Data(#"{"error":"forbidden"}"#.utf8)) }
                if url.absoluteString.contains("cursor=p2") {
                    return (200, Self.page([("2", "conv-bad", "org-c", "key-c")], cursor: nil))
                }
                return (200, Self.page([("1", "conv-bad", "org-c", "key-c"), ("3", "other", "org-c", "key-c")], cursor: "p2"))
            },
            cli: { _, _ in Self.page([], cursor: nil) },
            corveilBinary: { _ in "/fake/corveil" },
            home: home, now: { Self.now })

        let inputs = [bad, quiet].map {
            GatewayTrafficVerifier.SessionInput(session: $0, worktreePath: nil, prLinks: [], managerCwd: cwd)
        }
        let (evidence, sources) = await verifier.run(inputs: inputs, config: config, devRoot: nil)

        let badEv = try #require(evidence[bad.id])
        #expect(badEv.state == .mismatch)
        #expect(badEv.count == 2)  // both pages
        #expect(badEv.seenOrganizationName == "Corveil, Inc.")
        #expect(badEv.expectedOrganizationName == "Client A")
        #expect(badEv.seenAPIKeyID == "key-c")

        // Client A's log was never readable, so silence proves nothing.
        #expect(evidence[quiet.id]?.state == .unavailable)

        // One refused read, then two pages for Corveil; limit is always 500.
        #expect(calls.all.count == 3)
        #expect(calls.all.allSatisfy { $0.contains("/api/logs?limit=500") })
        #expect(sources.contains { !$0.readable && $0.note.contains("HTTP 403") })
        #expect(sources.contains { $0.label == "corveil CLI login" })  // fallback tried
        #expect(!sources.contains { $0.label.contains("sk-test-rm") || $0.note.contains("sk-test") })
    }

    @Test func nothingToDoWithoutClaudeSessions() async {
        let verifier = GatewayTrafficVerifier(
            http: { _, _ in Issue.record("no read expected"); return nil },
            cli: { _, _ in nil }, corveilBinary: { _ in nil }, now: { Self.now })
        let cursor = Session(name: "c", kind: .work, agentKind: .cursor)
        let (evidence, sources) = await verifier.run(
            inputs: [.init(session: cursor, worktreePath: nil, prLinks: [], managerCwd: nil)], config: AppConfig(), devRoot: nil)
        #expect(evidence.isEmpty)
        #expect(sources.isEmpty)
    }

    /// A reused worktree path can hold a previous session's transcripts; one
    /// that last changed before this session existed isn't this session's.
    @Test func workSessionIgnoresTranscriptsOlderThanTheSession() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let wt = "/dev/root/corveil/crow-1-x"
        let verifier = GatewayTrafficVerifier(home: home)
        let dir = verifier.projectDir(cwd: wt)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let created = Date(timeIntervalSince1970: 1_000_000)
        for (name, at) in [("old", created.addingTimeInterval(-60)), ("new", created.addingTimeInterval(60))] {
            let url = dir.appendingPathComponent("\(name).jsonl")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        }
        let session = Session(name: "w", kind: .work, createdAt: created)
        let convs = verifier.conversations(
            for: .init(session: session, worktreePath: wt, prLinks: [], managerCwd: nil))
        #expect(convs.map(\.id) == ["new"])
        #expect(GatewayTrafficVerifier.ownConversations(
            [.init(id: "unknown-mtime", lastWrite: nil)], sessionCreatedAt: created).count == 1)
    }

    /// CROW-1449: "active N ago" is the transcript's newest timestamped entry,
    /// not its mtime, which a live agent re-touches hourly while idle.
    @Test func managerActivityIsLastTimestampedEntryNotMtime() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = "/dev/root/.crow/managers/idle"
        let verifier = GatewayTrafficVerifier(home: home)
        let dir = verifier.projectDir(cwd: cwd)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("conv-idle.jsonl")
        try Data((#"{"type":"assistant","timestamp":"2026-11-12T18:59:27.000Z"}"# + "\n"
            + #"{"type":"custom-title","customTitle":"x"}"# + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: url.path)

        var manager = Session(name: "idle", kind: .manager)
        manager.harnessConversationID = "conv-idle"
        let convs = verifier.conversations(
            for: .init(session: manager, worktreePath: nil, prLinks: [], managerCwd: cwd))
        #expect(convs.map(\.id) == ["conv-idle"])
        #expect(convs.first?.lastWrite == TranscriptActivity.timestamp(
            ofLine: #"{"timestamp":"2026-11-12T18:59:27.000Z"}"#))
    }

    @Test func logsURLCarriesLimitAndCursor() {
        let url = GatewayTrafficVerifier.logsURL(base: "https://corveil.io/", cursor: "a+b")
        #expect(url?.absoluteString == "https://corveil.io/api/logs?limit=500&cursor=a%2Bb")
    }
}
