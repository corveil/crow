import Foundation
import CrowCore

/// `CodeBackend` implementation for GitHub. Wraps the `gh` CLI for PR/label operations.
///
/// Capabilities:
/// - `.autoMergeLabel` — supports `gh label create crow:merge`.
/// - `.batchedPRStates` — could fetch multiple PR states in one GraphQL call.
///
/// See ADR 0005 for the protocol contract.
public struct GitHubCodeBackend: CodeBackend {
    public let provider: Provider = .github
    public let capabilities: Set<CodeCapability> = [.autoMergeLabel, .batchedPRStates]

    private let shellRunner: ShellRunner

    public init(shellRunner: ShellRunner) {
        self.shellRunner = shellRunner
    }

    public func linkedPR(repo: String, branch: String) async throws -> LinkedPR? {
        let output = try await shellRunner.run(
            "gh", "pr", "list",
            "--repo", repo,
            "--head", branch,
            "--state", "all",
            "--json", "number,url,state",
            "--limit", "1"
        )
        guard let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let number = first["number"] as? Int,
              let url = first["url"] as? String,
              let state = first["state"] as? String else {
            return nil
        }
        return LinkedPR(number: number, url: url, state: state)
    }

    public func ensureMergeLabel(repo: String) async throws {
        // `gh label create` is idempotent-ish: it errors if the label already
        // exists. Swallow that one error; surface anything else.
        do {
            _ = try await shellRunner.run(
                "gh", "label", "create", "crow:merge",
                "--repo", repo,
                "--color", "1D76DB",
                "--description", "Auto-merge when checks pass"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            if output.localizedCaseInsensitiveContains("already exists") { return }
            throw ShellRunnerError.nonZeroExit(exitCode: 1, output: output)
        }
    }
}
