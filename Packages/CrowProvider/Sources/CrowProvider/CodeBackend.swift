import Foundation
import CrowCore

/// VCS-side operations: pull requests, merge labels, branch lookups, stale-PR state.
///
/// `CodeBackend` is paired with a `TaskBackend` (see `TaskBackend.swift` and ADR 0005)
/// when a session produces code. The split exists because tasks and code are
/// independent dimensions — a Corveil task may have a GitHub PR; a non-coding
/// task has no `CodeBackend` at all.
///
/// Backends are obtained from `ProviderManager` rather than instantiated directly so
/// the factory can pin the `ShellRunner` and provider-specific host config once.
public protocol CodeBackend: Sendable {
    /// Which provider this backend serves.
    var provider: Provider { get }

    /// CLI binary name this backend shells to (e.g. "gh", "glab"). Used by
    /// prompt-builders that render copy-paste hints — see `AutoRespondPrompts`.
    var cliName: String { get }

    /// What this backend can do, beyond the protocol's required methods.
    /// Replaces `guard session.provider == .github` style guards in call sites.
    var capabilities: Set<CodeCapability> { get }

    /// Find an existing PR/MR on `branch` in `repo` ("org/repo" slug), if one exists.
    /// Returns the first matching PR (any state) or `nil` if none found / call fails.
    func linkedPR(repo: String, branch: String) async throws -> LinkedPR?

    /// Ensure the auto-merge label exists in `repo`.
    /// Capability-gated: only call when `capabilities.contains(.autoMergeLabel)`.
    /// Without the capability this is a no-op (intentional — different VCS hosts
    /// have different label-management semantics, and a missing capability means
    /// "this provider doesn't need the same setup step").
    func ensureMergeLabel(repo: String) async throws

    /// Fetch the viewer's monitored PRs and review requests in one logical
    /// operation. GitHub batches both into a single GraphQL call; GitLab issues
    /// two REST calls. Returned together because IssueTracker consumes them
    /// together — the GraphQL batching is the original motivation for the
    /// combined return shape (see ADR 0005's "Migration status" note).
    func listMonitoredPRs() async throws -> MonitoredPRListing

    /// Batched state fetch for a set of PRs. Backends with `.batchedPRStates`
    /// issue one call; others fall back to per-PR. Returned keyed by `PRRef`
    /// (not URL) so callers don't have to round-trip through the API's
    /// canonical URL form to look up their result.
    func prStates(refs: [PRRef]) async throws -> [PRRef: PRRecord]

    /// Fetch every commit on the PR identified by `prURL` and `repoSlug`.
    /// Returns the full commit list; the caller filters for the
    /// `Crow-Session:` trailer to identify Crow-authored commits.
    func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo]

    /// Fetch recent commits on the repo's default branch, newest first,
    /// committed at or after `since`. Used by revert detection (#694) to
    /// spot `This reverts commit <sha>` messages targeting session-attributed
    /// commits, including reverts pushed directly or merged by others. The
    /// default implementation returns `[]` (no scan); GitHub overrides it.
    func fetchRecentDefaultBranchCommits(repoSlug: String, since: Date) async throws -> [CommitInfo]

    /// Fetch the file paths changed by the PR `prNumber` in `repoSlug`.
    /// Used by post-merge-fix detection (#694) to compute file overlap
    /// between a merged PR and later attributed PRs. The default
    /// implementation returns `[]` (no file listing); GitHub overrides it.
    func fetchPRChangedFiles(repoSlug: String, prNumber: Int) async throws -> [String]

    /// For each `(repoSlug, branch)` candidate, fetch up to 5 recently-updated
    /// PRs whose head matches `branch`. Used by session reconcile to recover
    /// dropped PR links. Returns one match per (candidate, PR) — callers run
    /// `decideReconcileLinks` to pick the best PR per candidate.
    func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch]

    /// For each `(repoSlug, key)` candidate, search the repo for PRs that
    /// reference `key` (e.g. a Jira key `MAXX-6859`) in their title/body/branch
    /// and return the recent matches. Used by reconcile to link PRs for
    /// task-only trackers (Jira) whose PR branch doesn't match the session's
    /// worktree branch — branch matching can't find those. The default
    /// implementation returns `[]` (no key search); GitHub overrides it.
    func findPRsMatchingKeys(_ candidates: [KeyCandidate]) async throws -> [KeyPRMatch]

    /// Add the `crow:merge` auto-merge label to the PR at `prURL`.
    /// Capability-gated on `.autoMergeLabel`. Backends without the capability
    /// inherit the default no-op-throw in the protocol extension below.
    func addMergeLabel(prURL: String) async throws

    /// Enable auto-merge on the PR at `prURL` (squash + delete branch).
    /// Capability-gated on `.autoMerge`. Backends without the capability throw
    /// `ProviderError.unimplemented`.
    func enableAutoMerge(prURL: String) async throws

    /// Trigger a "Update branch" rebase/merge from the base branch on the PR
    /// at `prURL`. Capability-gated on `.updateBranch`. Backends without the
    /// capability throw `ProviderError.unimplemented`.
    func updateBranch(prURL: String) async throws

    /// Fetch the metadata SessionService needs to prep a review clone:
    /// title, head/base branch names, head commit SHA, number. Issues one
    /// `gh pr view` / `glab mr view` call.
    func fetchPRMetadata(prURL: String) async throws -> PRMetadata
}

