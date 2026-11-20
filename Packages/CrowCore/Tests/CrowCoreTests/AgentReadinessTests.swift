import Foundation
import Testing
@testable import CrowCore

/// `agent_state` derivation (CROW-1475).
@Suite("AgentReadiness")
struct AgentReadinessTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func state(_ inputs: AgentReadiness.Inputs) -> AgentReadinessState? {
        AgentReadiness.state(inputs, now: now)
    }

    // MARK: - No agent / not launched

    @Test func noAgentTerminalIsNil() {
        #expect(state(.init(hasAgentTerminal: false, activity: .working)) == nil)
    }

    @Test func surfaceThatNeverCameUpIsExited() {
        #expect(state(.init(hasAgentTerminal: true, readiness: .failed)) == .exited)
        #expect(state(.init(hasAgentTerminal: true, readiness: .timedOut)) == .exited)
    }

    @Test func workTerminalBeforeDeferredLaunchIsStarting() {
        for readiness in [TerminalReadiness.uninitialized, .surfaceCreated, .shellReady] {
            #expect(state(.init(hasAgentTerminal: true, readiness: readiness, paneCommand: "zsh")) == .starting)
        }
    }

    // MARK: - Launch window

    @Test func launchWithNoHookYetIsStartingEvenOnAShellPane() {
        // The launch command was typed but the agent hasn't exec'd: a shell
        // pane means "not up yet", not "exited".
        let inputs = AgentReadiness.Inputs(
            hasAgentTerminal: true, readiness: .agentLaunched, paneCommand: "zsh",
            launchPending: true)
        #expect(state(inputs) == .starting)
    }

    @Test func hooklessAgentIsTakenAsUpAfterTheGrace() {
        // Antigravity sends no startup hook: once its process owns the pane
        // past the grace, it follows activity instead of reading starting forever.
        var inputs = AgentReadiness.Inputs(
            hasAgentTerminal: true, readiness: .agentLaunched, paneCommand: "agy",
            launchPending: true, launchedAt: now.addingTimeInterval(-2), activity: .idle)
        #expect(state(inputs) == .starting)
        inputs.launchedAt = now.addingTimeInterval(-(AgentReadiness.hooklessLaunchGrace + 1))
        #expect(state(inputs) == .idle)
        // Still a shell past the grace: the launch never took, not "up".
        inputs.paneCommand = "zsh"
        #expect(state(inputs) == .starting)
        // Unknown pane: no evidence the agent is up.
        inputs.paneCommand = nil
        #expect(state(inputs) == .starting)
    }

    @Test func launchPendingWinsOverStaleActivity() {
        let inputs = AgentReadiness.Inputs(
            hasAgentTerminal: true, paneCommand: "claude", launchPending: true, activity: .done)
        #expect(state(inputs) == .starting)
    }

    @Test func composerSettleKeepsAFreshAnnounceStarting() {
        let fresh = AgentReadiness.Inputs(
            hasAgentTerminal: true, paneCommand: "cursor-agent",
            announcedAt: now.addingTimeInterval(-0.5), activity: .idle)
        #expect(state(fresh) == .starting)

        var settled = fresh
        settled.announcedAt = now.addingTimeInterval(-(AgentReadiness.composerSettle + 0.1))
        #expect(state(settled) == .idle)
    }

    @Test func settleDoesNotHideAPromptTakenAsArgv() {
        // SessionStart then UserPromptSubmit within the settle: working, not starting.
        let inputs = AgentReadiness.Inputs(
            hasAgentTerminal: true, paneCommand: "claude",
            announcedAt: now.addingTimeInterval(-0.2), activity: .working)
        #expect(state(inputs) == .working)
    }

    // MARK: - Running agent

    @Test func activityMapsToState() {
        func s(_ activity: AgentActivityState, notification: Bool = false, turnEnded: Bool = false) -> AgentReadinessState? {
            state(.init(hasAgentTerminal: true, readiness: .agentLaunched, paneCommand: "claude",
                        activity: activity, hasPendingNotification: notification, turnEnded: turnEnded))
        }
        #expect(s(.idle) == .idle)
        #expect(s(.done) == .idle)
        #expect(s(.working) == .working)
        #expect(s(.waiting, notification: true) == .waitingPermission)
        // A permission request mid-turn may arrive before its notification.
        #expect(s(.waiting) == .waitingPermission)
        // StopFailure: `.waiting`, no notification, turn over — back at the prompt.
        #expect(s(.waiting, turnEnded: true) == .idle)
    }

    @Test func managerWithoutTrackedReadinessFollowsActivity() {
        #expect(state(.init(hasAgentTerminal: true, readiness: nil, paneCommand: "claude", activity: .working)) == .working)
    }

    @Test func unknownPaneCommandDoesNotMeanExited() {
        #expect(state(.init(hasAgentTerminal: true, readiness: .agentLaunched, paneCommand: nil, activity: .idle)) == .idle)
        // An agent that shows up as its runtime is still an agent.
        #expect(state(.init(hasAgentTerminal: true, readiness: .agentLaunched, paneCommand: "node", activity: .idle)) == .idle)
    }

    // MARK: - Exit

    @Test func shellPaneAfterAnnounceIsExited() {
        let inputs = AgentReadiness.Inputs(
            hasAgentTerminal: true, readiness: .agentLaunched, paneCommand: "zsh", activity: .working)
        #expect(state(inputs) == .exited)
    }

    @Test func managerExitMonitorIsExited() {
        #expect(state(.init(hasAgentTerminal: true, paneCommand: "claude", processExited: true, activity: .idle)) == .exited)
    }

    @Test func paneIsShellRecognizesShellsAndWrapper() {
        for command in ["zsh", "-zsh", "/bin/bash", "fish", "crow-shell-wrapper.sh", " sh\n"] {
            #expect(AgentReadiness.paneIsShell(command), "\(command)")
        }
        for command in ["claude", "node", "cursor-agent", "codex", "", "2.1.300"] {
            #expect(!AgentReadiness.paneIsShell(command), "\(command)")
        }
    }

    @Test func rawValuesMatchTheDocumentedContract() {
        #expect(AgentReadinessState.allCases.map(\.rawValue)
            == ["starting", "idle", "working", "waiting_permission", "exited"])
    }

    // MARK: - Hook state bookkeeping

    @MainActor
    @Test func firstHookAfterLaunchAnnouncesAndPromptStampsLastPrompt() {
        let hook = SessionHookState()
        #expect(!hook.agentLaunchPending)
        hook.agentLaunchPending = true

        let t1 = Date(timeIntervalSince1970: 10)
        hook.noteHookEventForReadiness("SessionStart", at: t1)
        #expect(!hook.agentLaunchPending)
        #expect(hook.agentAnnouncedAt == t1)
        #expect(hook.lastPromptAt == nil)

        let t2 = Date(timeIntervalSince1970: 20)
        hook.noteHookEventForReadiness("UserPromptSubmit", at: t2)
        #expect(hook.lastPromptAt == t2)
        // Only the first hook after a launch is the announce.
        #expect(hook.agentAnnouncedAt == t1)
    }

    @MainActor
    @Test func relaunchResetMarksPendingButKeepsLastPrompt() {
        let hook = SessionHookState()
        let prompt = Date(timeIntervalSince1970: 5)
        hook.noteHookEventForReadiness("UserPromptSubmit", at: prompt)
        hook.agentAnnouncedAt = prompt
        hook.resetForAgentRelaunch()
        #expect(hook.agentLaunchPending)
        #expect(hook.agentAnnouncedAt == nil)
        #expect(hook.lastPromptAt == prompt)
    }

    @MainActor
    @Test func noteAgentLaunchCreatesHookStateForAFreshSession() {
        let appState = AppState()
        let id = UUID()
        #expect(appState.existingHookState(for: id) == nil)
        appState.noteAgentLaunch(sessionID: id)
        #expect(appState.existingHookState(for: id)?.agentLaunchPending == true)
    }
}
