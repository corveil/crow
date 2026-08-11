import Foundation
import Testing
@testable import CrowCore

@Suite("ShellLaunchArgs")
struct ShellLaunchArgsTests {
    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(ShellLaunchArgs.shellQuote("plain") == "'plain'")
        #expect(ShellLaunchArgs.shellQuote("has'quote") == "'has'\\''quote'")
    }

    @Test func evalPromptLaunchAvoidsCatSubshell() {
        let cmd = ShellLaunchArgs.evalPromptLaunch(
            prefix: "'agent' --force",
            promptPath: "/tmp/wt/.crow-review-prompt.md")
        #expect(cmd.contains("_CROW_P=$(< '/tmp/wt/.crow-review-prompt.md')"))
        #expect(cmd.contains("eval \"'agent' --force $(printf '%q'"))
        #expect(!cmd.contains("$(cat"))
    }

    @Test func evalPromptLaunchQuotesPathsWithSpaces() {
        let cmd = ShellLaunchArgs.evalPromptLaunch(
            prefix: "'agent'",
            promptPath: "/Users/x/My Projects/wt/.crow-job-prompt.md")
        #expect(cmd.contains("'/Users/x/My Projects/wt/.crow-job-prompt.md'"))
    }

    /// #957 repro: inlined SKILL bodies contain `"` and `$` — launch must preserve them.
    @Test func evalPromptLaunchSurvivesQuotesAndDollars() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "shell-launch-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let promptFile = tmp.appendingPathComponent(".crow-review-prompt.md")
        let expected = "test \"quotes\" $HOME "
        try expected.write(to: promptFile, atomically: true, encoding: .utf8)

        let launch = ShellLaunchArgs.evalPromptLaunch(
            prefix: "'agent' --force",
            promptPath: promptFile.path).trimmingCharacters(in: .newlines)

        let script = "agent() { printf '%s' \"$2\"; }; \(launch)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(out == expected)
    }

    // MARK: - End-of-options separator (CROW-968)

    @Test func evalPromptLaunchEmitsSeparatorWhenAsked() {
        let cmd = ShellLaunchArgs.evalPromptLaunch(
            prefix: "'agent' --trust --force",
            promptPath: "/tmp/wt/.crow-review-prompt.md",
            endOfOptions: true)

        // The `--` must sit immediately before the prompt substitution, after the
        // agent's own flags — anywhere earlier and `--trust`/`--force` would
        // themselves become operands.
        #expect(cmd.contains("eval \"'agent' --trust --force -- $(printf '%q'"))
    }

    /// The separator is opt-in per agent (Claude/Codex/OpenCode/Antigravity share
    /// this helper and their parsers are unverified), so omitting it must produce
    /// byte-identical output to the pre-CROW-968 form.
    @Test func evalPromptLaunchWithoutSeparatorIsUnchanged() {
        let cmd = ShellLaunchArgs.evalPromptLaunch(
            prefix: "'agent' --force",
            promptPath: "/tmp/wt/.crow-review-prompt.md")

        #expect(cmd == "_CROW_P=$(< '/tmp/wt/.crow-review-prompt.md'); "
            + "eval \"'agent' --force $(printf '%q' \"$_CROW_P\")\"\n")
        #expect(!cmd.contains(" -- "))
    }

    /// CROW-968 repro at the shell layer: the review prompt began with `---`, and
    /// Cursor's `agent` read it as a flag. Proves `--` lands as its own argv
    /// element and the hyphen-leading body still arrives intact — quoting alone
    /// never fixed this, since a leading `-` is not shell-special.
    @Test func evalPromptLaunchSeparatorSurvivesAHyphenLeadingPrompt() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "shell-launch-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let promptFile = tmp.appendingPathComponent(".crow-review-prompt.md")
        let expected = "---\nname: crow-review-pr\n---\n\n# Crow Review PR"
        try expected.write(to: promptFile, atomically: true, encoding: .utf8)

        let launch = ShellLaunchArgs.evalPromptLaunch(
            prefix: "'agent' --force",
            promptPath: promptFile.path,
            endOfOptions: true).trimmingCharacters(in: .newlines)

        // `$1` is `--` and `$2` is the prompt: the separator must be a distinct
        // argv element, not glued onto the body.
        let script = "agent() { printf '%s|%s' \"$2\" \"$3\"; }; \(launch)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(out == "--|\(expected)")
    }
}
