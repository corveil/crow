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
        // `--prompt-file <path>` (not `-p "$(cat …)"`): Grok reads the file, so a
        // large prompt never becomes a giant argv or rides a subshell. Both the
        // binary and the path are shell-quoted so a space can't word-split.
        #expect(cmd == "'/opt/homebrew/bin/grok' --prompt-file '/tmp/wt/.crow-job-prompt.md'"
            + "; '/opt/homebrew/bin/grok' -c\n")
        // Semicolon (not &&) so the TUI opens even if the headless leg fails;
        // never a pipe or a `$(cat …)` subshell.
        #expect(!cmd.contains(" && "))
        #expect(!cmd.contains(" | "))
        #expect(!cmd.contains("$(cat"))
        #expect(!cmd.contains(" -p "))
    }

    @Test func firstLaunchChainedCommandAddsAutoFlagsToBothLegs() {
        let cmd = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: "grok",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true
        )
        // Both the headless leg and the resumed TUI carry the bounded flags.
        #expect(cmd.contains("'grok' --permission-mode auto"))
        // Two occurrences of the mode flag: flagged headless + flagged resume. The
        // bare `||` fallbacks on each leg carry none.
        let occurrences = cmd.components(separatedBy: "--permission-mode auto").count - 1
        #expect(occurrences == 2)
        // Flag-rejection fallback on BOTH legs (#861 r12-r14): the headless leg
        // (carries the prompt) and the resume leg each fall back to a bare form —
        // gated on clap's exit-2 usage error, so an upstream `--permission-mode`/
        // `--deny` rename neither loses the prompt nor strands the resume, while a
        // mid-turn failure or Ctrl-C does NOT trigger a re-run.
        #expect(cmd.contains("--prompt-file '/tmp/p.md' || { [ $? -eq 2 ] && 'grok' --prompt-file '/tmp/p.md'; }"))
        #expect(cmd.contains(" -c || { [ $? -eq 2 ] && 'grok' -c; }\n"))
    }

    @Test func firstLaunchChainedCommandShellQuotesPromptPath() {
        let cmd = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: "grok",
            promptPath: "/tmp/my worktree/.crow-job-prompt.md",
            autoPermissionMode: false
        )
        #expect(cmd.contains("--prompt-file '/tmp/my worktree/.crow-job-prompt.md'"))
    }

    @Test func firstLaunchChainedCommandShellQuotesBinaryPath() {
        // A `defaults.binaries.grok` override with a space must not word-split.
        let cmd = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: "/opt/my tools/grok",
            promptPath: "/tmp/p.md",
            autoPermissionMode: false
        )
        #expect(cmd.hasPrefix("'/opt/my tools/grok' --prompt-file "))
        #expect(cmd.contains("; '/opt/my tools/grok' -c\n"))
    }

    @Test func resumeTUICommandContinuesTheSession() {
        // No auto flags → bare resume, no fallback needed (nothing to reject).
        #expect(GrokLaunchArgs.resumeTUICommand(binary: "grok", autoPermissionMode: false)
            == "'grok' -c\n")
    }

    @Test func resumeTUICommandCarriesAutoForResumedJobs() {
        let cmd = GrokLaunchArgs.resumeTUICommand(binary: "grok", autoPermissionMode: true)
        #expect(cmd.contains("--permission-mode auto"))
        // Every restart of an auto job also gets the exit-2 flag-rejection fallback,
        // so a later upstream flag change can't make each restart die identically.
        #expect(cmd.hasSuffix(" -c || { [ $? -eq 2 ] && 'grok' -c; }\n"))
    }

    @Test func resumeLegFallbackIsExitTwoGated() {
        // No flags → bare resume, no fallback (nothing to reject).
        #expect(GrokLaunchArgs.resumeLeg(bin: "'grok'", flags: "") == "'grok' -c")
        // Flags present → retry bare ONLY on clap's exit-2 usage error, never on a
        // Ctrl-C (130) or other non-zero — so the pane doesn't reopen on quit.
        #expect(GrokLaunchArgs.resumeLeg(bin: "'grok'", flags: " --permission-mode auto")
            == "'grok' --permission-mode auto -c || { [ $? -eq 2 ] && 'grok' -c; }")
    }

    @Test func headlessLegFallbackIsExitTwoGated() {
        // Same exit-2-gated shape for the prompt-consuming leg (#861 r14): a flag
        // rejection still consumes the prompt (at `ask`), but a mid-turn failure
        // does NOT re-run the whole job. No fallback when flags are empty.
        #expect(GrokLaunchArgs.headlessLeg(bin: "'grok'", flags: "", quotedPath: "'/p.md'")
            == "'grok' --prompt-file '/p.md'")
        #expect(GrokLaunchArgs.headlessLeg(bin: "'grok'", flags: " --permission-mode auto", quotedPath: "'/p.md'")
            == "'grok' --permission-mode auto --prompt-file '/p.md' || { [ $? -eq 2 ] && 'grok' --prompt-file '/p.md'; }")
    }

    @Test func bareCommandIsJustTheQuotedBinary() {
        #expect(GrokLaunchArgs.bareCommand(binary: "grok") == "'grok'\n")
        #expect(GrokLaunchArgs.bareCommand(binary: "/opt/my tools/grok") == "'/opt/my tools/grok'\n")
    }
}