public extension CodeBackend {
    /// Default: no key-based PR search. Backends that can search PRs by text
    /// (GitHub) override this; others (GitLab today, Corveil stub) inherit the
    /// no-op so a Jira-key reconcile pass degrades to "no matches" rather than
    /// forcing every conformer to implement it.
    func findPRsMatchingKeys(_ candidates: [KeyCandidate]) async throws -> [KeyPRMatch] { [] }

    /// Default: no default-branch commit scan. GitHub overrides this; others
    /// (GitLab today, Corveil stub) inherit the no-op so revert detection
    /// degrades to "no branch scan" rather than forcing every conformer to
    /// implement it.
    func fetchRecentDefaultBranchCommits(repoSlug: String, since: Date) async throws -> [CommitInfo] { [] }

    /// Default: no changed-file listing. GitHub overrides this; others inherit
    /// the no-op so post-merge-fix detection degrades to "no overlap data".
    func fetchPRChangedFiles(repoSlug: String, prNumber: Int) async throws -> [String] { [] }

    /// Default: backends without `.autoMergeLabel` can't add the merge label.
    /// GitHub overrides this; others inherit the throw so a capability-gated
    /// caller that slips through degrades to an error rather than a silent no-op.
    func addMergeLabel(prURL: String) async throws {
        throw ProviderError.unimplemented("addMergeLabel not supported by \(provider)")
    }
}

/// Optional capabilities a `CodeBackend` may declare.
public enum CodeCapability: Sendable, Hashable {
    /// Supports creating/updating an auto-merge label (`crow:merge`) on the repo.
    /// Gates `ensureMergeLabel`.
    case autoMergeLabel

    /// Can fetch states for multiple PRs in one batched call rather than per-PR.
    /// Informational today — used by `IssueTracker`'s stale-PR follow-up to log
    /// which path was taken. Maintained as a capability so a future GitLab REST
    /// API upgrade can flip this on without rewriting callers.
    case batchedPRStates

    /// Supports `gh pr merge --auto` (or equivalent). Gates `enableAutoMerge`.
    /// GitHub declares this; GitLab does not (the `glab` CLI doesn't expose an
    /// equivalent "merge when checks pass" toggle).
    case autoMerge

    /// Supports `gh pr update-branch` (or equivalent). Gates `updateBranch`.
    /// GitHub declares this; GitLab does not.
    case updateBranch
}

/// Minimal PR/MR identity returned from `CodeBackend.linkedPR`.
public struct LinkedPR: Sendable, Equatable {
    public let number: Int
    public let url: String
    /// PR state as reported by the host (e.g. "OPEN", "MERGED", "CLOSED" for GitHub;
    /// "opened", "merged", "closed" for GitLab). Callers normalize as needed.
    public let state: String

    public init(number: Int, url: String, state: String) {
        self.number = number
        self.url = url
        self.state = state
    }
}
