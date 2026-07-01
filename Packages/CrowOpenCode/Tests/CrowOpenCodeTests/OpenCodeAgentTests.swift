import Foundation
import Testing
@testable import CrowOpenCode
@testable import CrowCore

@Suite("OpenCodeAgent")
struct OpenCodeAgentTests {
    private let agent = OpenCodeAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .openCode)
        #expect(agent.displayName == "OpenCode")
        #expect(agent.iconSystemName == "chevron.left.forwardslash.chevron.right")
        #expect(agent.supportsRemoteControl == true)
        #expect(agent.launchCommandToken == "opencode")
    }

    @Test func autoLaunchCommandWorkSession() {
        let session = Session(name: "test", agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        // Work sessions launch a bare `opencode` TUI — no `run` subcommand,
        // no prompt file, no flags. The tail is `opencode\n`.
        #expect(cmd?.hasSuffix("opencode\n") == true)
        #expect(cmd?.contains(" run ") == false)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // OpenCode has no OTEL exporter and no `--rc` flag — remote control
        // is `crow send` typing into the TUI. Toggling these must not change
        // the work launch text.
        let session = Session(name: "test", agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            autoPermissionMode: false,
            telemetryPort: 4318
        )
        #expect(cmd?.hasSuffix("opencode\n") == true)
        #expect(cmd?.contains("OTEL_") == false)
        #expect(cmd?.contains("--rc") == false)
    }

    @Test func autoLaunchCommandJobSessionFirstLaunch() {
        // First job launch (reviewPromptDispatched == false) drives the agent
        // headlessly via `opencode run` with the pre-written job prompt.
        let session = Session(name: "job", kind: .job, agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(" run ") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSessionAutoPermissionMode() {
        // `.job` + autoPermissionMode adds `--dangerously-skip-permissions`
        // (OpenCode's unattended auto-approve; the closest analog to Claude's
        // `--permission-mode auto`).
        let session = Session(name: "job", kind: .job, agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("--dangerously-skip-permissions") == true)
    }

    @Test func autoLaunchCommandReviewSessionFirstLaunch() {
        // First review launch passes the pre-written `.crow-review-prompt.md`
        // (agent-aware inlined SKILL body — see SessionService.buildReviewPrompt).
        // Review leaves auto-permission off, so no skip-permissions flag.
        let session = Session(name: "review", kind: .review, agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(" run ") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.contains("--dangerously-skip-permissions") == false)
    }

    @Test func autoLaunchCommandReviewSessionSubsequentLaunch() {
        // After the initial prompt has been dispatched, restarting Crow
        // resumes the TUI with a bare `opencode` (no headless re-run).
        var session = Session(name: "review", kind: .review, agentKind: .openCode)
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
        #expect(cmd?.contains(" run ") == false)
        #expect(cmd?.hasSuffix("opencode\n") == true)
    }

    @Test func autoLaunchCommandManagerSessionUnsupported() {
        // Manager sessions never auto-launch — Crow drives them externally.
        let session = Session(name: "manager", kind: .manager, agentKind: .openCode)
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
        // OpenCode has no `--rc`/`--name`/permission-mode analog for the
        // Manager terminal — the command is just the resolved binary token.
        let cmd = agent.managerLaunchCommand(
            sessionName: "my-session",
            remoteControlEnabled: true,
            autoPermissionMode: true,
            telemetryPort: 4318
        )
        #expect(cmd.hasSuffix("opencode"))
        #expect(!cmd.contains("--rc"))
        #expect(!cmd.contains("--name"))
        #expect(!cmd.hasSuffix("\n"))
    }
}
