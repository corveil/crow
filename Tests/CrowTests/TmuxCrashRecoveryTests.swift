import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowTerminal
@testable import CrowEngine
@testable import Crow

/// Covers the #588 tmux-server-crash auto-recovery: `handleTmuxServerCrash`
/// re-arms every managed work terminal and relaunches via the existing
/// `.shellReady` machinery (`--continue`, never a re-paste of a dispatched
/// initial plan), `tmuxCrashRecovering` drives the crash overlay and clears
/// once every tracked terminal settles, and the rebuild never re-runs a
/// stored claude command verbatim.
// Serialized for the same reason as DeferredLaunchTests: these tests overwrite
// the singleton `TmuxBackend.shared.onReadinessChanged` (via the rebuild's
// `wireTerminalReadiness()`) and then fire it directly.
@Suite("tmux crash auto-recovery (#588)", .serialized)
struct TmuxCrashRecoveryTests {

    @MainActor
    private struct Fixture {
        let appState = AppState()
        let service: SessionService

        init(name: String) {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("crow-crash-\(name)-\(UUID().uuidString)")
            service = SessionService(store: JSONStore(directory: tmp), appState: appState)
        }

        /// Seed a work session with one managed terminal that already launched
        /// its agent (the steady state when a crash hits).
        @discardableResult
        func seedLaunchedWorkTerminal(command: String? = nil) -> (sessionID: UUID, terminalID: UUID) {
            let sessionID = UUID()
            let terminalID = UUID()
            appState.sessions.append(Session(id: sessionID, name: "feat-\(terminalID)", kind: .work))
            appState.terminals[sessionID] = [SessionTerminal(
                id: terminalID, sessionID: sessionID, name: "Claude Code",
                cwd: "/tmp", command: command, isManaged: true, tmuxBinding: nil
            )]
            appState.terminalReadiness[terminalID] = .agentLaunched
            return (sessionID, terminalID)
        }
    }

    @MainActor
    @Test func crashSetsRecoveringFlagAndReArmsManagedTerminals() {
        let f = Fixture(name: "rearm")
        let (_, terminalID) = f.seedLaunchedWorkTerminal()

        f.service.handleTmuxServerCrash()

        #expect(f.appState.tmuxCrashRecovering)
        // Re-armed exactly like the manual restart path: fresh shell's
        // .shellReady drives launchAgent → autoLaunchCommand → --continue.
        #expect(f.appState.terminalReadiness[terminalID] == .uninitialized)
        #expect(f.appState.autoLaunchTerminals.contains(terminalID))
    }

    @MainActor
    @Test func crashHandlerIsReentrancySafe() {
        let f = Fixture(name: "reentrant")
        let (_, terminalID) = f.seedLaunchedWorkTerminal()

        f.service.handleTmuxServerCrash()
        // Simulate the terminal having progressed mid-recovery; a re-entrant
        // crash signal (run-loop pumping during shutdown) must not stomp it.
        f.appState.terminalReadiness[terminalID] = .shellReady
        f.service.handleTmuxServerCrash()

        #expect(f.appState.terminalReadiness[terminalID] == .shellReady)
    }

    @MainActor
    @Test func recoveringFlagClearsOnlyWhenAllTrackedTerminalsSettle() {
        let f = Fixture(name: "settle")
        let (_, terminalA) = f.seedLaunchedWorkTerminal()
        let (_, terminalB) = f.seedLaunchedWorkTerminal()

        f.service.handleTmuxServerCrash()
        #expect(f.appState.tmuxCrashRecovering)

        // First terminal comes back — the other is still rebuilding.
        TmuxBackend.shared.onReadinessChanged?(terminalA, .shellReady)
        #expect(f.appState.tmuxCrashRecovering)

        // Last terminal settles (a timeout also counts as settled: the user
        // gets the crash-flavored Retry overlay, not an eternal spinner).
        TmuxBackend.shared.onReadinessChanged?(terminalB, .timedOut)
        #expect(!f.appState.tmuxCrashRecovering)
    }

