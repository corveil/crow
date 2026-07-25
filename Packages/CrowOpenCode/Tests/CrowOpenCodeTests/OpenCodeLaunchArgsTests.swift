import Testing
@testable import CrowOpenCode

@Suite("OpenCodeLaunchArgs")
struct OpenCodeLaunchArgsTests {
    private let tuiHelpWithAuto = """
    Options:
      -c, --continue      continue the last session
          --auto          auto-approve permissions
    """

    private let tuiHelpWithoutAuto = """
    Options:
      -c, --continue      continue the last session
    """

    private let runHelpWithDangerously = """
    Options:
      --dangerously-skip-permissions  auto-approve permissions
    """

    private let runHelpWithAuto = """
    Options:
      --auto          auto-approve permissions
    """

    @Test func parseTUISupportsAutoWhenAdvertised() {
        #expect(OpenCodeLaunchArgs.parseTUISupportsAuto(from: tuiHelpWithAuto) == true)
    }

    @Test func parseTUISupportsAutoWhenAbsent() {
        #expect(OpenCodeLaunchArgs.parseTUISupportsAuto(from: tuiHelpWithoutAuto) == false)
    }

    @Test func runAutoApproveSuffixUsesDangerouslySkipPermissions() {
        #expect(
            OpenCodeLaunchArgs.runAutoApproveSuffix(
                autoPermissionMode: true,
                runHelpText: runHelpWithDangerously
            ) == " --dangerously-skip-permissions"
        )
    }

    @Test func runAutoApproveSuffixPrefersAutoWhenAdvertised() {
        #expect(
            OpenCodeLaunchArgs.runAutoApproveSuffix(
                autoPermissionMode: true,
                runHelpText: runHelpWithAuto + runHelpWithDangerously
            ) == " --auto"
        )
    }

    @Test func firstLaunchChainedCommandUsesRunThenContinue() {
        let cmd = OpenCodeLaunchArgs.firstLaunchChainedCommand(
            binary: "/opt/homebrew/bin/opencode",
            promptPath: "/tmp/wt/.crow-job-prompt.md",
            autoPermissionMode: false,
            tuiSupportsAuto: true,
            runHelpText: runHelpWithDangerously
        )
        #expect(cmd == "/opt/homebrew/bin/opencode run \"$(cat '/tmp/wt/.crow-job-prompt.md')\""
            + "; /opt/homebrew/bin/opencode --continue\n")
        #expect(cmd.contains(" | ") == false)
    }

    @Test func firstLaunchChainedCommandAddsRunAndContinueAutoFlags() {
        let cmd = OpenCodeLaunchArgs.firstLaunchChainedCommand(
            binary: "opencode",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true,
            tuiSupportsAuto: true,
            runHelpText: runHelpWithAuto
        )
        #expect(cmd.contains(" run \"$(cat '/tmp/p.md')\" --auto"))
        #expect(cmd.contains("; opencode --continue --auto\n"))
    }

    @Test func firstLaunchChainedCommandOmitsUnsupportedAutoFlags() {
        let cmd = OpenCodeLaunchArgs.firstLaunchChainedCommand(
            binary: "opencode",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true,
            tuiSupportsAuto: false,
            runHelpText: tuiHelpWithoutAuto
        )
        #expect(cmd == "opencode run \"$(cat '/tmp/p.md')\"; opencode --continue\n")
    }

    @Test func firstLaunchChainedCommandShellQuotesPromptPath() {
        let cmd = OpenCodeLaunchArgs.firstLaunchChainedCommand(
            binary: "opencode",
            promptPath: "/tmp/my worktree/.crow-job-prompt.md",
            autoPermissionMode: false,
            tuiSupportsAuto: false,
            runHelpText: ""
        )
        #expect(cmd.contains("$(cat '/tmp/my worktree/.crow-job-prompt.md')"))
    }

    @Test func resumeTUICommandCarriesAutoForResumedJobs() {
        let cmd = OpenCodeLaunchArgs.resumeTUICommand(
            binary: "opencode",
            autoPermissionMode: true,
            tuiSupportsAuto: true
        )
        #expect(cmd == "opencode --continue --auto\n")
    }

    @Test func resumeTUICommandOmitsAutoWhenUnsupported() {
        let cmd = OpenCodeLaunchArgs.resumeTUICommand(
            binary: "opencode",
            autoPermissionMode: true,
            tuiSupportsAuto: false
        )
        #expect(cmd == "opencode --continue\n")
    }

    // MARK: - Version-aware TUI `--auto` probe narrowing (CROW-831)

    @Test func parseVersionExtractsSemVer() {
        #expect(OpenCodeLaunchArgs.parseVersion("1.17.10") == OpenCodeLaunchArgs.SemVer(1, 17, 10))
        // Tolerates a name prefix and trailing noise.
        #expect(OpenCodeLaunchArgs.parseVersion("opencode 1.18.4\n") == OpenCodeLaunchArgs.SemVer(1, 18, 4))
        #expect(OpenCodeLaunchArgs.parseVersion("v2.0.0-beta") == OpenCodeLaunchArgs.SemVer(2, 0, 0))
        #expect(OpenCodeLaunchArgs.parseVersion("no version here") == nil)
    }

    @Test func semVerOrdersByField() {
        #expect(OpenCodeLaunchArgs.SemVer(1, 17, 10) < OpenCodeLaunchArgs.SemVer(1, 18, 0))
        #expect(OpenCodeLaunchArgs.SemVer(1, 18, 0) < OpenCodeLaunchArgs.SemVer(1, 18, 1))
        #expect(!(OpenCodeLaunchArgs.SemVer(2, 0, 0) < OpenCodeLaunchArgs.SemVer(1, 99, 99)))
    }

    @Test func tuiAutoKnownAbsentOnlyForRemovedWindow() {
        // [1.17.0, 1.18.0): the top-level `--auto` flag was dropped, skip the probe.
        #expect(OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(1, 17, 0)))
        #expect(OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(1, 17, 10)))
        // < 1.17: the flag was still present — must probe, not "known absent".
        #expect(!OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(1, 16, 9)))
        #expect(!OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(1, 0, 0)))
        // >= 1.18: `--auto` was re-added — must still probe (not "known absent").
        #expect(!OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(1, 18, 0)))
        #expect(!OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(1, 18, 4)))
        #expect(!OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: OpenCodeLaunchArgs.SemVer(2, 0, 0)))
        // Unknown version → never assume absent; fall through to the probe.
        #expect(!OpenCodeLaunchArgs.tuiAutoKnownAbsent(version: nil))
    }
}
