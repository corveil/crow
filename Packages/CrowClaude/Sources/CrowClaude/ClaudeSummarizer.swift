import Foundation
import CrowCore

/// Turns the deterministic Changes-summary digest into a short narrative by
/// shelling out to the `claude` CLI in print mode (`claude -p`). Crow's whole
/// premise is orchestrating the `claude` CLI, so it's the natural LLM path —
/// no API key, no in-app HTTP client, reuses the user's existing Claude auth.
public struct ClaudeSummarizer: Sendable {
    public init() {}

    public enum SummarizeError: Error, LocalizedError {
        case claudeNotFound
        case empty
        case commandFailed(stderr: String)

        public var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "The `claude` CLI wasn't found on your PATH. Install Claude Code to use LLM Summarize."
            case .empty:
                return "Claude returned an empty response."
            case .commandFailed(let stderr):
                return "Claude exited with an error: \(stderr.isEmpty ? "no output" : stderr)"
            }
        }
    }

    /// Instruction wrapped around the digest. Kept terse — the deterministic
    /// digest is the source of truth; we only want a readable gloss of it.
    private static let instruction = """
    You are summarizing recent code changes across several git repositories for a \
    developer skimming their day. Below is a deterministic digest: per-repo commit \
    counts and diffstats, followed by one line per commit (short hash, subject, \
    +insertions/-deletions). Write a concise narrative of what changed — 3 to 6 \
    sentences, grouped by theme rather than by repo where it reads better. Be \
    specific about features and fixes; skip the per-commit detail. Output only the \
    narrative prose, no headings or preamble.

    DIGEST:
    """

    /// Run `claude -p "<instruction + digest>"`, returning the trimmed narrative.
    public func summarize(digest: String) async throws -> String {
        guard ShellEnvironment.shared.hasCommand("claude") else {
            throw SummarizeError.claudeNotFound
        }
        let prompt = "\(Self.instruction)\n\(digest)"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "-p", prompt]
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw SummarizeError.commandFailed(stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let narrative = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !narrative.isEmpty else { throw SummarizeError.empty }
        return narrative
    }
}
