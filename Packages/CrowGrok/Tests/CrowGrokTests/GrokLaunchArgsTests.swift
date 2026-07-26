import Testing
@testable import CrowGrok

@Suite("GrokLaunchArgs")
struct GrokLaunchArgsTests {

    @Test func shellQuoteWrapsAndEscapes() {
        #expect(GrokLaunchArgs.shellQuote("/tmp/p.md") == "'/tmp/p.md'")
        #expect(GrokLaunchArgs.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func autoPermissionSuffixOffIsEmpty() {
        #expect(GrokLaunchArgs.autoPermissionSuffix(autoPermissionMode: false) == "")
    }

    @Test func autoPermissionSuffixOnIsBoundedNotYolo() {
        let s = GrokLaunchArgs.autoPermissionSuffix(autoPermissionMode: true)
        #expect(s.contains("--permission-mode auto"))
        #expect(s.contains("--deny 'Bash(rm -rf /)'"))
        #expect(s.contains("--deny 'Bash(rm -rf /*)'"))
        // Never the full-bypass forms.
        #expect(!s.contains("--yolo"))
        #expect(!s.contains("--always-approve"))
        #expect(!s.contains("bypassPermissions"))
    }

    @Test func firstLaunchChainedCommandUsesHeadlessThenContinue() {
        let cmd = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: "/opt/homebrew/bin/grok",
            promptPath: "/tmp/wt/.crow-job-prompt.md",
            autoPermissionMode: false
        )
        #expect(cmd == "/opt/homebrew/bin/grok -p \"$(cat '/tmp/wt/.crow-job-prompt.md')\""
            + "; /opt/homebrew/bin/grok -c\n")
        // Semicolon (not &&) so the TUI opens even if the headless leg fails;
        // never a pipe (which would bind stdin and break the TUI).
        #expect(!cmd.contains(" && "))
        #expect(!cmd.contains(" | "))
    }

    @Test func firstLaunchChainedCommandAddsAutoFlagsToBothLegs() {
        let cmd = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: "grok",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true
        )
        // Both the headless leg and the resumed TUI carry the bounded flags.
        #expect(cmd.contains("grok --permission-mode auto"))
        // Two occurrences of the mode flag (one per leg).
        let occurrences = cmd.components(separatedBy: "--permission-mode auto").count - 1
        #expect(occurrences == 2)
    }

    @Test func firstLaunchChainedCommandShellQuotesPromptPath() {
        let cmd = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: "grok",
            promptPath: "/tmp/my worktree/.crow-job-prompt.md",
            autoPermissionMode: false
        )
        #expect(cmd.contains("$(cat '/tmp/my worktree/.crow-job-prompt.md')"))
    }

    @Test func resumeTUICommandContinuesTheSession() {
        #expect(GrokLaunchArgs.resumeTUICommand(binary: "grok", autoPermissionMode: false)
            == "grok -c\n")
    }

    @Test func resumeTUICommandCarriesAutoForResumedJobs() {
        let cmd = GrokLaunchArgs.resumeTUICommand(binary: "grok", autoPermissionMode: true)
        #expect(cmd.contains("--permission-mode auto"))
        #expect(cmd.contains(" -c\n"))
    }

    @Test func bareCommandIsJustTheBinary() {
        #expect(GrokLaunchArgs.bareCommand(binary: "grok") == "grok\n")
    }
}
