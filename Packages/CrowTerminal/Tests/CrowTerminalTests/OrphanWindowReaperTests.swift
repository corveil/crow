import Foundation
import Testing
@testable import CrowTerminal

/// Policy tests for the conservative orphan-window reaper (#408): reap a
/// cockpit window only when NO live terminal references it AND it is sitting at
/// a bare login shell. Pure over `shouldReapWindow`, so no tmux needed.
@Suite("Orphan cockpit window reaper policy (#408)")
struct OrphanWindowReaperTests {

    @Test func reapsUnboundBareShell() {
        #expect(TmuxBackend.shouldReapWindow(index: 3, command: "zsh", keep: []))
        #expect(TmuxBackend.shouldReapWindow(index: 3, command: "-zsh", keep: []))
        #expect(TmuxBackend.shouldReapWindow(index: 3, command: "bash", keep: []))
        #expect(TmuxBackend.shouldReapWindow(index: 3, command: "sh", keep: []))
    }

    @Test func keepsBoundWindowEvenWhenBareShell() {
        // A terminal references it (e.g. the agent exited and the user is now at
        // the shell) — must be preserved.
        #expect(!TmuxBackend.shouldReapWindow(index: 3, command: "zsh", keep: [3]))
    }

    @Test func keepsWindowRunningAProcess() {
        // Anything that isn't a bare login shell is left alone.
        #expect(!TmuxBackend.shouldReapWindow(index: 4, command: "claude", keep: []))
        #expect(!TmuxBackend.shouldReapWindow(index: 4, command: "node", keep: []))
        #expect(!TmuxBackend.shouldReapWindow(index: 4, command: "codex", keep: []))
        #expect(!TmuxBackend.shouldReapWindow(index: 4, command: "tail", keep: []))  // session anchor
    }
}

/// Targeted-auto policy (CROW-581): additionally reap positively-identified
/// orphaned AGENT windows after a one-pass grace, while never touching a
/// Manager, the anchor (index 0), a bound window, or an unknown/infra window.
@Suite("Targeted-auto orphan reaper policy (CROW-581)")
struct TargetedOrphanReaperTests {
    let agents: Set<String> = ["Claude Code", "Cursor", "OpenAI Codex", "OpenCode"]

    private func reap(_ i: Int, _ name: String, _ cmd: String,
                      keep: Set<Int> = [], seen: Bool = false) -> Bool {
        TmuxBackend.shouldReapOrphanWindow(
            index: i, name: name, command: cmd, keep: keep,
            agentWindowNames: agents, seenOrphanedLastPass: seen)
    }

    @Test func neverReapsManagerWindow() {
        #expect(!reap(5, "Manager", "zsh"))          // bare-shell Manager
        #expect(!reap(5, "Manager 2", "node", seen: true))  // running-agent Manager, even after grace
        #expect(!reap(5, "manager", "node", seen: true))    // case-insensitive
    }

    @Test func neverReapsAnchorOrBoundOrInfra() {
        #expect(!reap(0, "Claude Code", "node", seen: true))   // anchor index
        #expect(!reap(3, "Claude Code", "node", keep: [3], seen: true))  // bound
        #expect(!reap(4, "logs", "tail", seen: true))          // unknown/infra, not an agent name
    }

    @Test func reapsForgottenBareShellImmediately() {
        #expect(reap(3, "Claude Code", "zsh"))       // exited agent → bare shell → reap now
        #expect(reap(3, "some-shell", "bash"))
    }

    @Test func reapsRunningAgentOnlyAfterGrace() {
        #expect(!reap(6, "Claude Code", "node", seen: false))  // first pass → spare (grace)
        #expect(reap(6, "Claude Code", "node", seen: true))    // second pass → reap
        #expect(reap(6, "Cursor", "cursor", seen: true))
    }
}
