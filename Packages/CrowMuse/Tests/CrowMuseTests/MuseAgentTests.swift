import Foundation
import Testing
@testable import CrowMuse
@testable import CrowCore

@Suite("MuseAgent")
struct MuseAgentTests {
    private let agent = MuseAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .muse)
        #expect(agent.kind.rawValue == "muse")
        #expect(agent.displayName == "Muse Code")
        #expect(agent.iconSystemName == "wand.and.stars")
        #expect(agent.supportsRemoteControl == true)
        #expect(agent.usesAlternateScreen == false)
        #expect(agent.launchCommandToken == "muse")
        // Rename surface is unverified → opt-out nil (no stray paste).
        #expect(agent.sessionRenameSlashCommand(newName: "my-session") == nil)
    }

    @Test func fallbackCandidatesAreStandardBinPaths() {
        for path in agent.fallbackCandidates {
            #expect(path.hasSuffix("/muse"), "fallback should resolve the `muse` binary: \(path)")
            #expect(!path.lowercased().contains("github"), "must not reference GitHub releases: \(path)")
            #expect(!path.contains("lookaside.facebook.com"), "must not download from Meta CDN: \(path)")
        }
    }

    // MARK: - autoLaunchCommand

    @Test func workSessionLaunchesTrustedTUI() {
        let session = Session(name: "test", agentKind: .muse)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: true, autoPermissionMode: true, telemetryPort: 4318)
        #expect(cmd?.contains("muse'") == true)
        #expect(cmd?.contains("--trust-workspace") == true)
        #expect(cmd?.contains("--disable-approval") == false)
        #expect(cmd?.contains("--yolo") == false)
        #expect(cmd?.contains(" exec") == false)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        #expect(cmd?.contains("OTEL_") == false)
        #expect(cmd?.contains("--rc") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func jobFirstLaunchExecThenResume() {
        let session = Session(name: "job", kind: .job, agentKind: .muse)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd != nil)
        #expect(cmd?.contains(" exec") == true)
        #expect(cmd?.contains(" --prompt-file ") == true)
        #expect(cmd?.contains("; ") == true)
        #expect(cmd?.contains(" resume") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.contains("--trust-workspace") == true)
        #expect(cmd?.contains("--disable-approval") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func jobFirstLaunchAutoPermissionIsBoundedNotYolo() {
        let session = Session(name: "job", kind: .job, agentKind: .muse)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.contains("--disable-approval") == true)
        #expect(cmd?.contains("--trust-workspace") == true)
        #expect(cmd?.contains("--yolo") == false)
        #expect(cmd?.contains("--disable-sandbox") == false)
        #expect(cmd?.contains("--subagent-worktree-isolation") == false)
    }

    @Test func reviewFirstLaunchExecThenResumeWithoutTrust() {
        let session = Session(name: "review", kind: .review, agentKind: .muse)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd != nil)
        #expect(cmd?.contains(" exec") == true)
        #expect(cmd?.contains(" --prompt-file ") == true)
        #expect(cmd?.contains(" resume") == true)
        #expect(cmd?.contains(".crow-review-prompt.md") == true)
        #expect(cmd?.contains(".crow-job-prompt.md") == false)
        // Strip-not-trust: review never gets --trust-workspace.
        #expect(cmd?.contains("--trust-workspace") == false)
        // Auto-perm is honored so unattended `gh pr review` can post.
        #expect(cmd?.contains("--disable-approval") == true)
        #expect(cmd?.contains("--yolo") == false)
    }

    @Test func reviewSubsequentLaunchResumesWithoutRerun() {
        var session = Session(name: "review", kind: .review, agentKind: .muse)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd?.contains(".crow-review-prompt.md") == false)
        #expect(cmd?.contains(" exec") == false)
        #expect(cmd?.contains(" resume") == true)
        #expect(cmd?.contains("--trust-workspace") == false)
        #expect(cmd?.hasSuffix("\n") == true)
    }

    @Test func jobSubsequentLaunchCarriesAutoFlagsAndTrust() {
        var session = Session(name: "job", kind: .job, agentKind: .muse)
        session.reviewPromptDispatched = true
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: true, telemetryPort: nil)
        #expect(cmd?.contains(" resume") == true)
        #expect(cmd?.contains(" exec") == false)
        #expect(cmd?.contains("--disable-approval") == true)
        #expect(cmd?.contains("--trust-workspace") == true)
    }

    @Test func managerSessionUnsupported() {
        let session = Session(name: "manager", kind: .manager, agentKind: .muse)
        let cmd = agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt",
            remoteControlEnabled: false, autoPermissionMode: false, telemetryPort: nil)
        #expect(cmd == nil)
    }

    @Test func managerLaunchCommandTrustsAndHonorsAutoPerm() {
        let cmd = agent.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: true,
            autoPermissionMode: true, telemetryPort: 4318)
        #expect(cmd.hasPrefix("'"))
        #expect(cmd.contains("muse"))
        #expect(cmd.contains("--trust-workspace"))
        #expect(cmd.contains("--disable-approval"))
        #expect(!cmd.contains("--yolo"))
        #expect(!cmd.contains("--rc"))
        #expect(!cmd.contains("\n"))
    }

    @Test func launcherHandoffCommandUsesPassedBinaryQuoted() async throws {
        let launcher = MuseLauncher()
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(),
            worktreePath: "/tmp/wt",
            prompt: "do the thing",
            binary: "/opt/my tools/muse"
        )
        #expect(cmd.contains("'/opt/my tools/muse'"))
        #expect(cmd.contains("--prompt-file"))
        #expect(cmd.contains(" resume"))
        #expect(cmd.contains("--trust-workspace"))
        #expect(!cmd.contains("--yolo"))
    }

    @Test func findBinaryDoesNotCrash() {
        _ = agent.findBinary()
    }

    // MARK: - Identity probe

    @Test func identityProbeAcceptsMuseCodeFlags() async {
        let runner = FakeProbeRunner(outputs: [
            "--version": "muse 0.1.0",
            "--help": """
                Usage: muse [OPTIONS] [COMMAND]
                Commands:
                  exec      Run one prompt headlessly
                  resume    Reopen a retained session
                Options:
                  --disable-approval     Skip approval prompts; keep the sandbox
                  --trust-workspace      Trust this workspace for the run
                  --sandbox-network <MODE>
                  --prompt-file <PATH>   Read the prompt from a file (exec)
                  --yolo                 Disable approval and the sandbox
                """,
        ])
        let agent = MuseAgent(probeRunner: runner)
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/muse") == true)
    }

    @Test func identityProbeRejectsMuseSequencer() async {
        let runner = FakeProbeRunner(outputs: [
            "--version": "Muse Sequencer 4.2.1",
            "--help": """
                Muse Sequencer — MIDI/audio sequencer
                Usage: muse [options]
                Options:
                  --audio <backend>   JACK, ALSA, or dummy
                  --midi <backend>
                  --help              Show help
                """,
        ])
        let agent = MuseAgent(probeRunner: runner)
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/muse") == false)
    }

    @Test func identityProbeRejectsEmptyOutput() async {
        let agent = MuseAgent(probeRunner: FakeProbeRunner(outputs: [:]))
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/muse") == false)
    }

    @Test func identityProbeToleratesNonZeroExit() async {
        let runner = FakeProbeRunner(
            outputs: ["--help": "muse --disable-approval --trust-workspace", "--version": ""],
            failing: ["--help"]
        )
        let agent = MuseAgent(probeRunner: runner)
        #expect(await agent.verifyBinaryIdentity(atPath: "/opt/homebrew/bin/muse") == true)
    }
}

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
