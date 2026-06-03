import Foundation
import CrowCore

/// `TaskBackend` implementation for GitHub. Wraps the `gh` CLI.
///
/// Capabilities declared:
/// - `.batchedQuery` — `listAssigned`-style fetches use one GraphQL call.
/// - `.projectBoardStatus` — GitHub Projects v2 is the UI surface this
///   capability gates. The `setTaskStatus` GraphQL migration is still
///   pending; the legacy `IssueTracker.markInReview` path (see
///   `IssueTracker.swift:2549`) executes the mutation today via the
///   `onMarkInReview` closure, so calling `setTaskStatus` on this backend
///   directly still throws `.unimplemented`. UI guards branch on this
///   capability instead of `provider == .github` (see ADR 0005); execution
///   falls through to the legacy path until the migration lands.
///
/// See ADR 0005 for the protocol contract and its Context section for why
/// task ops are separate from code ops.
public struct GitHubTaskBackend: TaskBackend {
    public let provider: Provider = .github
    public let capabilities: Set<TaskCapability> = [.batchedQuery, .projectBoardStatus]

    private let shellRunner: ShellRunner

    public init(shellRunner: ShellRunner) {
        self.shellRunner = shellRunner
    }

    // MARK: - TaskBackend

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        // fetchTask is issue-only by contract; if the URL is a PR the caller
        // should be using CodeBackend. Reject here rather than silently fetching
        // a PR — the asymmetry would invite latent bugs.
        if parsed.isMR {
            throw ProviderError.invalidURL("fetchTask received a pull request URL: \(url)")
        }
        let output = try await shellRunner.run("gh", "issue", "view", url, "--json", "title,body,labels")
        let title = Self.extractTitle(from: output) ?? "Ticket #\(parsed.number)"
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: .github,
            isMR: false
        )
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        var args: [String] = ["gh", "issue", "edit", url]
        for label in add {
            args.append("--add-label")
            args.append(label)
        }
        for label in remove {
            args.append("--remove-label")
            args.append(label)
        }
        _ = try await shellRunner.run(args: args, env: [:], cwd: nil)
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        // Real implementation requires the GraphQL project-item lookup + mutation
        // sequence currently inlined at IssueTracker.swift:2549. That migration is
        // deferred to a follow-up PR — see ADR 0005 references.
        // UI guards key off `.projectBoardStatus` (declared above); execution
        // currently routes through `IssueTracker.markInReview` via the
        // `onMarkInReview` closure rather than through this method, so the
        // throw is unreached on the live path until the migration lands.
        throw ProviderError.unimplemented(
            "GitHubTaskBackend.setTaskStatus: migration of markInReview project-board mutation pending"
        )
    }

    // MARK: - Helpers

    private static func extractTitle(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String {
            return title
        }
        return output.components(separatedBy: .newlines).first
    }
}
