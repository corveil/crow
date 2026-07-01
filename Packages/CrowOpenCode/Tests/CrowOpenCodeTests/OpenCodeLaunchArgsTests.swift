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
        #expect(cmd == "/opt/homebrew/bin/opencode run \"$(cat /tmp/wt/.crow-job-prompt.md)\""
            + " && /opt/homebrew/bin/opencode --continue\n")
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
        #expect(cmd.contains(" run \"$(cat /tmp/p.md)\" --auto"))
        #expect(cmd.contains(" && opencode --continue --auto\n"))
    }

    @Test func firstLaunchChainedCommandOmitsUnsupportedAutoFlags() {
        let cmd = OpenCodeLaunchArgs.firstLaunchChainedCommand(
            binary: "opencode",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true,
            tuiSupportsAuto: false,
            runHelpText: tuiHelpWithoutAuto
        )
        #expect(cmd == "opencode run \"$(cat /tmp/p.md)\" && opencode --continue\n")
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
}
