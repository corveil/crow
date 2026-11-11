import Foundation
import Testing
@testable import CrowAntigravity
@testable import CrowCore

@Suite("AntigravityAgent")
struct AntigravityAgentTests {
    private let agent = AntigravityAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .antigravity)
        #expect(agent.kind.rawValue == "antigravity")
        #expect(agent.displayName == "Antigravity")
        #expect(agent.iconSystemName == "arrow.up.circle")
        #expect(agent.supportsRemoteControl == true)
        #expect(agent.usesAlternateScreen == false)
        #expect(agent.launchCommandToken == "agy")
        // Rename surface is unverified on v1.1.7 → opt-out nil (no stray paste).
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == nil)
    }

    // MARK: - Supply-chain gate

    @Test func fallbackCandidatesNeverReferenceCommunityGitHubOrg() {
        // The gate: fallbacks must be standard-bin / official-installer paths,
        // never the unverified `google-antigravity/*` GitHub release binary.
        for path in agent.fallbackCandidates {
            #expect(path.hasSuffix("/agy"), "fallback should resolve the `agy` binary: \(path)")
            #expect(!path.contains("google-antigravity"), "must not reference the community org: \(path)")
            #expect(!path.lowercased().contains("github"), "must not reference GitHub releases: \(path)")
        }
    }

    // MARK: - autoLaunchCommand

    /// The exact ADC-guarded suffix (CROW-1428). Pinned verbatim so a drift in
    /// the shell guard — the thing that keeps an ADC sign-in launching — fails.
    private let rcSuffix = " $([ -n \"${AGY_ADC_AUTH-}\" ] || printf %s --remote-control)"

    @Test func workSessionLaunchesBareTUI() {
        let session = Session(name: "test", agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: 4318)
        // Bare interactive TUI: no prompt, no resume flag, no OTEL prefix, no RC.
        #expect(cmd?.hasSuffix("agy'\n") == true)  // binary is shell-quoted
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.contains("OTEL_") == false)
        #expect(cmd?.contains("-p ") == false)
        #expect(cmd?.contains("--remote-control") == false)
    }

    @Test func workSessionAppendsNativeRemoteControlWhenEnabled() {
        // CROW-1428: session-scoped `--remote-control`, behind the ADC guard.
        let session = Session(name: "test", agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: true, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd?.hasSuffix("agy'\(rcSuffix)\n") == true)
        // Never the machine-global OS service, and never Claude's flag spelling.
        #expect(cmd?.contains("remote-control start") == false)
        #expect(cmd?.contains(" --rc") == false)
    }

    @Test func remoteControlSuffixIsEmptyWhenDisabled() {
        #expect(AntigravityLaunchArgs.remoteControlSuffix(false) == "")
        #expect(AntigravityLaunchArgs.remoteControlSuffix(true) == rcSuffix)
    }

    @Test func remoteControlNeverRidesThePrintTurn() {
        // `-p` is an unattended one-shot turn that prints no RC URL; only the
        // interactive `-c` resume carries the flag.
        for kind in [SessionKind.job, .review] {
            let first = Session(name: "x", kind: kind, agentKind: .antigravity)
            let firstCmd = agent.autoLaunchCommand(
                session: first, worktreePath: "/tmp/wt",
                remoteControlEnabled: true, autoPermissionMode: false, telemetryPort: nil)
            #expect(firstCmd?.contains("--remote-control") == false)

            var resumed = Session(name: "x", kind: kind, agentKind: .antigravity)
            resumed.reviewPromptDispatched = true
            let resumeCmd = agent.autoLaunchCommand(
                session: resumed, worktreePath: "/tmp/wt",
                remoteControlEnabled: true, autoPermissionMode: false, telemetryPort: nil)
            #expect(resumeCmd?.hasSuffix(" -c\(rcSuffix)\n") == true)
        }
    }

    @Test func jobFirstLaunchInjectsPromptViaDashP() {
        let session = Session(name: "job", kind: .job, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd != nil)
        #expect(cmd?.contains("_CROW_P=$(<") == true)
        #expect(cmd?.contains("eval \"") == true)
        #expect(cmd?.contains(" -p $(printf '%q'") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func jobFirstLaunchQuotesPromptPathWithSpaces() {
        // A worktree under `/Users/x/My Projects/…` must not split the prompt read:
        // the prompt path is single-quoted inside the `$(< …)` substitution.
        let session = Session(name: "job", kind: .job, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/Users/x/My Projects/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd?.contains("_CROW_P=$(< '/Users/x/My Projects/wt/.crow-job-prompt.md');") == true)
        #expect(cmd?.contains("eval \"") == true)
        #expect(cmd?.contains(" -p $(printf '%q'") == true)
    }

    @Test func jobSubsequentLaunchResumesWithDashC() {
        var session = Session(name: "job", kind: .job, agentKind: .antigravity)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.hasSuffix(" -c\n") == true)
    }

    @Test func reviewFirstLaunchInjectsPromptViaDashP() {
        // #902: review dispatches the inlined SKILL body via `-p "$_CROW_P"`.
        let session = Session(name: "review", kind: .review, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd != nil)
        #expect(cmd?.contains("_CROW_P=$(<") == true)
        #expect(cmd?.contains("eval \"") == true)
        #expect(cmd?.contains(" -p $(printf '%q'") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == true)
        // NOT the job prompt file — review reads its own.
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func reviewFirstLaunchQuotesPromptPathWithSpaces() {
        // A worktree under `/Users/x/My Projects/…` must not split the prompt read:
        // the prompt path is single-quoted inside the `$(< …)` substitution.
        let session = Session(name: "review", kind: .review, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/Users/x/My Projects/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd?.contains("_CROW_P=$(< '/Users/x/My Projects/wt/.crow-review-prompt.md');") == true)
        #expect(cmd?.contains("eval \"") == true)
        #expect(cmd?.contains(" -p $(printf '%q'") == true)
    }

    @Test func reviewSubsequentLaunchResumesWithDashC() {
        // Restart mid-review resumes with `-c` (continue most-recent) rather than
        // re-running the whole review prompt.
        var session = Session(name: "review", kind: .review, agentKind: .antigravity)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.hasSuffix(" -c\n") == true)
    }

    @Test func managerSessionUnsupported() {
        let session = Session(name: "manager", kind: .manager, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd == nil)
    }

    // MARK: - Auto-permission (CROW-1427)

    /// The exact suffix that selects Auto mode, pasted raw.
    private static let autoSuffix = #" --settings '{"agentMode":"auto"}'"#

    @Test func autoPermissionSuffixOffIsEmpty() {
        #expect(AntigravityLaunchArgs.autoPermissionSuffix(false) == "")
    }

    @Test func autoPermissionSuffixOnSelectsAutoModeViaSettings() {
        let s = AntigravityLaunchArgs.autoPermissionSuffix(true)
        #expect(s == Self.autoSuffix)
        // `--mode auto` is a silent no-op on agy 1.5.5 (applied before sign-in),
        // and the bypass flags are never acceptable.
        #expect(!s.contains("--mode"))
        #expect(!s.contains("--dangerously-skip-permissions"))
        #expect(!s.contains("always-proceed"))
    }

    @Test func workSessionWithAutoPermissionSelectsAutoMode() {
        let session = Session(name: "test", agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.hasSuffix("agy'" + Self.autoSuffix + "\n") == true)
    }

    @Test func jobFirstLaunchWithAutoPermissionEscapesSettingsForEval() {
        let session = Session(name: "job", kind: .job, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        // Inside `eval "…"` the JSON quotes are backslash-escaped, before `-p`.
        #expect(cmd?.contains(#" --settings '{\"agentMode\":\"auto\"}' -p $(printf '%q'"#) == true)
        #expect(cmd?.contains("--mode") == false)
        #expect(cmd?.contains("--dangerously-skip-permissions") == false)
    }

    /// Run the real `.job` first-launch command through bash with the binary
    /// swapped for a stub. Auto mode must reach `agy` as one `--settings` argv
    /// element before `-p` and the prompt.
    @Test func jobFirstLaunchWithAutoPermissionRoundTripsThroughBash() throws {
        let fm = FileManager.default
        let wt = fm.temporaryDirectory.appendingPathComponent("agy-auto-\(UUID().uuidString)")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: wt) }
        let prompt = "ship \"it\" $HOME"
        try prompt.write(
            to: wt.appendingPathComponent(".crow-job-prompt.md"), atomically: true, encoding: .utf8)

        let session = Session(name: "job", kind: .job, agentKind: .antigravity)
        let cmd = try #require(agent.autoLaunchCommand(
            session: session, worktreePath: wt.path,
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil))
        let quotedBinary = AntigravityLaunchArgs.shellQuote(agent.launchBinary() ?? "agy")
        #expect(cmd.contains(quotedBinary))
        let launch = cmd.replacingOccurrences(of: quotedBinary, with: "stub")
            .trimmingCharacters(in: .newlines)
        let script = "stub() { printf '%s|%s|%s|%s' \"$1\" \"$2\" \"$3\" \"$4\"; }; \(launch)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(out == #"--settings|{"agentMode":"auto"}|-p|"# + prompt)
    }

    @Test func jobResumeWithAutoPermissionKeepsAutoMode() {
        var session = Session(name: "job", kind: .job, agentKind: .antigravity)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        // `-c` is pasted raw (no eval), so the suffix is unescaped.
        #expect(cmd?.hasSuffix("agy'" + Self.autoSuffix + " -c\n") == true)
    }

    @Test func reviewNeverGetsAutoModeEvenWhenAutoPermissionIsOn() {
        // SECURITY: review clones are attacker-controlled. Auto's sandbox-exit
        // reviewer reads the PR's own text, so `.review` keeps the user's mode.
        var session = Session(name: "review", kind: .review, agentKind: .antigravity)
        let first = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(first?.contains("--settings") == false)
        #expect(first?.contains("agentMode") == false)
        #expect(first?.contains("--dangerously-skip-permissions") == false)
        session.reviewPromptDispatched = true
        let resume = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(resume?.hasSuffix("agy' -c\n") == true)
    }

    @Test func managerLaunchCommandBareNoRC() {
        let cmd = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: false,
            autoPermissionMode: false, telemetryPort: 4318)
        #expect(cmd.hasSuffix("agy'"))  // binary is shell-quoted, no trailing newline
        #expect(cmd.contains("--dangerously-skip-permissions") == false)
    }

    @Test func managerLaunchCommandAppendsNativeRemoteControl() {
        // CROW-1428. No `--name` equivalent exists, so the session name is not
        // passed anywhere; no trailing newline (backend appends Enter).
        let cmd = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: true,
            autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd.hasSuffix("agy'\(rcSuffix)"))
        #expect(cmd.contains("Manager") == false)
    }

    @Test func managerLaunchCommandWithAutoPermissionSelectsAutoMode() {
        let cmd = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: false,
            autoPermissionMode: true, telemetryPort: 4318)
        #expect(cmd.hasSuffix("agy'" + Self.autoSuffix))  // no trailing newline
        #expect(cmd.contains("--dangerously-skip-permissions") == false)
    }

    @Test func managerLaunchCommandWithAutoAndRemoteControlCarriesBoth() {
        // CROW-1427 + CROW-1428: Auto first, then the ADC-guarded RC flag.
        let cmd = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: true,
            autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd.hasSuffix("agy'" + Self.autoSuffix + rcSuffix))
    }

    @Test func workSessionWithAutoAndRemoteControlCarriesBoth() {
        let session = Session(name: "test", agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: true, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.hasSuffix("agy'" + Self.autoSuffix + rcSuffix + "\n") == true)
    }

    @Test func jobFirstLaunchWithAutoAndRemoteControlHasNoRCOnPrintTurn() {
        // RC is interactive-only (CROW-1428); Auto still applies to the `-p` turn.
        let session = Session(name: "job", kind: .job, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: true, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.contains("--remote-control") == false)
        #expect(cmd?.contains(#"--settings '{\"agentMode\":\"auto\"}' -p"#) == true)
    }

    @Test func findBinaryDoesNotCrash() {
        _ = agent.findBinary()  // smoke test
    }
}
