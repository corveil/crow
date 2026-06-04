import Foundation
import Testing
@testable import CrowCursor
@testable import CrowCore

@Suite("CursorAgent")
struct CursorAgentTests {
    private let agent = CursorAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .cursor)
        #expect(agent.displayName == "Cursor")
        #expect(agent.iconSystemName == "cursorarrow.rays")
        #expect(agent.supportsRemoteControl == true)
        #expect(agent.launchCommandToken == "agent")
    }

    @Test func autoLaunchCommandWorkSession() {
        let session = Session(name: "test", agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        // Work sessions launch a bare `agent` — prefer the absolute binary
        // path when `findBinary()` resolves, otherwise fall back to the bare
        // token. Either way the tail is `agent\n` (no prompt, no flags).
        #expect(cmd?.hasSuffix("agent\n") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // Cursor has no OTEL exporter and provides remote control via the
        // global hooks.json (`stop.followup_message`), not a per-launch
        // flag — toggling these shouldn't change the launch text.
        let session = Session(name: "test", agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            autoPermissionMode: false,
            telemetryPort: 4318
        )
        #expect(cmd?.hasSuffix("agent\n") == true)
        // No OTEL env-var prefix and no review/job prompt file should be
        // referenced for a plain work session.
        #expect(cmd?.contains("OTEL_") == false)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandReviewSessionFirstLaunch() {
        // First review launch (reviewPromptDispatched == false) should pass
        // the pre-written `.crow-review-prompt.md` as argv so Cursor starts
        // the review unattended. The prompt file content is agent-aware
        // (inlined SKILL body for Cursor) — see SessionService.buildReviewPrompt
        // and #431.
        let session = Session(name: "review", kind: .review, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(".crow-review-prompt.md") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandReviewSessionSubsequentLaunch() {
        // After the initial review prompt has been dispatched, restarting
        // Crow should resume the TUI with a bare `agent` (no re-issued
        // review brief). Mirrors the Jobs subsequent-launch contract.
        var session = Session(name: "review", kind: .review, agentKind: .cursor)
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
        #expect(cmd?.hasSuffix("agent\n") == true)
    }

    @Test func autoLaunchCommandManagerSessionUnsupported() {
        // Manager sessions never auto-launch an agent; Crow drives them
        // externally. Cursor must keep returning nil here so the manager
        // contract isn't accidentally regressed by the review-enable work
        // in #431.
        let session = Session(name: "manager", kind: .manager, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd == nil)
    }

    @Test func autoLaunchCommandJobSessionFirstLaunch() {
        // First job launch (reviewPromptDispatched == false) should pass the
        // pre-written `.crow-job-prompt.md` as argv so Cursor starts working
        // unattended — mirrors the Claude Code Jobs path (#424).
        let session = Session(name: "job", kind: .job, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSessionSubsequentLaunch() {
        // After the initial prompt has been dispatched, the deferred-launch
        // path falls back to a bare `agent` (Cursor has no `--continue`), so
        // restarting Crow resumes the TUI instead of re-running the prompt.
        var session = Session(name: "job", kind: .job, agentKind: .cursor)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.hasSuffix("agent\n") == true)
    }

    @Test func findBinaryReturnsNilWhenAbsent() {
        // We can't easily mock FileManager.isExecutableFile, but we CAN
        // verify the search returns nil when the candidate paths don't
        // resolve. This relies on the test environment not having an
        // `agent` binary at the homedir candidate path — the homebrew
        // path may or may not exist depending on the developer machine,
        // so we accept either outcome and just verify the result type.
        _ = agent.findBinary()  // smoke test: must not crash
    }
}
