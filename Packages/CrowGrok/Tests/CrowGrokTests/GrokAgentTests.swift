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
        // Shell-quoted resolved binary (`findBinary() ?? "grok"`), no flags, no
        // trailing newline. Quoted like Cursor's manager path so a spaced
        // `defaults.binaries.grok` override can't word-split (#861 review r8).
        #expect(cmd.hasPrefix("'"))
        #expect(cmd.hasSuffix("'"))
        #expect(cmd.contains("grok"))
        #expect(!cmd.contains("--rc"))
        #expect(!cmd.contains("--name"))
        #expect(!cmd.contains("\n"))
    }

    /// The handoff path (`GrokAgent.launchCommand` → `GrokLauncher.launchCommand`)
    /// must launch the *passed* binary — the caller threads the override-aware
    /// `findBinary()` result — not a bare PATH walk. Otherwise a
    /// `defaults.binaries.grok` pin is ignored on `crow handoff-agent --agent
    /// grok` and the colliding `superagent-ai/grok-cli` can win (#861 review r8).
    /// Prove the launcher honors its `binary:` argument, shell-quoted so a spaced
    /// override path stays intact.
    @Test func launcherHandoffCommandUsesPassedBinaryQuoted() async throws {
        let launcher = GrokLauncher()
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(),
            worktreePath: "/tmp/wt",
            prompt: "do the thing",
            binary: "/opt/my tools/grok"
        )
        #expect(cmd.contains("'/opt/my tools/grok'"))
        #expect(cmd.contains("--prompt-file"))
        #expect(cmd.contains(" -c"))
    }

    // MARK: - Identity probe (CROW-911)

    /// A resolved binary whose `--help` lists grok-build's own flags is xAI's
    /// grok-build — even with no vendor branding — so the probe accepts it.
    @Test func identityProbeAcceptsGrokBuildFlags() async {
        let runner = FakeProbeRunner(outputs: [
            "--version": "grok 0.4.1",
            "--help": """
                Usage: grok [OPTIONS]
                Options:
                  --prompt-file <PATH>     Read the prompt from a file (headless)
                  --prompt-json <JSON>     Structured prompt input
                  --permission-mode <MODE> ask | auto | bypassPermissions
                  --always-approve         Approve every tool call (alias --yolo)
                  -c, --continue           Resume the last session
                """,
        ])
        let agent = GrokAgent(probeRunner: runner)
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/grok") == true)
    }

    /// The colliding community `superagent-ai/grok-cli` (a Node conversational
    /// client for xAI's API) carries none of grok-build's flags — even though it
    /// legitimately mentions xAI — so the probe rejects it. This is the exact
    /// false-positive CROW-911 fixes.
    @Test func identityProbeRejectsCommunityGrokCli() async {
        let runner = FakeProbeRunner(outputs: [
            "--version": "1.2.3",
            "--help": """
                Grok CLI — a conversational AI assistant powered by xAI's Grok.
                Usage: grok [prompt]
                Options:
                  --model <NAME>   Model to use
                  --api-key <KEY>  xAI API key
                  --help           Show help
                """,
        ])
        let agent = GrokAgent(probeRunner: runner)
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/grok") == false)
    }

    /// A binary that prints nothing (or a spawn failure that yields `""`) can't
    /// be identified, so it's treated as the foreign tool and rejected.
    @Test func identityProbeRejectsEmptyOutput() async {
        let agent = GrokAgent(probeRunner: FakeProbeRunner(outputs: [:]))
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/grok") == false)
    }

    /// A foreign `grok --version` may exit non-zero yet still print a marker; the
    /// probe merges stdout+stderr and matches it regardless of exit status.
    @Test func identityProbeToleratesNonZeroExit() async {
        let runner = FakeProbeRunner(
            outputs: ["--version": "grok --prompt-file supported", "--help": ""],
            failing: ["--version"]
        )
        let agent = GrokAgent(probeRunner: runner)
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/grok") == true)
    }

    /// The Red from #912 review: a `grok` that never exits and ignores
    /// cancellation must not stall boot. The shared probe's timeout is a *hard*
    /// bound on the awaiting task — it returns `""` at the cap even against a
    /// runner that never completes. Uses a tiny injected timeout so the test is
    /// instant. (Lives here as well as in `CrowCore` because Grok's
    /// `verifyBinaryIdentity` is the original caller this bound was written for.)
    @Test func probeHardBoundsAgainstNeverCompletingRunner() async {
        let out = await BinaryIdentityProbe.run(
            "/opt/homebrew/bin/grok",
            "--help",
            runner: NeverRunner(),
            timeoutNanos: 50_000_000  // 50ms
        )
        #expect(out == "")
    }
}

/// Canned `--version` / `--help` responder for the identity probe, keyed by the
/// probe arg — lets a test hand `verifyBinaryIdentity` grok-build vs the
/// colliding community `grok` output without spawning a subprocess. Args listed
/// in `failing` throw `.nonZeroExit` carrying their output (a foreign binary
/// that exits non-zero but still prints).
private struct FakeProbeRunner: ShellRunner {
    let outputs: [String: String]
    var failing: Set<String> = []

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        let arg = args.dropFirst().first ?? ""
        let out = outputs[arg] ?? ""
        if failing.contains(arg) {
            throw ShellRunnerError.nonZeroExit(exitCode: 2, output: out)
        }
        return out
    }
}

/// A `ShellRunner` that never completes and ignores cancellation — the exact
/// shape from the #912 review repro. Proves the shared probe's timeout bounds the
/// awaiting task rather than relying on the runner cooperating. Uses an *unsafe*
/// continuation deliberately: the leak (never resumed) is the intended scenario,
/// so a checked continuation would only emit a spurious misuse diagnostic.
private struct NeverRunner: ShellRunner {
    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return ""  // unreachable
    }
}
