import Foundation
import CrowCore

/// `TaskBackend` implementation for GitHub. Wraps the `gh` CLI.
///
/// Facade (CROW-1265): protocol methods, `capabilities`, `shellRunner`, and
/// the `gh` argv wrappers. GraphQL documents and `AssignedIssue` parsers live
/// in `GitHubTaskBackend+Parsing.swift` as `extension GitHubTaskBackend` so
/// `@testable` tests keep `GitHubTaskBackend.parseIssueNodes` etc.
///
/// `classifyGraphQLError` stays here (gh-stderr routing). `decodeGraphQLData`
/// / `parseRateLimit` live on this type via the parsing extension so
/// `GitHubCodeBackend+Parsing` keeps calling `GitHubTaskBackend.*` (CROW-1253).
///
/// Capabilities declared:
/// - `.batchedQuery` — `listAssigned` fetches open + closed issues in one
///   GraphQL call.
/// - `.projectBoardStatus` — GitHub Projects v2. After the #454 migration this
///   is a real implementation: `setTaskStatus` performs the project-item
///   lookup + `updateProjectV2ItemFieldValue` mutation. The legacy
///   `IssueTracker.markInReview` escape-hatch is gone.
///
/// See ADR 0005.
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

    public func listAssigned(includeClosed: Bool) async throws -> AssignedListing {
        let openQuery = "assignee:@me state:open type:issue"
        let closedQuery = "assignee:@me state:closed closed:>=\(Self.closedSinceString()) type:issue"

        // GitHub batches open + closed into one GraphQL call regardless of
        // `includeClosed` — there's no per-half network cost to save. When
        // `includeClosed` is false we drop the closedIssues from the parsed
        // result. The retry-without-projectItems path mirrors the same
        // shape so the missing-scope semantics stay consistent.
        do {
            let output = try await runIssuesQuery(
                query: Self.consolidatedIssuesQuery,
                openQuery: openQuery,
                closedQuery: closedQuery
            )
            let listing = try Self.parseIssuesResponse(output, missingScope: nil)
            return includeClosed ? listing : Self.stripClosed(listing)
        } catch ProviderError.insufficientScope(let scope) {
            do {
                let output = try await runIssuesQuery(
                    query: Self.consolidatedIssuesQueryNoProjects,
                    openQuery: openQuery,
                    closedQuery: closedQuery
                )
                let listing = try Self.parseIssuesResponse(output, missingScope: scope)
                return includeClosed ? listing : Self.stripClosed(listing)
            } catch ProviderError.samlRestricted(let blob) {
                // Rare: the no-projects retry also hit SAML. Recover what
                // resolved; the scope warning is sacrificed for this cycle.
                let listing = Self.recoverPartialIssues(fromSAMLBlob: blob)
                return includeClosed ? listing : Self.stripClosed(listing)
            }
        } catch ProviderError.samlRestricted(let blob) {
            // An org's SAML enforcement blocked the token. GitHub still
            // returned the accessible-org issues in `data`; recover them and
            // flag the listing degraded instead of failing the whole cycle.
            let listing = Self.recoverPartialIssues(fromSAMLBlob: blob)
            return includeClosed ? listing : Self.stripClosed(listing)
        }
    }

    private static func stripClosed(_ listing: AssignedListing) -> AssignedListing {
        AssignedListing(
            open: listing.open,
            closed: [],
            rateLimit: listing.rateLimit,
            missingScope: listing.missingScope,
            samlRestricted: listing.samlRestricted
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
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        // Step 1: look up the issue's project item, project, Status field, and
        // available options. Two-step because the option ID we need to set
        // lives on the field, not on the item.
        let queryOut: String
        do {
            queryOut = try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(Self.projectItemLookupQuery)",
                "-F", "owner=\(parsed.org)",
                "-F", "repo=\(parsed.repo)",
                "-F", "number=\(parsed.number)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw Self.classifyGraphQLError(output)
        }

        guard let resolved = Self.resolveProjectFieldOption(queryOut, target: status) else {
            if !Self.hasProjectItems(queryOut) {
                // No project board attached to the issue: represent pipeline
                // status with a `crow:in-progress` / `crow:in-review` fallback
                // label instead (#706, #790). The two are mutually exclusive —
                // the target status' label is applied and the other cleared.
                // Statuses with no label (notably Done, signaled by closing the
                // issue) just clear both.
                try await setFallbackStatusLabel(
                    url: url, repo: "\(parsed.org)/\(parsed.repo)", status: status
                )
                return
            }
            // On a project, but no matching option for the requested status.
            // Treat as unimplemented so callers can distinguish "feature
            // genuinely not available here" from "shell failed".
            throw ProviderError.unimplemented(
                "GitHubTaskBackend.setTaskStatus: issue has no '\(status.rawValue)' status option"
            )
        }

        do {
            _ = try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(Self.updateProjectV2ItemFieldValueMutation)",
                "-F", "projectId=\(resolved.projectID)",
                "-F", "itemId=\(resolved.itemID)",
                "-F", "fieldId=\(resolved.fieldID)",
                "-F", "optionId=\(resolved.optionID)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw Self.classifyGraphQLError(output)
        }
    }

    public func closeTask(url: String) async throws {
        guard ProviderManager.parseTicketURLComponents(url) != nil else {
            throw ProviderError.invalidURL(url)
        }
        // `gh issue close` is idempotent — closing an already-closed issue exits 0.
        do {
            _ = try await shellRunner.run("gh", "issue", "close", url)
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw ProviderError.commandFailed(output)
        }
    }

    public func assign(url: String, to login: String) async throws {
        _ = try await shellRunner.run(
            "gh", "issue", "edit", url, "--add-assignee", login
        )
    }

    public func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
        var args: [String] = [
            "gh", "issue", "create",
            "--repo", repo,
            "--title", title,
            "--body", body
        ]
        for label in labels {
            args.append("--label")
            args.append(label)
        }
        let output = try await shellRunner.run(args: args, env: [:], cwd: nil)
        // `gh issue create` prints the new issue URL on stdout. Pluck it.
        let url = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") } ?? ""
        guard !url.isEmpty,
              let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.commandFailed("gh issue create did not return a parseable URL; got: \(output)")
        }
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

    // MARK: - Helpers

    private func runIssuesQuery(query: String, openQuery: String, closedQuery: String) async throws -> String {
        do {
            return try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(query)",
                "-F", "openQuery=\(openQuery)",
                "-F", "closedQuery=\(closedQuery)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw Self.classifyGraphQLError(output)
        }
    }

    /// Classify a `gh api graphql` stderr blob into a typed error. Rate-limit
    /// and scope failures get their own cases so callers can route them to
    /// dedicated UI; everything else collapses to `.commandFailed`.
    static func classifyGraphQLError(_ stderr: String) -> ProviderError {
        // Check SAML first: GitHub returns partial `data` alongside the SAML
        // `errors` entry, so we carry the whole blob to recover accessible-org
        // results. A SAML blob won't also contain the rate-limit/scope tokens.
        if stderr.contains("Resource protected by organization SAML enforcement")
            || stderr.contains("protected by SAML") {
            return .samlRestricted(stderr)
        }
        if stderr.contains("RATE_LIMITED") || stderr.contains("API rate limit exceeded") {
            return .rateLimited(stderr)
        }
        if stderr.contains("INSUFFICIENT_SCOPES") || stderr.contains("read:project") {
            return .insufficientScope("read:project")
        }
        return .commandFailed(stderr)
    }

    /// Apply the fallback status label for `status` — and clear the other one —
    /// on an issue that has no project board (#706, #790).
    ///
    /// The add and each removal go out as separate `gh issue edit` calls on
    /// purpose: `--remove-label` fails the whole invocation when the label
    /// doesn't exist in the repo, which would take the add down with it.
    private func setFallbackStatusLabel(url: String, repo: String, status: TicketStatus) async throws {
        let target = status.fallbackStatusLabel
        if let target {
            try await ensureFallbackLabel(target, repo: repo)
            try await setLabels(url: url, add: [target], remove: [])
        }
        for stale in TicketStatus.fallbackStatusLabels where stale != target {
            do {
                try await setLabels(url: url, add: [], remove: [stale])
            } catch ShellRunnerError.nonZeroExit(_, let output)
                where output.localizedCaseInsensitiveContains("not found") {
                // Label doesn't exist in the repo (never reached that status
                // here); removal is best-effort.
            }
        }
    }

    /// Ensure a `crow:` fallback status label exists in `repo`, mirroring
    /// `GitHubCodeBackend.ensureMergeLabel`.
    private func ensureFallbackLabel(_ label: String, repo: String) async throws {
        let isInReview = label == TicketStatus.inReviewFallbackLabel
        do {
            _ = try await shellRunner.run(
                "gh", "label", "create", label,
                "--repo", repo,
                "--color", isInReview ? "FBCA04" : "1D76DB",
                "--description", isInReview
                    ? "Crow: in review (no-project status fallback)"
                    : "Crow: in progress (no-project status fallback)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) where output.localizedCaseInsensitiveContains("already exists") {
            return
        }
    }

    private static func extractTitle(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String {
            return title
        }
        return output.components(separatedBy: .newlines).first
    }

    /// GraphQL `search` only accepts date-only for `closed:>=`. Use yesterday
    /// (UTC) so closed-issue diffing has a 24h trailing window.
    private static func closedSinceString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date().addingTimeInterval(-86400))
    }
}
