import Foundation
import Testing
import CrowCore
@testable import CrowClaude

/// Locks in the resume-vs-initial-prompt decision in
/// `ClaudeCodeAgent.autoLaunchCommand` (#588): work sessions always resume
/// with `--continue`; review/job sessions read their pre-written prompt file
/// exactly once (`reviewPromptDispatched == false`) and resume with
/// `--continue` on every relaunch after that — including the rebuild after a
/// tmux server crash. Manager `.autoLaunchCommand` is a dead production path
/// (Managers use `managerLaunchCommand`) and must still resume-by-id, never
/// `--continue` (CROW-1281).
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

    @Test func workAlwaysResumesWithContinue() throws {
        for dispatched in [false, true] {
            let cmd = try #require(command(kind: .work, dispatched: dispatched))
            #expect(cmd.hasSuffix(" --continue\n"))
            #expect(!cmd.contains("$(<"))
            #expect(!cmd.contains("--resume"))
        }
    }

    @Test func managerAutoLaunchResumesByIdNeverContinue() throws {
        let fresh = try #require(command(kind: .manager, dispatched: false))
        #expect(!fresh.contains("--continue"))
        #expect(!fresh.contains("--resume"))

        var session = Session(name: "s", kind: .manager)
        session.harnessConversationID = "ses-mgr"
        let resumed = try #require(agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        ))
        #expect(resumed.contains("--resume 'ses-mgr'"))
        #expect(!resumed.contains("--continue"))
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
        // must not grow a silent bypass, blanket `--add-dir`, or
        // `--permission-prompts none` (CROW-1215 — print-mode only).
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
        #expect(!cmd.contains("--permission-prompts"))

        let manager = agent.managerLaunchCommand(
            sessionName: "Manager",
            remoteControlEnabled: true,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(manager.contains("--permission-mode auto"))
        #expect(!manager.contains("--dangerously-skip-permissions"))
        #expect(!manager.contains("--add-dir"))
        #expect(!manager.contains("--permission-prompts"))
    }

    /// CROW-1215: `--permission-prompts none` is print-mode only (`claude -p`).
    /// Crow launches the interactive TUI in a tmux PTY, so emitting it would
    /// not convert extra-workdir auto-mode Read stalls into denials. Pin that
    /// no launch path emits it — a future "wire it for `.job`" change has to
    /// fail this first.
    @Test func launchNeverEmitsPermissionPromptsNone() throws {
        var resumed = Session(name: "review", kind: .review)
        resumed.reviewPromptDispatched = true
        var resumedJob = Session(name: "job", kind: .job)
        resumedJob.reviewPromptDispatched = true

        let sessions: [Session] = [
            Session(name: "work", kind: .work),
            Session(name: "job", kind: .job),
            Session(name: "review", kind: .review),
            Session(name: "manager", kind: .manager),
            resumed,
            resumedJob,
        ]
        for session in sessions {
            let cmd = try #require(agent.autoLaunchCommand(
                session: session,
                worktreePath: "/tmp/wt",
                remoteControlEnabled: true,
                autoPermissionMode: true,
                telemetryPort: nil))
            #expect(!cmd.contains("--permission-prompts"),
                    "\(session.kind) auto-launch emitted --permission-prompts")
        }

        let manager = agent.managerLaunchCommand(
            sessionName: "Manager",
            remoteControlEnabled: true,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(!manager.contains("--permission-prompts"))
    }

    @Test func managerLaunchCommandResumesByIdNeverContinue() {
        // CROW-1281: Manager reboot must resume-by-id, not `--continue`.
        // `--continue` is cwd-scoped; extra Managers sharing {devRoot} shuffle.
        let fresh = agent.managerLaunchCommand(
            sessionName: "Manager 2",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(!fresh.contains("--continue"))
        #expect(!fresh.contains("--resume"))

        let id = "dfb5e99e-3195-4342-89fd-4025f1b7f09e"
        let resumed = agent.managerLaunchCommand(
            sessionName: "Manager 2",
            remoteControlEnabled: true,
            autoPermissionMode: true,
            telemetryPort: nil,
            conversationID: id
        )
        #expect(resumed.contains("--resume '\(id)'"))
        #expect(!resumed.contains("--continue"))
        #expect(resumed.contains("--name 'Manager 2'"))
        #expect(resumed.contains("--permission-mode auto"))
        let blank = agent.managerLaunchCommand(
            sessionName: "Manager",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil,
            conversationID: "  "
        )
        #expect(!blank.contains("--resume"))
    }
}
