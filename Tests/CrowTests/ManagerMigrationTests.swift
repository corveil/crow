import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowCursor
import CrowPersistence
@testable import Crow

/// Locks down the legacy primary-Manager migration (#316). Before
/// SessionKind.manager existed the primary Manager was persisted as `.work`;
/// on upgrade it must become `.manager` BEFORE hydration's per-session loop,
/// otherwise the work-session branch clears its claude command and reroutes it
/// through the auto-launch path (dropping --auto-permission-mode).
@Suite("SessionService.migrateLegacyManagerKind")
struct ManagerMigrationTests {

    @Test
    func migratesLegacyWorkPrimaryManager() {
        var sessions = [
            Session(id: AppState.managerSessionID, name: "Manager", kind: .work),
            Session(name: "feature", kind: .work),
        ]
        let migrated = SessionService.migrateLegacyManagerKind(&sessions)
        #expect(migrated)
        #expect(sessions.first { $0.id == AppState.managerSessionID }?.kind == .manager)
        // Non-primary work session is untouched.
        #expect(sessions.first { $0.name == "feature" }?.kind == .work)
    }

    @Test
    func noOpWhenPrimaryAlreadyManager() {
        var sessions = [Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)]
        #expect(SessionService.migrateLegacyManagerKind(&sessions) == false)
        #expect(sessions[0].kind == .manager)
    }

    @Test
    func noOpWhenNoPrimaryManager() {
        var sessions = [Session(name: "work", kind: .work)]
        #expect(SessionService.migrateLegacyManagerKind(&sessions) == false)
    }

    /// Locks in the per-session `--name` label flow that `hydrateState` and
    /// `createManagerTerminal` both rely on (#316 review): distinct manager
    /// names must produce distinct `--name '…'` flags so additional managers
    /// show correct labels in the Remote Control panel.
    @MainActor
    @Test
    func managerCommandUsesSessionNameForRemoteControlLabel() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-cmd-\(UUID().uuidString)")
        let appState = AppState()
        appState.remoteControlEnabled = true
        appState.managerAutoPermissionMode = true
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState)

        // Register Claude so the dispatch path returns the Claude command.
        // Use a fresh registry to avoid bleed across tests.
        AgentRegistry.shared.register(ClaudeCodeAgent())

        let session2 = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        let session3 = Session(name: "Manager 3", kind: .manager, agentKind: .claudeCode)
        let cmd2 = service.managerCommand(for: session2)
        let cmd3 = service.managerCommand(for: session3)

        #expect(cmd2.contains("--name 'Manager 2'"))
        #expect(cmd3.contains("--name 'Manager 3'"))
        #expect(cmd2 != cmd3)
        #expect(cmd2.contains("--permission-mode auto"))
        #expect(cmd2.contains("--rc"))
    }

    /// CROW-433: a Manager session whose `agentKind` is `.cursor` must
    /// dispatch through `CursorAgent.managerLaunchCommand`, producing a
    /// `cursor-agent`-style command rather than a Claude one.
    @MainActor
    @Test
    func managerCommandDispatchesByAgentKind() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-cursor-\(UUID().uuidString)")
        let appState = AppState()
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState)

        AgentRegistry.shared.register(ClaudeCodeAgent())
        AgentRegistry.shared.register(CursorAgent())

        let claudeSession = Session(name: "Manager", kind: .manager, agentKind: .claudeCode)
        let cursorSession = Session(name: "Manager", kind: .manager, agentKind: .cursor)

        let claudeCmd = service.managerCommand(for: claudeSession)
        let cursorCmd = service.managerCommand(for: cursorSession)

        // Claude path keeps producing a `claude` invocation.
        #expect(claudeCmd.contains("claude"))
        // Cursor path emits the `agent` binary (Cursor's CLI name), not claude.
        #expect(cursorCmd.contains("agent"))
        #expect(!cursorCmd.contains("claude"))
    }

    /// #374: hydrating the Manager rebuilds its claude `command` to refresh the
    /// --rc/--name/--permission-mode flags. That rebuild must NOT drop the
    /// terminal's `tmuxBinding` — if it does, `rehydrateTerminalSurface` can't
    /// take the adopt path and spawns a fresh tmux window + claude every
    /// relaunch, leaking the prior Manager window in `crow-cockpit`.
    @MainActor
    @Test
    func hydratePreservesManagerTmuxBinding() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-hydrate-mgr-\(UUID().uuidString)")
        let store = JSONStore(directory: tmp)
        let binding = TmuxBinding(socketPath: "/tmp/crow.sock", sessionName: "crow-cockpit", windowIndex: 5)
        let terminalID = UUID()
        store.mutate { data in
            data.sessions = [Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)]
            data.terminals = [SessionTerminal(
                id: terminalID, sessionID: AppState.managerSessionID,
                name: "Manager", cwd: tmp.path,
                command: "claude --rc --name 'Manager'", isManaged: false,
                tmuxBinding: binding
            )]
        }

        let appState = AppState()
        appState.remoteControlEnabled = true  // so the rebuilt command carries --rc/--name
        let service = SessionService(store: store, appState: appState)
        service.hydrateState()

        let row = appState.terminals[AppState.managerSessionID]?.first { $0.id == terminalID }
        // Binding preserved → relaunch will adopt the live window, not register a new one.
        #expect(row?.tmuxBinding == binding)
        // Command was still rebuilt (proves we didn't just skip the rebuild).
        #expect(row?.command?.contains("--name 'Manager'") == true)
        // Rebuild also re-seeds the Remote Control active set for the row.
        #expect(appState.remoteControlActiveTerminals.contains(terminalID))
    }

    /// Same in-place-mutation guarantee for the work-session hydration branch
    /// that clears a managed terminal's claude command (#374). The command is
    /// nilled (so the surface starts as a plain shell) but the `tmuxBinding`
    /// must survive so the work terminal also re-adopts its window.
    @MainActor
    @Test
    func hydratePreservesWorkTerminalTmuxBinding() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-hydrate-work-\(UUID().uuidString)")
        let store = JSONStore(directory: tmp)
        let binding = TmuxBinding(socketPath: "/tmp/crow.sock", sessionName: "crow-cockpit", windowIndex: 9)
        let sessionID = UUID()
        let terminalID = UUID()
        store.mutate { data in
            data.sessions = [Session(id: sessionID, name: "feature", kind: .work)]
            data.terminals = [SessionTerminal(
                id: terminalID, sessionID: sessionID,
                name: "Claude Code", cwd: tmp.path,
                command: "claude --continue", isManaged: true,
                tmuxBinding: binding
            )]
        }

        let appState = AppState()
        let service = SessionService(store: store, appState: appState)
        service.hydrateState()

        let row = appState.terminals[sessionID]?.first { $0.id == terminalID }
        #expect(row?.tmuxBinding == binding)
        // Managed work terminal's claude command is cleared so it starts as a shell.
        #expect(row?.command == nil)
    }
}
