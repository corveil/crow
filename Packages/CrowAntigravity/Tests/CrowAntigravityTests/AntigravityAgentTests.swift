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
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: 4318)
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

    @Test func autoPermissionIsNoOpOnPinnedVersion() {
        // Bounded auto-permission is a documented Tier-2 gap: no verified launch
        // flag, and we never pass --dangerously-skip-permissions.
        let session = Session(name: "job", kind: .job, agentKind: .antigravity)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.contains("--dangerously-skip-permissions") == false)
        #expect(cmd?.contains("always-proceed") == false)
    }

    @Test func managerLaunchCommandBareNoRC() {
        let cmd = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: false,
            autoPermissionMode: true, telemetryPort: 4318)
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

    @Test func findBinaryDoesNotCrash() {
        _ = agent.findBinary()  // smoke test
    }
}
