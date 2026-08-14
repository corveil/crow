import Testing
@testable import CrowMuse

@Suite("MuseLaunchArgs")
struct MuseLaunchArgsTests {

    @Test func shellQuoteWrapsAndEscapes() {
        #expect(MuseLaunchArgs.shellQuote("/tmp/p.md") == "'/tmp/p.md'")
        #expect(MuseLaunchArgs.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func autoPermissionSuffixOffIsEmpty() {
        #expect(MuseLaunchArgs.autoPermissionSuffix(autoPermissionMode: false) == "")
    }

    @Test func autoPermissionSuffixOnIsBoundedNotYolo() {
        let s = MuseLaunchArgs.autoPermissionSuffix(autoPermissionMode: true)
        #expect(s == " --disable-approval")
        #expect(!s.contains("--yolo"))
        #expect(!s.contains("--disable-sandbox"))
    }

    @Test func trustSuffixOffIsEmpty() {
        #expect(MuseLaunchArgs.trustSuffix(trustWorkspace: false) == "")
    }

    @Test func trustSuffixOnIsTrustWorkspaceOnly() {
        #expect(MuseLaunchArgs.trustSuffix(trustWorkspace: true) == " --trust-workspace")
    }

    @Test func firstLaunchChainedCommandUsesExecThenResume() {
        let cmd = MuseLaunchArgs.firstLaunchChainedCommand(
            binary: "/opt/homebrew/bin/muse",
            promptPath: "/tmp/wt/.crow-job-prompt.md",
            autoPermissionMode: false,
            trustWorkspace: true
        )
        #expect(cmd == "'/opt/homebrew/bin/muse' exec --trust-workspace --prompt-file '/tmp/wt/.crow-job-prompt.md'"
            + " || { [ $? -eq 2 ] && '/opt/homebrew/bin/muse' exec --prompt-file '/tmp/wt/.crow-job-prompt.md'; }"
            + "; '/opt/homebrew/bin/muse' --trust-workspace resume"
            + " || { [ $? -eq 2 ] && '/opt/homebrew/bin/muse' resume; }\n")
        // The two legs are joined by `;`, not `&&` — a failed exec still
        // opens the TUI. The exit-2 fallbacks themselves contain `&&`; that
        // is not the chain.
        #expect(cmd.contains("; '/opt/homebrew/bin/muse' --trust-workspace resume"))
        #expect(!cmd.contains("$(cat"))
        #expect(!cmd.contains(" -p "))
        #expect(!cmd.contains("--yolo"))
    }

    @Test func firstLaunchWithoutFlagsHasNoFallback() {
        let cmd = MuseLaunchArgs.firstLaunchChainedCommand(
            binary: "muse",
            promptPath: "/tmp/p.md",
            autoPermissionMode: false,
            trustWorkspace: false
        )
        #expect(cmd == "'muse' exec --prompt-file '/tmp/p.md'; 'muse' resume\n")
        #expect(!cmd.contains("||"))
    }

    @Test func firstLaunchAddsAutoFlagsToBothLegs() {
        let cmd = MuseLaunchArgs.firstLaunchChainedCommand(
            binary: "muse",
            promptPath: "/tmp/p.md",
            autoPermissionMode: true,
            trustWorkspace: true
        )
        let autoCount = cmd.components(separatedBy: "--disable-approval").count - 1
        // Flagged exec + flagged resume. Bare fallbacks carry none.
        #expect(autoCount == 2)
        #expect(cmd.contains("exec --disable-approval --trust-workspace --prompt-file"))
        #expect(cmd.contains("'muse' --disable-approval --trust-workspace resume"))
        #expect(cmd.contains("|| { [ $? -eq 2 ] && 'muse' exec --prompt-file '/tmp/p.md'; }"))
        #expect(cmd.contains("|| { [ $? -eq 2 ] && 'muse' resume; }"))
        #expect(!cmd.contains("--yolo"))
    }

    @Test func firstLaunchReviewOmitsTrust() {
        let cmd = MuseLaunchArgs.firstLaunchChainedCommand(
            binary: "muse",
            promptPath: "/tmp/wt/.crow-review-prompt.md",
            autoPermissionMode: true,
            trustWorkspace: false
        )
        #expect(cmd.contains("--disable-approval"))
        #expect(!cmd.contains("--trust-workspace"))
        #expect(cmd.contains(".crow-review-prompt.md"))
    }

    @Test func firstLaunchShellQuotesPromptPathAndBinary() {
        let cmd = MuseLaunchArgs.firstLaunchChainedCommand(
            binary: "/opt/my tools/muse",
            promptPath: "/tmp/my worktree/.crow-job-prompt.md",
            autoPermissionMode: false,
            trustWorkspace: false
        )
        #expect(cmd.hasPrefix("'/opt/my tools/muse' exec --prompt-file "))
        #expect(cmd.contains("'/tmp/my worktree/.crow-job-prompt.md'"))
        #expect(cmd.contains("; '/opt/my tools/muse' resume\n"))
    }

    @Test func resumeTUICommandBare() {
        #expect(MuseLaunchArgs.resumeTUICommand(
            binary: "muse", autoPermissionMode: false, trustWorkspace: false)
            == "'muse' resume\n")
    }

    @Test func resumeTUICommandCarriesAutoForResumedJobs() {
        let cmd = MuseLaunchArgs.resumeTUICommand(
            binary: "muse", autoPermissionMode: true, trustWorkspace: true)
        #expect(cmd.contains("--disable-approval"))
        #expect(cmd.contains("--trust-workspace"))
        #expect(cmd.hasSuffix(" resume || { [ $? -eq 2 ] && 'muse' resume; }\n"))
    }

    @Test func resumeLegFallbackIsExitTwoGated() {
        #expect(MuseLaunchArgs.resumeLeg(bin: "'muse'", flags: "") == "'muse' resume")
        #expect(MuseLaunchArgs.resumeLeg(bin: "'muse'", flags: " --disable-approval")
            == "'muse' --disable-approval resume || { [ $? -eq 2 ] && 'muse' resume; }")
    }

    @Test func headlessLegFallbackIsExitTwoGated() {
        #expect(MuseLaunchArgs.headlessLeg(bin: "'muse'", flags: "", quotedPath: "'/p.md'")
            == "'muse' exec --prompt-file '/p.md'")
        #expect(MuseLaunchArgs.headlessLeg(
            bin: "'muse'", flags: " --disable-approval", quotedPath: "'/p.md'")
            == "'muse' exec --disable-approval --prompt-file '/p.md' || { [ $? -eq 2 ] && 'muse' exec --prompt-file '/p.md'; }")
    }

    @Test func bareCommandQuotesAndOptionallyTrusts() {
        #expect(MuseLaunchArgs.bareCommand(binary: "muse", trustWorkspace: true)
            == "'muse' --trust-workspace\n")
        #expect(MuseLaunchArgs.bareCommand(binary: "/opt/my tools/muse", trustWorkspace: false)
            == "'/opt/my tools/muse'\n")
    }

    @Test func managerCommandHasNoTrailingNewline() {
        let cmd = MuseLaunchArgs.managerCommand(
            binary: "muse", autoPermissionMode: true, trustWorkspace: true)
        #expect(cmd == "'muse' --disable-approval --trust-workspace")
        #expect(!cmd.contains("\n"))
        #expect(!cmd.contains("--yolo"))
    }
}
