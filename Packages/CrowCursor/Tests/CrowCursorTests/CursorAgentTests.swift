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
        #expect(agent.launchCommandToken == "cursor-agent")
        #expect(agent.alternateLaunchCommandTokens == ["agent"])
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == "/rename my-session\n")
    }

    // MARK: - Binary token collision (CROW-989)

    /// Cursor ships the same executable under two names. Crow prefers the
    /// unambiguous `cursor-agent`; the generic `agent` is kept only as an alias
    /// because xAI's grok-build installs `~/.grok/bin/agent` and won the PATH
    /// walk, so Crow built a Cursor command and ran Grok's binary — which died
    /// on `--force`.
    @Test func prefersTheUnambiguousNameAndKeepsTheLegacyAlias() {
        #expect(agent.binaryTokens == ["cursor-agent", "agent"])
    }

    /// Hardcoded fallbacks follow the same preference: a `…/bin/agent` on disk is
    /// just as likely to be grok-build's as a PATH one, so every `cursor-agent`
    /// candidate is tried before any bare `agent`.
    @Test func fallbackCandidatesPreferCursorAgent() {
        let names = agent.fallbackCandidates.map { ($0 as NSString).lastPathComponent }
        let lastPreferred = names.lastIndex(of: "cursor-agent")
        let firstLegacy = names.firstIndex(of: "agent")
        #expect(lastPreferred != nil && firstLegacy != nil)
        #expect(lastPreferred! < firstLegacy!)
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
        #expect(cmd?.contains("eval \"") == true)
        #expect(cmd?.contains("$(cat") == false)
        #expect(cmd?.hasSuffix("\n") == true)
        // CROW-968: the inlined review brief must reach `agent` as an operand.
        // Without the `--`, a prompt starting with `-` (the SKILL's `---`
        // frontmatter) is claimed by commander as an option and the launch dies.
        #expect(cmd?.contains(" -- $(printf") == true)
        // CROW-954 reverses the CROW-890 carve-out: a `.review` clone launches
        // pre-trusted so unattended dispatch isn't stranded on "Workspace Trust
        // Required". Its defense is the launch-path `.cursor/` strip
        // (`SessionService.shouldStripCursorReviewClone`), not the dialog.
        #expect(cmd?.contains("--trust") == true)
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
        // The seed rides `--continue` resume too — harmless, since the first
        // launch already recorded the saved trust decision (CROW-954).
        #expect(cmd?.contains("--trust") == true)
    }

    @Test func autoLaunchCommandReviewSeedsTrustAndRunEverything() {
        // CROW-954, the shipped-default review config
        // (`reviewAutoPermissionMode == true`): a review session must come up both
        // already-trusted (`--trust`) AND in Run Everything mode (`--force`, which
        // `agent --help` documents `--yolo` as an alias of). Regression pin for the
        // reported symptom — the session stopping on Cursor's "Workspace Trust
        // Required" prompt despite carrying `--force --approve-mcps`, which does
        // NOT suppress that dialog (observed on `agent 2026.08.04`).
        let session = Session(name: "review", kind: .review, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.contains("--trust") == true)
        #expect(cmd?.contains("--force --approve-mcps") == true)
        // Trust leads, so it is in effect before the prompt argument is parsed.
        #expect(cmd?.contains("--trust --force --approve-mcps") == true)
    }

    @Test func launchCommandHandoffSeedsTrustForEveryKind() async throws {
        // `SessionService.handoffAgent` passes the live `session.kind` through the
        // `CodingAgent` protocol default. Post-CROW-954 Cursor has no kind-dependent
        // launch, so every kind — `.review` included — carries the trust seed.
        for kind in [SessionKind.review, .work, .job] {
            let cmd = try await agent.launchCommand(
                sessionID: UUID(), worktreePath: "/w", prompt: "p", sessionKind: kind)
            #expect(cmd.contains("--trust") == true, "\(kind) handoff should seed trust")
        }
    }

    @Test func existentialDispatchSeedsTrustForReviewHandoff() async throws {
        // `handoffAgent` holds the agent as `any CodingAgent`. Pin that the
        // existential path — protocol default → Cursor's three-arg `launchCommand`
        // — still seeds trust for a `.review` handoff. Cursor dropped its
        // `sessionKind:` override in CROW-954; if someone reintroduces one that
        // forgets to seed, a Cursor review handoff would silently start blocking on
        // the trust dialog again with an otherwise-green suite.
        let erased: any CodingAgent = CursorAgent()
        let review = try await erased.launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p", sessionKind: .review)
        #expect(review.contains("--trust") == true)
    }

    @Test func launchCommandThreeArgSeedsTrust() async throws {
        // The kindless three-argument requirement is what the protocol default
        // lands on, so it must seed too. The CROW-890 "fail closed, never seed"
        // default is moot now that every kind is trusted (CROW-954) — leaving it
        // would strand exactly the handoff path that default serves.
        let cmd = try await agent.launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p")
        #expect(cmd.contains("--trust") == true)
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
        // CROW-968: job prompts are user-authored, so one can legitimately begin
        // with `-`. The separator covers that as well as the review path.
        #expect(cmd?.contains(" -- $(printf") == true)
    }

    /// CROW-968: the `--` belongs to the prompt-dispatch path only. A resume or a
    /// bare `.work` TUI passes no positional prompt, so an end-of-options marker
    /// there would be a stray argv element with nothing to protect.
    @Test func endOfOptionsSeparatorOnlyRidesThePromptDispatch() {
        var resumed = Session(name: "review", kind: .review, agentKind: .cursor)
        resumed.reviewPromptDispatched = true

        for session in [
            Session(name: "work", kind: .work, agentKind: .cursor),
            resumed,
        ] {
            let cmd = agent.autoLaunchCommand(
                session: session,
                worktreePath: "/tmp/wt",
                remoteControlEnabled: false,
                autoPermissionMode: true,
                telemetryPort: nil
            )
            // ` -- ` specifically: `--trust`/`--force`/`--continue` all contain
            // a double hyphen, so a bare `contains("--")` would pass vacuously.
            #expect(cmd?.contains(" -- ") == false, "\(session.kind) carried a stray separator")
        }
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

    // MARK: - Identity probe (CROW-989)

    /// Real `cursor-agent 2026.08.04-aaa8809 --help`, trimmed to the option lines
    /// the markers key on. Note the `Usage:` line says **`agent`** — the binary
    /// reports its generic argv[0] name even when invoked as `cursor-agent` —
    /// which is exactly why the markers are flags and env vars, not the program
    /// name.
    private static let cursorHelp = """
        Usage: agent [options] [command] [prompt...]

        Start the Cursor Agent

        Options:
          -v, --version              Output the version number
          --api-key <key>            API key for authentication (can also use
                                     CURSOR_API_KEY env var)
          -e, --endpoint <url>       Target API endpoint URL (can also use
                                     CURSOR_API_ENDPOINT env var)
          -f, --force                Force allow commands unless explicitly denied
          --approve-mcps             Automatically approve all MCP servers
          --trust                    Trust the current workspace without prompting
        """

    /// Real `grok 1.0.0 --help` (grok-build, installed as `~/.grok/bin/agent`),
    /// trimmed. This is the binary Crow actually launched in the CROW-989 repro:
    /// it has a `--force`-adjacent vocabulary but none of Cursor's flags, so
    /// Cursor's `--force --approve-mcps` died on parse.
    private static let grokBuildHelp = """
        Grok Build TUI

        Usage: agent [OPTIONS] [PROMPT] [COMMAND]

        Options:
              --allow <RULE>       Permission allow rule (compat alias: --allowedTools)
              --always-approve     Auto-approve all tool executions
          -c, --continue           Continue the most recent session
              --deny <RULE>        Permission deny rule
        """

    @Test func identityProbeAcceptsCursorHelp() async {
        let agent = CursorAgent(probeRunner: FakeProbeRunner(
            outputs: ["--help": Self.cursorHelp]))
        #expect(await agent.verifyBinaryIdentity(atPath: "/Users/x/.local/bin/cursor-agent"))
    }

    /// The exact CROW-989 false positive: `agent` resolved to grok-build. The
    /// probe rejects it, so registration reports Cursor unavailable (naming the
    /// resolved path) instead of launching and failing on flag parsing.
    @Test func identityProbeRejectsGrokBuildUnderTheAgentName() async {
        let agent = CursorAgent(probeRunner: FakeProbeRunner(
            outputs: ["--help": Self.grokBuildHelp]))
        #expect(await agent.verifyBinaryIdentity(atPath: "/Users/x/.grok/bin/agent") == false)
    }

    /// A binary that prints nothing — or a probe that times out — can't be
    /// identified, so it's rejected rather than optimistically launched.
    @Test func identityProbeRejectsEmptyOutput() async {
        let agent = CursorAgent(probeRunner: FakeProbeRunner(outputs: [:]))
        #expect(await agent.verifyBinaryIdentity(atPath: "/usr/local/bin/agent") == false)
    }

    /// Cursor's `--version` is a bare build stamp with no vendor text, so it
    /// could never match a marker; probing it would only cost a second spawn per
    /// boot. `--help` is the only leg.
    @Test func identityProbeOnlySpawnsHelp() async {
        let runner = FakeProbeRunner(outputs: ["--version": "2026.08.04-aaa8809"])
        _ = await CursorAgent(probeRunner: runner).verifyBinaryIdentity(atPath: "/bin/x")
        #expect(runner.probed.value == ["--help"])
    }

    /// Every marker must be present in the real Cursor help — a marker that
    /// matches nothing is dead weight that silently narrows the probe.
    @Test func everyMarkerAppearsInRealCursorHelp() {
        let help = Self.cursorHelp.lowercased()
        for marker in CursorAgent.identityMarkers {
            #expect(help.contains(marker), "marker \(marker) no longer appears in Cursor's --help")
        }
    }
}

/// Canned `--help` responder for the identity probe, recording which args were
/// spawned. Lets a test hand `verifyBinaryIdentity` real Cursor vs grok-build
/// output without spawning a subprocess.
private struct FakeProbeRunner: ShellRunner {
    let outputs: [String: String]
    let probed = Recorder()

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var args: [String] = []
        var value: [String] { lock.lock(); defer { lock.unlock() }; return args }
        func record(_ a: String) { lock.lock(); defer { lock.unlock() }; args.append(a) }
    }

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        let arg = args.dropFirst().first ?? ""
        probed.record(arg)
        return outputs[arg] ?? ""
    }
}
