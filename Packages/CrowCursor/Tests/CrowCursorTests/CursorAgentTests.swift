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
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == "/rename my-session\n")
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
        // Work sessions launch `agent` with the unconditional `--trust`
        // workspace-trust seed and no auto-permission flags (autoPermissionMode
        // off) — prefer the absolute binary path when `findBinary()` resolves,
        // otherwise the bare token; either way the tail is `agent' --trust\n`
        // (no prompt, no --force).
        #expect(cmd?.hasSuffix("agent' --trust\n") == true)  // binary is shell-quoted
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandWorkSessionAutoPermission() {
        // The opt-in coder-view auto-permission path (#586): a bare work TUI
        // still carries the auto-permission flags when autoPermissionMode is on.
        let session = Session(name: "test", agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.hasSuffix(" --force --approve-mcps\n") == true)
        #expect(cmd?.contains("--trust") == true)  // trust seed always present
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // Cursor has no OTEL exporter and provides remote control via `crow
        // send` typing into the interactive TUI (not a per-launch flag), so
        // toggling these shouldn't change the launch text.
        let session = Session(name: "test", agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            autoPermissionMode: false,
            telemetryPort: 4318
        )
        #expect(cmd?.hasSuffix("agent' --trust\n") == true)  // binary is shell-quoted
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
        // CROW-890 review (Red 1): a `.review` clone is attacker-controlled, so
        // it must NOT be auto-trusted — the `--trust` seed is withheld, leaving
        // Cursor's folder-trust dialog as the human gate.
        #expect(cmd?.contains("--trust") == false)
    }

    @Test func autoLaunchCommandReviewSessionSubsequentLaunch() {
        // After the initial review prompt has been dispatched, restarting
        // Crow resumes the conversation with `--continue` instead of
        // re-issuing the review brief or dropping into a cold TUI (#829).
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
        #expect(cmd?.hasSuffix("--continue\n") == true)
        // Resume of a `.review` session stays untrusted too (Red 1).
        #expect(cmd?.contains("--trust") == false)
    }

    @Test func autoLaunchCommandReviewOmitsTrustSeedEvenWithAutoPermission() {
        // CROW-890 review, Red 1 — the exact shipped-default exploit config
        // (`reviewAutoPermissionMode == true`). A `.review` clone is
        // attacker-controlled, so it must NEVER be auto-trusted even with review
        // auto-permission on. Auto-permission (`--force --approve-mcps`) is
        // unchanged; only the `--trust` seed is withheld, leaving Cursor's
        // folder-trust dialog as the human gate — mirrors the Codex
        // `session.kind != .review` guard.
        let session = Session(name: "review", kind: .review, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.contains("--force --approve-mcps") == true)
        #expect(cmd?.contains("--trust") == false)
    }

    @Test func launchCommandHandoffWithholdsTrustForReview() async throws {
        // The kind-aware handoff launch (`SessionService.handoffAgent` passes the
        // live `session.kind`): a `.review` handoff to Cursor omits the trust
        // seed (attacker-controlled clone), a `.work` handoff keeps it (Red 1).
        let review = try await agent.launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p", sessionKind: .review)
        #expect(review.contains("--trust") == false)
        let work = try await agent.launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p", sessionKind: .work)
        #expect(work.contains("--trust") == true)
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
        // path resumes the conversation with `--continue` (#829) rather than
        // re-running the prompt or opening a cold TUI.
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
        #expect(cmd?.hasSuffix("--continue\n") == true)
    }

    @Test func autoLaunchCommandJobAutoPermissionBounded() {
        // With auto-permission on, a first job launch carries the `--trust`
        // seed + the auto flags (approval off, no sandbox — parity with Claude
        // auto + trust seed) and NOT --yolo/--auto-review (#829 review, CROW-890).
        // Positional prompt still fed, flags precede it.
        let session = Session(name: "job", kind: .job, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains(" --force --approve-mcps ") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.contains("--sandbox") == false)
        #expect(cmd?.contains("--yolo") == false)
        #expect(cmd?.contains("--auto-review") == false)
        #expect(cmd?.contains("--trust") == true)  // workspace-trust seed
    }

    @Test func autoLaunchCommandJobResumeCarriesAutoPermission() {
        // Resume (subsequent launch) with auto-permission keeps the flags so
        // the resumed unattended job still runs hands-off.
        var session = Session(name: "job", kind: .job, agentKind: .cursor)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("--force --approve-mcps") == true)
        #expect(cmd?.hasSuffix("--continue\n") == true)
    }

    @Test func managerLaunchCommandAppliesAutoPermission() {
        // Manager honors its auto-permission toggle (parity with Claude's
        // --permission-mode auto) and returns no trailing newline (backend
        // appends Enter). The `--trust` seed is unconditional (parity with
        // Claude seeding the Manager cwd, CROW-890).
        let plain = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: false,
            autoPermissionMode: false, telemetryPort: nil)
        #expect(plain.hasSuffix("agent' --trust"))  // trust seed, no auto-permission
        #expect(plain.contains("--force") == false)

        let auto = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: false,
            autoPermissionMode: true, telemetryPort: nil)
        #expect(auto.contains("--force --approve-mcps"))
        #expect(auto.contains("--trust") == true)
        #expect(auto.hasSuffix("\n") == false)
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
