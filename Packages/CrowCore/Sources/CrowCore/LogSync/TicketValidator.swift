import Foundation

/// Confirms a reconstructed ticket actually exists on the provider before Crow
/// asserts a link for it (CROW-1075, decision #3). Backfill reconstructs a
/// `(repo, number)` from a worktree name; that number might be a real issue, a
/// real PR, or nothing (a typo, a since-deleted ticket, a number that was never
/// a ticket at all). Uploading a fabricated REFERENCE would put a false edge
/// into a permanent, org-readable graph, so the uploader only stamps a ticket
/// hint into the sidecar when this validator reports `.issue` or `.pullRequest`.
///
/// One `gh api repos/{owner}/{repo}/issues/{n}` (or `glab`) call answers both
/// "does it exist" and "issue vs PR" — GitHub's issues endpoint returns PRs too,
/// distinguished by a `pull_request` member. Results are cached per
/// `host/owner/repo#n` so a scan/upload of many sessions in one repo pays once.
public actor TicketValidator {
    private let runner: any ShellRunner
    private var cache: [String: BackfillTicketKind] = [:]

    public init(runner: any ShellRunner = ProcessShellRunner()) {
        self.runner = runner
    }

    /// Validate `(remote, number)`. Returns `.issue`/`.pullRequest` when the
    /// provider confirms it, `.notFound` on a clean 404, and `.unvalidated` when
    /// the check couldn't run (no CLI, auth failure, network) — the caller treats
    /// everything but the first two as "assert no link".
    public func validate(remote: RepoRemote, number: Int) async -> BackfillTicketKind {
        let key = "\(remote.host)/\(remote.owner)/\(remote.repo)#\(number)"
        if let cached = cache[key] { return cached }
        let kind = remote.isGitHub
            ? await validateGitHub(remote: remote, number: number)
            : await validateGitLab(remote: remote, number: number)
        cache[key] = kind
        return kind
    }

    // MARK: - GitHub

    private func validateGitHub(remote: RepoRemote, number: Int) async -> BackfillTicketKind {
        var args = ["gh", "api"]
        if remote.host != "github.com" { args += ["--hostname", remote.host] }
        args.append("repos/\(remote.owner)/\(remote.repo)/issues/\(number)")
        do {
            let out = try await runner.run(args: args, env: [:], cwd: nil)
            return Self.classifyGitHub(json: out)
        } catch let ShellRunnerError.nonZeroExit(_, output) {
            // A 404 is a definitive "does not exist"; any other failure (auth,
            // rate limit, offline) is inconclusive, so don't claim not-found.
            return output.contains("Not Found") || output.contains("HTTP 404")
                ? .notFound : .unvalidated
        } catch {
            return .unvalidated
        }
    }

    /// Classify a GitHub issues-endpoint JSON body: a `pull_request` member marks
    /// it a PR, otherwise it's an issue. A body missing a `number` isn't a valid
    /// ticket payload → inconclusive.
    static func classifyGitHub(json: String) -> BackfillTicketKind {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unvalidated }
        guard obj["number"] != nil else { return .unvalidated }
        return obj["pull_request"] != nil ? .pullRequest : .issue
    }

    // MARK: - GitLab

    private func validateGitLab(remote: RepoRemote, number: Int) async -> BackfillTicketKind {
        let project = "\(remote.owner)/\(remote.repo)"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(remote.owner)/\(remote.repo)"
        // GitLab keeps issues and MRs in separate namespaces sharing an `iid`
        // space, so try an issue first, then a merge request.
        if await gitlabExists(host: remote.host, path: "projects/\(project)/issues/\(number)") {
            return .issue
        }
        if await gitlabExists(host: remote.host, path: "projects/\(project)/merge_requests/\(number)") {
            return .pullRequest
        }
        return .unvalidated
    }

    private func gitlabExists(host: String, path: String) async -> Bool {
        var args = ["glab", "api"]
        if host != "gitlab.com" { args += ["--hostname", host] }
        args.append(path)
        do {
            let out = try await runner.run(args: args, env: [:], cwd: nil)
            guard let data = out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return obj["iid"] != nil || obj["id"] != nil
        } catch {
            return false
        }
    }
}
