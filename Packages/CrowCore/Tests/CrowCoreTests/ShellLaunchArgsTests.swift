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
}
