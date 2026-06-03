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
