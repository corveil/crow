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
        // First job launch (reviewPromptDispatched == false) pipes the prompt
        // into the interactive TUI so the session stays resident (#547).
        let session = Session(name: "job", kind: .job, agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains("cat ") == true)
        #expect(cmd?.contains(" | ") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.contains(" run ") == false)
        #expect(cmd?.contains("--prompt") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSessionAutoPermissionMode() {
        // `.job` + autoPermissionMode adds `--auto` only when the installed
        // OpenCode build advertises the TUI flag in `opencode --help`.
        let session = Session(name: "job", kind: .job, agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("cat ") == true)
        #expect(cmd?.contains(" run ") == false)
        if OpenCodeLaunchArgs.tuiSupportsAuto(binary: agent.findBinary() ?? "opencode") {
            #expect(cmd?.contains("--auto") == true)
        } else {
            #expect(cmd?.contains("--auto") == false)
        }
    }

    @Test func autoLaunchCommandReviewSessionFirstLaunch() {
        // First review launch pipes the pre-written `.crow-review-prompt.md`
        // (agent-aware inlined SKILL body — see SessionService.buildReviewPrompt).
        // Review leaves auto-permission off, so no --auto flag.
        let session = Session(name: "review", kind: .review, agentKind: .openCode)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains("cat ") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.contains("--auto") == false)
        #expect(cmd?.contains(" run ") == false)
    }

    @Test func autoLaunchCommandReviewSessionSubsequentLaunch() {
        // After the initial prompt has been dispatched, restarting Crow
        // resumes the TUI with `--continue` (no headless re-run).
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
        #expect(cmd?.contains("--continue") == true)
        #expect(cmd?.contains("--auto") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSessionSubsequentLaunchCarriesAutoWhenSupported() {
        var session = Session(name: "job", kind: .job, agentKind: .openCode)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("--continue") == true)
        if OpenCodeLaunchArgs.tuiSupportsAuto(binary: agent.findBinary() ?? "opencode") {
            #expect(cmd?.contains("--auto") == true)
        } else {
            #expect(cmd?.contains("--auto") == false)
        }
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
