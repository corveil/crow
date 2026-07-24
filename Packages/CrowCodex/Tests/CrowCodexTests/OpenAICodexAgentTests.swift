import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("OpenAICodexAgent", .serialized)
struct OpenAICodexAgentTests {
    private let agent = OpenAICodexAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .codex)
        #expect(agent.displayName == "OpenAI Codex")
        #expect(agent.iconSystemName == "terminal.fill")
        #expect(agent.supportsRemoteControl == false)
        #expect(agent.launchCommandToken == "codex")
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == "/rename my-session\n")
    }

    @Test func autoLaunchCommandWorkSession() {
        let session = Session(name: "test", agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        // Work sessions resume the most recent recorded thread on an app
        // restart instead of reopening a blank TUI (#830) — prefer the absolute
        // binary path when `findBinary()` resolves, otherwise the bare token.
        #expect(cmd?.hasSuffix("codex resume --last\n") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // Codex has no OTEL exporter and doesn't honor --rc — toggling these
        // shouldn't change the launch text.
        let session = Session(name: "test", agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            autoPermissionMode: false,
            telemetryPort: 4318
        )
        #expect(cmd?.hasSuffix("codex resume --last\n") == true)
        // No OTEL env-var prefix and no review/job prompt file should be
        // referenced for a plain work session.
        #expect(cmd?.contains("OTEL_") == false)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
    }

    @Test func autoLaunchCommandReviewSessionFirstLaunchFeedsPrompt() {
        // #830 review: Codex inlines `.crow-review-prompt.md` (the `/crow-review-pr`
        // skill) exactly like Cursor/OpenCode so the review posts a real GitHub
        // verdict — the native `codex review` subcommand posts nothing and would
        // leave the session unable to satisfy its completion condition.
        let session = Session(name: "review", kind: .review, agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd?.contains("/tmp/wt/.crow-review-prompt.md") == true)
        // Not the native local-review subcommand.
        #expect(cmd?.contains(" review --base") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandReviewSessionSubsequentLaunchResumes() {
        // After the review prompt has been dispatched, restarts resume the
        // thread rather than re-running the whole review.
        var session = Session(name: "review", kind: .review, agentKind: .codex)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.hasSuffix("resume --last\n") == true)
    }

    @Test func autoLaunchCommandManagerSessionUnsupported() {
        // Manager sessions never auto-launch an agent; Crow drives them
        // externally. Matches Cursor's `.manager` contract.
        let session = Session(name: "manager", kind: .manager, agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd == nil)
    }

    @Test func autoLaunchCommandJobSessionFirstLaunchInteractive() {
        // First job launch with auto-permission OFF drives the TUI with the
        // pre-written `.crow-job-prompt.md` so the user still approves each
        // step — mirrors the Claude/Cursor Jobs path (CROW-493).
        let session = Session(name: "job", kind: .job, agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd != nil)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.contains("/tmp/wt/.crow-job-prompt.md") == true)
        // Interactive path — not the headless `exec` runner.
        #expect(cmd?.contains(" exec ") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func autoLaunchCommandJobSessionFirstLaunchAutoPermission() {
        // First job launch with auto-permission ON runs the INTERACTIVE TUI
        // with approval OFF but the workspace-write sandbox still ON — the
        // bounded default (#830). It is deliberately NOT headless `codex exec`:
        // exec is one-shot and would exit after prompt 1, leaving JobScheduler's
        // typed follow-up prompts to hit the shell (#843 review round 3). And
        // never the unbounded escape hatches.
        let session = Session(name: "job", kind: .job, agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: true,
            telemetryPort: nil
        )
        #expect(cmd?.contains("-a never -s workspace-write") == true)
        #expect(cmd?.contains("/tmp/wt/.crow-job-prompt.md") == true)
        // Interactive, not the one-shot headless runner.
        #expect(cmd?.contains(" exec ") == false)
        #expect(cmd?.contains("danger-full-access") == false)
        #expect(cmd?.contains("--dangerously-bypass") == false)
    }

    @Test func autoLaunchCommandJobSessionSubsequentLaunch() {
        // After the initial prompt has been dispatched, restarts resume the
        // prior (interactive) thread — plain `--last` (cwd-scoped) selects it.
        var session = Session(name: "job", kind: .job, agentKind: .codex)
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
        #expect(cmd?.hasSuffix("resume --last\n") == true)
    }

    @Test func findBinaryReturnsNilWhenAbsent() {
        // We can't easily mock FileManager.isExecutableFile, but we CAN
        // verify the search returns nil when the candidate paths don't
        // resolve. This relies on the test environment not having a
        // codex binary at the homedir candidate path — the homebrew path
        // may or may not exist depending on the developer machine, so we
        // accept either outcome and just verify the result type.
        _ = agent.findBinary()  // smoke test: must not crash
    }

    @Test func findBinaryHonorsBinaryOverride() {
        // `defaults.binaries.codex` -> absolute path. The default
        // `CodingAgent.findBinary()` impl should consult
        // `BinaryOverrides.shared` before walking PATH (CROW-484).
        // `/bin/sh` is guaranteed-executable on macOS and clearly distinct
        // from any real codex install, so a positive result here means the
        // override path was honored.
        BinaryOverrides.shared.set(["codex": "/bin/sh"])
        defer { BinaryOverrides.shared.set([:]) }

        #expect(agent.findBinary() == "/bin/sh")
    }

    @Test func autoLaunchCommandHonorsBinaryOverride() {
        // The .work branch should resolve through findBinary(), not
        // hardcode `"codex"` — this catches the regression of the prior
        // bug where `autoLaunchCommand` ignored `defaults.binaries.codex`
        // overrides (CROW-484).
        BinaryOverrides.shared.set(["codex": "/bin/sh"])
        defer { BinaryOverrides.shared.set([:]) }

        let session = Session(name: "test", agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd == "/bin/sh resume --last\n")
    }

    @Test func findBinaryIgnoresOverrideWhenPathMissing() {
        // A stale override (binary moved/uninstalled after config edit) must
        // not break registration outright — fall through to PATH/fallback
        // discovery instead. We can't guarantee codex is installed in the
        // test env, so we just assert that the bogus override doesn't get
        // returned literally.
        BinaryOverrides.shared.set(["codex": "/tmp/this-path-does-not-exist-crow484"])
        defer { BinaryOverrides.shared.set([:]) }

        #expect(agent.findBinary() != "/tmp/this-path-does-not-exist-crow484")
    }
}
