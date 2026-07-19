import Foundation

/// Runs subprocesses on behalf of provider backends.
///
/// Provider backends (`GitHubTaskBackend`, `GitLabCodeBackend`, …) take a `ShellRunner`
/// at init so unit tests can inject a fake that returns canned JSON and asserts the
/// command vector. The production implementation is `ProcessShellRunner`, which uses
/// `Process()` with the resolved PATH from `ShellEnvironment.shared`.
///
/// See ADR 0005 — TaskBackend and CodeBackend protocols.
public protocol ShellRunner: Sendable {
    /// Run a subprocess and return its stdout (and stderr — they're merged).
    ///
    /// - Parameters:
    ///   - args: Command and arguments, e.g. `["gh", "issue", "view", url]`.
    ///   - env: Additional environment variables merged on top of `ShellEnvironment.shared.env`.
    ///   - cwd: Working directory. Pass `nil` to inherit the current process's cwd.
    /// - Returns: stdout+stderr as a UTF-8 string.
    /// - Throws: `ShellRunnerError.nonZeroExit` if the process returns non-zero.
    func run(args: [String], env: [String: String], cwd: String?) async throws -> String
}

extension ShellRunner {
    /// Variadic convenience: `try await runner.run("gh", "issue", "view", url)`.
    public func run(_ args: String...) async throws -> String {
        try await run(args: args, env: [:], cwd: nil)
    }

    /// Convenience for the common case of `env` only.
    public func run(env: [String: String], _ args: String...) async throws -> String {
        try await run(args: args, env: env, cwd: nil)
    }
}

public enum ShellRunnerError: Error, LocalizedError, Sendable {
    /// Process exited non-zero. `output` is the merged stdout+stderr.
    case nonZeroExit(exitCode: Int32, output: String)

    /// Surfaces exit code + subprocess output so callers logging
    /// `error.localizedDescription` get the real stderr (e.g. `gh` GraphQL
    /// errors) instead of the useless `ShellRunnerError error 0` default
    /// (CROW-621).
    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let exitCode, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed with exit code \(exitCode)"
            }
            return "Command failed with exit code \(exitCode): \(trimmed)"
        }
    }
}

/// Default production implementation: spawns `/usr/bin/env <args>` with
/// `ShellEnvironment.shared` merged in, captures stdout+stderr.
public struct ProcessShellRunner: ShellRunner {
    public init() {}

    public func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = env.isEmpty
            ? ShellEnvironment.shared.env
            : ShellEnvironment.shared.merging(env)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = pipe
        process.standardError = pipe

        // Drain the pipe on a background task so a >64KB output can't deadlock waitUntilExit.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            Task.detached {
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    cont.resume(throwing: ShellRunnerError.nonZeroExit(
                        exitCode: process.terminationStatus,
                        output: output
                    ))
                }
            }
        }
    }
}
