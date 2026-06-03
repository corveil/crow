import Foundation
import CrowCore

/// `TaskBackend` implementation for GitLab. Wraps the `glab` CLI.
///
/// Capabilities: none in v1 — GitLab issue boards aren't surfaced through Crow yet,
/// and `glab` doesn't batch issue queries the same way `gh` does.
///
/// See ADR 0005.
public struct GitLabTaskBackend: TaskBackend {
    public let provider: Provider = .gitlab
    public let capabilities: Set<TaskCapability> = []

    private let shellRunner: ShellRunner
    private let host: String?

    public init(shellRunner: ShellRunner, host: String?) {
        self.shellRunner = shellRunner
        self.host = host
    }

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        if parsed.isMR {
            throw ProviderError.invalidURL("fetchTask received a merge request URL: \(url)")
        }
        let env = self.env()
        let repoSlug = "\(parsed.org)/\(parsed.repo)"
        let output = try await shellRunner.run(
            args: ["glab", "issue", "view", "\(parsed.number)", "--repo", repoSlug],
            env: env,
            cwd: NSHomeDirectory()
        )
        let title = output.components(separatedBy: .newlines).first ?? "Ticket #\(parsed.number)"
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: .gitlab,
            isMR: false
        )
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        let repoSlug = "\(parsed.org)/\(parsed.repo)"
        let env = self.env()
        var args: [String] = ["glab", "issue", "update", "\(parsed.number)", "--repo", repoSlug]
        if !add.isEmpty {
            args.append("--label")
            args.append(add.joined(separator: ","))
        }
        if !remove.isEmpty {
            args.append("--unlabel")
            args.append(remove.joined(separator: ","))
        }
        _ = try await shellRunner.run(args: args, env: env, cwd: NSHomeDirectory())
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        // No project board support declared. Capability-gated callers won't hit this;
        // anything that does is a programming error.
        throw ProviderError.unimplemented("GitLabTaskBackend.setTaskStatus: no projectBoardStatus capability")
    }

    private func env() -> [String: String] {
        guard let host else { return [:] }
        return ["GITLAB_HOST": host]
    }
}