    @MainActor
    @Test func rapidRepeatCrashIsDebounced() {
        let f = Fixture(name: "debounce")
        let (_, terminalID) = f.seedLaunchedWorkTerminal()

        f.service.handleTmuxServerCrash()
        TmuxBackend.shared.onReadinessChanged?(terminalID, .shellReady)
        #expect(!f.appState.tmuxCrashRecovering)

        // Server dies again immediately (broken tmux install): the second
        // recovery inside the debounce window must not re-kill the panes.
        f.service.handleTmuxServerCrash()
        #expect(!f.appState.tmuxCrashRecovering)
        #expect(f.appState.terminalReadiness[terminalID] == .shellReady)
    }

    /// A terminal whose initial plan was never dispatched keeps its pending
    /// launch across a crash rebuild and pastes it exactly once — the prompt
    /// is neither lost nor double-dispatched.
    @MainActor
    @Test func pendingInitialLaunchSurvivesCrashAndPastesOnce() {
        let f = Fixture(name: "pending")
        let (_, terminalID) = f.seedLaunchedWorkTerminal()
        let command = "cd /tmp && claude \"$(cat plan.md)\""
        f.appState.terminalReadiness[terminalID] = .uninitialized
        f.appState.pendingLaunchCommands[terminalID] = command
        f.appState.autoLaunchTerminals.insert(terminalID)

        f.service.handleTmuxServerCrash()
        // The rebuild must not consume the never-dispatched launch.
        #expect(f.appState.pendingLaunchCommands[terminalID] == command)

        TmuxBackend.shared.onReadinessChanged?(terminalID, .shellReady)
        // Pasted and consumed — a later spurious .shellReady can't re-paste.
        #expect(f.appState.pendingLaunchCommands[terminalID] == nil)
        #expect(!f.appState.autoLaunchTerminals.contains(terminalID))
        #expect(f.appState.terminalReadiness[terminalID] == .agentLaunched)
    }

    /// The force-register rebuild mirrors the hydrate-clear: a managed work
    /// terminal must never re-run a stored claude command verbatim (that's
    /// the "re-ran the initial plan" failure #588 forbids); the Manager keeps
    /// its stored launch command, and unmanaged shells are untouched.
    @MainActor
    @Test func forceRegisterRebuildClearsManagedClaudeCommandsOnly() {
        let f = Fixture(name: "clear")
        let claudeCmd = "cd /tmp && claude \"$(cat plan.md)\""
        let (workSessionID, workTerminalID) = f.seedLaunchedWorkTerminal(command: claudeCmd)

        let unmanagedID = UUID()
        f.appState.terminals[workSessionID]?.append(SessionTerminal(
            id: unmanagedID, sessionID: workSessionID, name: "Shell",
            cwd: "/tmp", command: claudeCmd, isManaged: false, tmuxBinding: nil
        ))

        let managerSessionID = AppState.managerSessionID
        let managerTerminalID = UUID()
        f.appState.sessions.append(Session(id: managerSessionID, name: "Manager", kind: .manager))
        f.appState.terminals[managerSessionID] = [SessionTerminal(
            id: managerTerminalID, sessionID: managerSessionID, name: "Manager",
            cwd: "/tmp", command: "claude --permission-mode auto", isManaged: true, tmuxBinding: nil
        )]

        f.service.rebuildAllSurfaces(forceRegister: true)

        let workRows = f.appState.terminals[workSessionID] ?? []
        #expect(workRows.first(where: { $0.id == workTerminalID })?.command == nil)
        #expect(workRows.first(where: { $0.id == unmanagedID })?.command == claudeCmd)
        #expect(f.appState.terminals[managerSessionID]?.first?.command == "claude --permission-mode auto")
    }

    @MainActor
    @Test func manualRestartClearsStaleCrashFlag() {
        let f = Fixture(name: "manual")
        f.seedLaunchedWorkTerminal()
        f.appState.tmuxCrashRecovering = true

        f.service.restartTmuxServer()

        #expect(!f.appState.tmuxCrashRecovering)
    }
}
