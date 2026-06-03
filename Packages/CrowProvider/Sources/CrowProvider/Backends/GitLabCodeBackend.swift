import Foundation
import CrowCore

/// `CodeBackend` implementation for GitLab. Wraps the `glab` CLI.
///
/// Capabilities: none in v1. The merge-label flow at IssueTracker.swift:2037 is
/// GitHub-specific today; once GitLab gets equivalent CI gating, declare `.autoMergeLabel`
/// and implement `ensureMergeLabel`.
///
/// See ADR 0005.
public struct GitLabCodeBackend: CodeBackend {
    public let provider: Provider = .gitlab
    public let capabilities: Set<CodeCapability> = []

    private let shellRunner: ShellRunner
    private let host: String?

    public init(shellRunner: ShellRunner, host: String?) {
        self.shellRunner = shellRunner
        self.host = host
    }

    public func linkedPR(repo: String, branch: String) async throws -> LinkedPR? {
        let env = self.env()
        // `glab mr list` returns plain-text by default; ask for JSON via API.
        // Pattern: list MRs whose source branch matches; pick first.
        let output = try await shellRunner.run(
            args: [
                "glab", "mr", "list",
                "--repo", repo,
                "--source-branch", branch,
                "--all",
                "-F", "json"
            ],
            env: env,
            cwd: NSHomeDirectory()
        )
        guard let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let iid = first["iid"] as? Int else {
            return nil
        }
        let webURL = (first["web_url"] as? String) ?? ""
        let state = (first["state"] as? String) ?? ""
        return LinkedPR(number: iid, url: webURL, state: state)
    }

    public func ensureMergeLabel(repo: String) async throws {
        // No `.autoMergeLabel` capability declared. Capability-gated callers
        // skip this; a direct call is a programming error.
        throw ProviderError.unimplemented("GitLabCodeBackend.ensureMergeLabel: no autoMergeLabel capability")
    }

    private func env() -> [String: String] {
        guard let host else { return [:] }
        return ["GITLAB_HOST": host]
    }
}
