import Testing
@testable import CrowOpenCode

@Suite("OpenCodeLaunchArgs")
struct OpenCodeLaunchArgsTests {
    private let helpWithAuto = """
    Options:
      -c, --continue      continue the last session
          --prompt        prompt to use
          --auto          auto-approve permissions
    """

    private let helpWithoutAuto = """
    Options:
      -c, --continue      continue the last session
          --prompt        prompt to use
    """

    @Test func parseTUISupportsAutoWhenAdvertised() {
        #expect(OpenCodeLaunchArgs.parseTUISupportsAuto(from: helpWithAuto) == true)
    }

    @Test func parseTUISupportsAutoWhenAbsent() {
        #expect(OpenCodeLaunchArgs.parseTUISupportsAuto(from: helpWithoutAuto) == false)
    }

    @Test func seededTUICommandUsesStdinPipe() {
        let cmd = OpenCodeLaunchArgs.seededTUICommand(
            binary: "/opt/homebrew/bin/opencode",
            promptPath: "/tmp/wt/.crow-job-prompt.md",
            autoPermissionMode: false,
            tuiSupportsAuto: true
        )
        #expect(cmd == "cat /tmp/wt/.crow-job-prompt.md | /opt/homebrew/bin/opencode\n")
        #expect(cmd.contains(" run ") == false)
        #expect(cmd.contains("--prompt") == false)
    }

    @Test func seededTUICommandAddsAutoWhenSupported() {
        let cmd = OpenCodeLaunchArgs.seededTUICommand(
            binary: "opencode",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true,
            tuiSupportsAuto: true
        )
        #expect(cmd.hasSuffix("opencode --auto\n"))
    }

    @Test func seededTUICommandOmitsAutoWhenUnsupported() {
        let cmd = OpenCodeLaunchArgs.seededTUICommand(
            binary: "opencode",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true,
            tuiSupportsAuto: false
        )
        #expect(cmd == "cat /tmp/p.md | opencode\n")
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
