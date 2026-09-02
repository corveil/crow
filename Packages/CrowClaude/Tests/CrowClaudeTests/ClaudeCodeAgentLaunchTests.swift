import Foundation
import Testing
import CrowCore
@testable import CrowClaude

/// Locks in the resume-vs-initial-prompt decision in
/// `ClaudeCodeAgent.autoLaunchCommand` (#588): work/manager sessions always
/// resume with `--continue`; review/job sessions read their pre-written
/// prompt file exactly once (`reviewPromptDispatched == false`) and resume
/// with `--continue` on every relaunch after that — including the rebuild
/// after a tmux server crash.
@Suite("ClaudeCodeAgent.autoLaunchCommand resume semantics")
struct ClaudeCodeAgentLaunchTests {

    private let agent = ClaudeCodeAgent()

    @Test func usesAlternateScreen() {
        // Claude Code is the one confirmed smcup TUI; CROW-1010 keeps the
        // alt-buffer path here and the unified 50k on inline agents.
        #expect(agent.usesAlternateScreen == true)
    }

    private func command(kind: SessionKind, dispatched: Bool) -> String? {
        agent.autoLaunchCommand(
            session: Session(name: "s", kind: kind, reviewPromptDispatched: dispatched),
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
    }

    @Test func workAndManagerAlwaysResume() throws {
        for kind in [SessionKind.work, .manager] {
            for dispatched in [false, true] {
                let cmd = try #require(command(kind: kind, dispatched: dispatched))
                #expect(cmd.hasSuffix(" --continue\n"))
                #expect(!cmd.contains("$(<"))
            }
        }
    }

    @Test func reviewAndJobReadPromptFileOnFirstLaunchOnly() throws {
        let review = try #require(command(kind: .review, dispatched: false))
        #expect(review.contains("_CROW_P=$(< '/tmp/wt/.crow-review-prompt.md')"))
        #expect(review.contains("eval \""))
        #expect(review.contains("claude $(printf '%q'"))
        #expect(!review.contains("--continue"))

        let job = try #require(command(kind: .job, dispatched: false))
        #expect(job.contains("_CROW_P=$(< '/tmp/wt/.crow-job-prompt.md')"))
        #expect(!job.contains("--continue"))
    }

    @Test func reviewAndJobResumeAfterPromptDispatched() throws {
        for kind in [SessionKind.review, .job] {
            let cmd = try #require(command(kind: kind, dispatched: true))
            #expect(cmd.hasSuffix(" --continue\n"))
            #expect(!cmd.contains("$(<"))
        }
    }

    @Test func sessionRenameSlashCommandIsOptIn() {
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == "/rename my-session\n")
    }

    @Test func autoPermissionEmitsAutoModeWithoutBypassOrAddDir() throws {
        // CROW-1176: auto is no longer stall-free (≥ 2.1.257 extra-workdir Read
        // prompt). The launch line still carries `--permission-mode auto` and
        // must not grow a silent bypass or blanket `--add-dir`.
        let cmd = try #require(agent.autoLaunchCommand(
            session: Session(name: "s", kind: .job, reviewPromptDispatched: true),
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        ))
        #expect(cmd.contains("--permission-mode auto"))
        #expect(!cmd.contains("--dangerously-skip-permissions"))
        #expect(!cmd.contains("bypassPermissions"))
        #expect(!cmd.contains("--add-dir"))

        let manager = agent.managerLaunchCommand(
            sessionName: "Manager",
            remoteControlEnabled: true,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(manager.contains("--permission-mode auto"))
        #expect(!manager.contains("--dangerously-skip-permissions"))
        #expect(!manager.contains("--add-dir"))
    }
}
