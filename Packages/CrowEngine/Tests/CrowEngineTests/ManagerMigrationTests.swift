import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowCursor
import CrowPersistence
@testable import CrowEngine

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
        // `AgentRegistry.shared` is a process-wide singleton with no reset
        // hook — repeated registrations of the same `AgentKind` are
        // idempotent, so this is safe under `--parallel`, but be aware the
        // registry survives across tests rather than being scoped per test.
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
        // Cursor path emits Cursor's own CLI, not claude. Asserted on the
        // unambiguous `cursor-agent` name rather than a bare `agent` substring —
        // that substring also matches grok-build's `agent`, which is the exact
        // mix-up CROW-989 fixed, so a loose assertion here would pass on it.
        #expect(cursorCmd.contains("cursor-agent"))
        #expect(!cursorCmd.contains("claude"))
    }

    /// #582 / #834: the "+" agent picker passes a one-shot `AgentKind` into
    /// `createManagerSession`. `resolvedManagerAgentKind` must prefer that
    /// explicit choice over the configured Manager default — but only when an
    /// agent is registered for it (the CROW-593 gate, now shared across every
    /// creation surface). This is the single choke point both `create-manager`
    /// RPC surfaces (web + daemon) funnel through.
    @MainActor
    @Test
    func resolvedManagerAgentKindPrefersExplicitOverride() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-resolve-override-\(UUID().uuidString)")
        let appState = AppState()
        appState.defaultAgentKind = .claudeCode
        appState.agentsByKind = ["manager": .claudeCode]
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState)

        // Register Cursor so the explicit pick is honored (idempotent under the
        // process-wide singleton). registeredKind passthrough proven directly.
        AgentRegistry.shared.register(CursorAgent())
        #expect(AgentRegistry.shared.registeredKind(.cursor) == .cursor)

        // Explicit *registered* pick wins over both agentsByKind["manager"] and
        // the default.
        #expect(service.resolvedManagerAgentKind(.cursor) == .cursor)
        // The configured default is left untouched (no config mutation).
        #expect(appState.agentsByKind["manager"] == .claudeCode)
        #expect(appState.defaultAgentKind == .claudeCode)

        // #834: an explicit but *unregistered* kind is rejected by the gate and
        // falls back to the configured Manager default — a Manager can't be
        // persisted with a kind that would silently launch as the default.
        let unregistered = AgentKind(rawValue: "crow-834-unregistered-manager")
        #expect(AgentRegistry.shared.agent(for: unregistered) == nil)
        #expect(service.resolvedManagerAgentKind(unregistered) == .claudeCode)
    }

    /// #582: with no explicit pick (the RPC / single-agent path passes `nil`),
    /// resolution falls back to `agentsByKind["manager"] ?? defaultAgentKind`,
    /// preserving the pre-picker behavior.
    @MainActor
    @Test
    func resolvedManagerAgentKindFallsBackToConfigDefault() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-resolve-default-\(UUID().uuidString)")
        let appState = AppState()

        // Per-action override present → it wins.
        appState.defaultAgentKind = .claudeCode
        appState.agentsByKind = ["manager": .cursor]
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState)
        #expect(service.resolvedManagerAgentKind(nil) == .cursor)

        // No per-action override → falls through to defaultAgentKind.
        appState.agentsByKind = [:]
        appState.defaultAgentKind = .codex
        #expect(service.resolvedManagerAgentKind(nil) == .codex)
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
        // The command rebuild resolves the Manager's agent through the
        // process-wide `AgentRegistry.shared`, which is NOT scoped per test (see
        // the note in `managerCommandIsIdempotent`). Register Claude Code here
        // rather than relying on a sibling test having done so first — under
        // `--parallel` the ordering isn't guaranteed, and without it the rebuild
        // falls back to a command carrying neither `--name` nor remote control.
        // Registration is idempotent, so this is safe to repeat.
        AgentRegistry.shared.register(ClaudeCodeAgent())
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
