import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowCursor
import CrowCodex
import CrowPersistence
@testable import CrowEngine

@Suite("ManagerIdentity (CROW-1281)")
struct ManagerIdentityTests {
    @Test func primaryStaysAtRequestedCwd() {
        let id = AppState.managerSessionID
        let root = "/Users/x/Dev"
        #expect(ManagerIdentity.resolvedCwd(
            requested: root, sessionID: id, isPrimary: true, devRoot: root) == root)
    }

    @Test func extraManagerSharingDevRootIsIsolated() {
        let extra = UUID()
        let root = "/Users/x/Dev"
        let isolated = ManagerIdentity.resolvedCwd(
            requested: root, sessionID: extra, isPrimary: false, devRoot: root)
        #expect(isolated == "\(root)/.crow/managers/\(extra.uuidString)")
        #expect(isolated != root)
    }

    @Test func extraManagersGetDistinctDirectories() {
        let root = "/Users/x/Dev"
        let a = UUID()
        let b = UUID()
        let cwdA = ManagerIdentity.resolvedCwd(
            requested: root, sessionID: a, isPrimary: false, devRoot: root)
        let cwdB = ManagerIdentity.resolvedCwd(
            requested: root, sessionID: b, isPrimary: false, devRoot: root)
        #expect(cwdA != cwdB)
    }

    @Test func alreadyUniqueCwdIsLeftAlone() {
        let extra = UUID()
        let root = "/Users/x/Dev"
        let other = "/Users/x/elsewhere"
        #expect(ManagerIdentity.resolvedCwd(
            requested: other, sessionID: extra, isPrimary: false, devRoot: root) == other)
    }

    @Test func claudeExtraManagerGetsAddDirOfRoot() {
        let extra = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        let root = "/Users/x/Dev"
        let cwd = ManagerIdentity.directory(devRoot: root, sessionID: extra.id)
        #expect(ManagerIdentity.additionalDirectory(for: extra, cwd: cwd, devRoot: root) == root)
        let primary = Session(
            id: AppState.managerSessionID, name: "Manager",
            kind: .manager, agentKind: .claudeCode)
        #expect(ManagerIdentity.additionalDirectory(
            for: primary, cwd: root, devRoot: root) == nil)
        let cursor = Session(name: "Manager 2", kind: .manager, agentKind: .cursor)
        #expect(ManagerIdentity.additionalDirectory(
            for: cursor, cwd: cwd, devRoot: root) == nil)
        // An extra Manager that already had a unique cwd (not the identity
        // dir) must not grow `--add-dir` of the whole development root.
        #expect(ManagerIdentity.additionalDirectory(
            for: extra, cwd: "/Users/x/elsewhere", devRoot: root) == nil)
    }

    @Test func prepareDirectoryCreatesIdentityTree() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-identity-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent("devroot")
        let extra = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# root\n".write(
            to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let dest = ManagerIdentity.directory(devRoot: root.path, sessionID: extra)
        ManagerIdentity.prepareDirectory(at: dest, orchestrationRoot: root.path)
        #expect(FileManager.default.fileExists(atPath: dest))
        #expect(FileManager.default.fileExists(
            atPath: (dest as NSString).appendingPathComponent("CLAUDE.md")))
        #expect(FileManager.default.fileExists(
            atPath: (dest as NSString).appendingPathComponent("CLAUDE.crow.md")))
        try? FileManager.default.removeItem(at: tmp)
    }
}

@Suite("Manager resume-by-id command (CROW-1281)")
@MainActor
struct ManagerResumeCommandTests {
    private func service() -> SessionService {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-resume-\(UUID().uuidString)")
        return SessionService(store: JSONStore(directory: tmp), appState: AppState())
    }

    @Test func managerCommandResumesClaudeByIdNotContinue() {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let svc = service()
        var session = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        session.harnessConversationID = "claude-ses-99"
        let cmd = svc.managerCommand(for: session)
        #expect(cmd.contains("--resume 'claude-ses-99'"))
        #expect(!cmd.contains("--continue"))
    }

    @Test func managerCommandResumesCursorByChatId() {
        AgentRegistry.shared.register(CursorAgent())
        let svc = service()
        var session = Session(name: "Manager 2", kind: .manager, agentKind: .cursor)
        session.harnessConversationID = "chat-22"
        let cmd = svc.managerCommand(for: session)
        #expect(cmd.contains("--resume 'chat-22'"))
        #expect(!cmd.contains("--continue"))
        #expect(!cmd.contains("claude"))
    }

    @Test func managerCommandResumesCodexByThreadIdNotLast() {
        AgentRegistry.shared.register(OpenAICodexAgent())
        let svc = service()
        var session = Session(name: "Manager 2", kind: .manager, agentKind: .codex)
        session.harnessConversationID = "thread-7"
        let cmd = svc.managerCommand(for: session)
        #expect(cmd.contains("resume 'thread-7'"))
        #expect(!cmd.contains("--last"))
    }

    @Test func twoManagersWithIdsProduceDistinctResumeCommands() {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let svc = service()
        var a = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        var b = Session(name: "Manager 3", kind: .manager, agentKind: .claudeCode)
        a.harnessConversationID = "ses-a"
        b.harnessConversationID = "ses-b"
        let cmdA = svc.managerCommand(for: a)
        let cmdB = svc.managerCommand(for: b)
        #expect(cmdA.contains("--resume 'ses-a'"))
        #expect(cmdB.contains("--resume 'ses-b'"))
        #expect(cmdA != cmdB)
    }

    @Test func recreateRebuildsExtraManagerCommandFromPersistedId() {
        // Recreate of a secondary Manager must not reuse a stale stored
        // command from before the conversation id was captured.
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-recreate-\(UUID().uuidString)")
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let svc = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        var session = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        session.harnessConversationID = "after-hook-id"
        appState.sessions.append(session)
        let terminal = SessionTerminal(
            sessionID: session.id, name: session.name,
            cwd: tmp.path, command: "claude --rc --name 'Manager 2'")
        appState.terminals[session.id] = [terminal]
        store.mutate {
            $0.sessions.append(session)
            $0.terminals.append(terminal)
        }
        #expect(svc.managerCommand(for: session).contains("--resume 'after-hook-id'"))
        // Primary still routes recreate to restartManager.
        #expect(SessionService.shouldRestartPrimaryManagerOnRecreate(sessionID: session.id) == false)
    }
}
