import Foundation
import Testing
@testable import CrowGrok
@testable import CrowCore

@Suite("GrokAgent")
struct GrokAgentTests {
    private let agent = GrokAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .grok)
        #expect(agent.displayName == "Grok Build")
        #expect(agent.iconSystemName == "bolt.fill")
        #expect(agent.supportsRemoteControl == true)
        #expect(agent.launchCommandToken == "grok")
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == "/rename my-session\n")
    }

    @Test func autoLaunchCommandWorkSession() {
        let session = Session(name: "test", agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        // Work sessions launch a bare `grok` TUI — no `-p`, no prompt file.
        #expect(cmd?.hasSuffix("grok'\n") == true)
        #expect(cmd?.contains(" -p ") == false)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // Grok has no OTEL exporter and no `--rc` flag — remote control is
        // `crow send` typing into the TUI. Toggling these must not change the
        // work launch text.
        let session = Session(name: "test", agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            autoPermissionMode: false,
            telemetryPort: 4318
        )
        #expect(cmd?.hasSuffix("grok'\n") == true)
        #expect(cmd?.contains("OTEL_") == false)
        #expect(cmd?.contains("--rc") == false)
    }

    @Test func autoLaunchCommandJobSessionFirstLaunch() {
        // First job launch runs headlessly (`-p`), then chains into `-c` (#859).
        let session = Session(name: "job", kind: .job, agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(" --prompt-file ") == true)
        #expect(cmd?.contains("; ") == true)
        #expect(cmd?.contains(" && ") == false)
        #expect(cmd?.contains(" -c") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        // Auto-permission off → no bounded flags.
        #expect(cmd?.contains("--permission-mode") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSessionAutoPermissionMode() {
        // `.job` + autoPermissionMode adds bounded auto flags to both legs —
        // `--permission-mode auto` + hard `--deny`, never `--yolo`.
        let session = Session(name: "job", kind: .job, agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("--permission-mode auto") == true)
        #expect(cmd?.contains("--deny") == true)
        #expect(cmd?.contains("--yolo") == false)
        #expect(cmd?.contains("--always-approve") == false)
    }

    @Test func autoLaunchCommandReviewSessionFirstLaunch() {
        let session = Session(name: "review", kind: .review, agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(" --prompt-file ") == true)
        #expect(cmd?.contains(" -c") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandReviewNeverAutoApproves() {
        // Auto-permission is `.job`-only: a review is human-gated even when
        // reviewAutoPermissionMode is on (autoPermissionMode == true here).
        let session = Session(name: "review", kind: .review, agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("--permission-mode") == false)
        #expect(cmd?.contains("--deny") == false)
    }

    @Test func autoLaunchCommandReviewSessionSubsequentLaunch() {
        // After the initial prompt has been dispatched, a restart resumes the
        // TUI with `-c` (no headless re-run).
        var session = Session(name: "review", kind: .review, agentKind: .grok)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.contains(" -p ") == false)
        #expect(cmd?.contains(" -c") == true)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSubsequentLaunchCarriesAutoFlags() {
        var session = Session(name: "job", kind: .job, agentKind: .grok)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains(" -c") == true)
        #expect(cmd?.contains(" -p ") == false)
        #expect(cmd?.contains("--permission-mode auto") == true)
    }

    @Test func autoLaunchCommandManagerSessionUnsupported() {
        let session = Session(name: "manager", kind: .manager, agentKind: .grok)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd == nil)
    }

    @Test func managerLaunchCommandHasNoFlags() {
        let cmd = agent.managerLaunchCommand(
            sessionName: "my-session",
            remoteControlEnabled: true,
            autoPermissionMode: true,
            telemetryPort: 4318
        )
        #expect(cmd.hasSuffix("grok"))
        #expect(!cmd.contains("--rc"))
        #expect(!cmd.contains("--name"))
        #expect(!cmd.hasSuffix("\n"))
    }
}
