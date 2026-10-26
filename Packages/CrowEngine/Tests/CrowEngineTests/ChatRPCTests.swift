import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// The Chat view's RPCs through the real engine router, plus the experimental
/// driver registry's lifecycle. No real `claude` runs: the registry tests use a
/// `/bin/sh` child, and the RPC tests stop at gates that fire before any spawn.
@Suite("Chat RPCs and driver registry")
@MainActor
struct ChatRPCTests {
    private struct Fixture {
        let appState: AppState
        let router: CommandRouter
        let tmp: URL
    }

    private func fixture() throws -> Fixture {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-chat-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        let ctx = EngineContext(
            appState: appState, store: store, sessionService: service, issueTracker: nil,
            telemetryPort: nil, devRoot: tmp.path, hostBridge: NoopHostBridge(),
            loadConfig: { nil }, applyConfig: { _ in nil })
        return Fixture(appState: appState, router: makeEngineRouter(ctx), tmp: tmp)
    }

    /// A Claude session whose primary worktree is `dir`, holding one project skill.
    private func addSession(_ f: Fixture, kind: SessionKind, skill: String) throws -> Session {
        let session = Session(name: "chat-\(kind.rawValue)", kind: kind, agentKind: .claudeCode)
        let dir = f.tmp.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let skillDir = dir.appendingPathComponent(".claude/skills/\(skill)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try Data("---\ndescription: project skill\n---\n".utf8)
            .write(to: skillDir.appendingPathComponent("SKILL.md"))
        f.appState.sessions.append(session)
        f.appState.worktrees[session.id] = [
            SessionWorktree(sessionID: session.id, repoName: "repo", repoPath: dir.path,
                            worktreePath: dir.path, branch: "feature/x", isPrimary: true),
        ]
        return session
    }

    private func call(_ f: Fixture, _ method: String, _ session: Session) async -> JSONRPCResponse {
        await f.router.handle(request: JSONRPCRequest(
            id: 1, method: method, params: ["session_id": .string(session.id.uuidString)]))
    }

    @Test("chat-driver-start refuses review sessions, whether or not the flag is on")
    func driverStartRefusesReviewSessions() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let review = try addSession(f, kind: .review, skill: "x")
        let work = try addSession(f, kind: .work, skill: "y")

        let refused = await call(f, "chat-driver-start", review)
        #expect(refused.error?.message.contains("review sessions") == true)
        #expect(ChatDriverRegistry.shared.driver(for: review.id) == nil)

        // A work session passes the session gates and stops at the flag (off in tests),
        // which proves the review gate is not just the flag in disguise.
        if !ChatDriverRegistry.enabled {
            let off = await call(f, "chat-driver-start", work)
            #expect(off.error?.message.contains("CROW_CHAT_DRIVER") == true)
        }
    }

    @Test("chat-driver-start refuses a session with no worktree, or one outside the dev root")
    func driverStartRefusesMissingOrOutsideCwd() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        // No managed terminal and no worktree: the cwd resolves to "".
        let bare = Session(name: "no-worktree", kind: .work, agentKind: .claudeCode)
        f.appState.sessions.append(bare)
        let none = await call(f, "chat-driver-start", bare)
        #expect(none.error?.message.contains("worktree") == true)

        // A worktree that exists but sits outside the dev root.
        let outside = Session(name: "outside", kind: .work, agentKind: .claudeCode)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        f.appState.sessions.append(outside)
        f.appState.worktrees[outside.id] = [
            SessionWorktree(sessionID: outside.id, repoName: "repo", repoPath: home,
                            worktreePath: home, branch: "feature/x", isPrimary: true),
        ]
        let out = await call(f, "chat-driver-start", outside)
        #expect(out.error?.message.contains("worktree") == true)
        #expect(ChatDriverRegistry.shared.driver(for: bare.id) == nil)
        #expect(ChatDriverRegistry.shared.driver(for: outside.id) == nil)
    }

    @Test("the driver itself refuses an empty working directory")
    func driverRefusesEmptyCwd() throws {
        let driver = ClaudeStreamDriver(
            sessionID: UUID(), cwd: "", logURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("unused-\(UUID().uuidString).ndjson"),
            executable: "/bin/sh", arguments: ["-c", "true"]) { _ in }
        #expect(throws: ClaudeStreamDriver.DriverError.self) { try driver.start() }
        #expect(!driver.isRunning)
    }

    @Test("stopAndWait returns only once the child has exited, even one ignoring SIGTERM")
    func stopAndWaitWaitsForExit() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let registry = ChatDriverRegistry()
        let id = UUID()
        let stubborn = (executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 0.05; done"])
        let driver = try registry.start(sessionID: id, cwd: f.tmp.path, appState: f.appState, command: stubborn)
        #expect(driver.isRunning)
        await registry.stopAndWait(sessionID: id, timeout: 0.3)
        #expect(!driver.isRunning)
        #expect(registry.driver(for: id) == nil)
    }

    @Test("list-chat-commands hides a review worktree's project skills")
    func reviewSessionsListNoProjectCommands() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let marker = "crow-test-skill-\(UUID().uuidString.prefix(8).lowercased())"
        let work = try addSession(f, kind: .work, skill: marker)
        let review = try addSession(f, kind: .review, skill: marker)

        func names(_ r: JSONRPCResponse) -> [String] {
            guard case .array(let items)? = r.result?["commands"] else { return [] }
            return items.compactMap { item in
                if case .object(let o) = item, case .string(let n)? = o["name"] { return n }
                return nil
            }
        }
        let workNames = names(await call(f, "list-chat-commands", work))
        let reviewNames = names(await call(f, "list-chat-commands", review))
        #expect(workNames.contains(marker))
        #expect(!reviewNames.contains(marker))
        #expect(reviewNames.contains("compact"))
    }

    @Test("a replaced driver's late events never touch the current one; stop forgets it")
    func registryIgnoresStaleDriverEvents() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let registry = ChatDriverRegistry()
        let id = UUID()
        let child = (executable: "/bin/sh", arguments: ["-c", "cat >/dev/null"])

        let first = try registry.start(sessionID: id, cwd: f.tmp.path, appState: f.appState, command: child)
        first.stop()
        try await waitUntil { !first.isRunning }
        let second = try registry.start(sessionID: id, cwd: f.tmp.path, appState: f.appState, command: child)
        #expect(second !== first)

        // `first`'s `.exited` hops to the MainActor; give it every chance to land.
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(registry.driver(for: id) === second)

        // Events attributed to the stale driver are dropped outright.
        registry.apply(.exited(status: 0), sessionID: id, from: first, appState: f.appState)
        #expect(registry.driver(for: id) === second)

        f.appState.hookState(for: id).activityState = .working
        #expect(registry.stop(sessionID: id, appState: f.appState))
        #expect(registry.driver(for: id) == nil)
        #expect(f.appState.hookState(for: id).activityState == .idle)
        try await waitUntil { !second.isRunning }
        #expect(!registry.stop(sessionID: id))
    }

    private func waitUntil(_ cond: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { throw WaitTimeout() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private struct WaitTimeout: Error {}
}
