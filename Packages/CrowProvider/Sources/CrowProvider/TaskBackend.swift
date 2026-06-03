import Foundation
import CrowCore

/// Tracker-side operations: issues, tasks, labels, assignment, project status.
///
/// `TaskBackend` is paired with a `CodeBackend` (separate protocol — see ADR 0005)
/// when a session also produces a PR. A Corveil-tasked session that delegates its
/// PR work to GitHub will use a `StubCorveilTaskBackend` here and a `GitHubCodeBackend`
/// there. The split exists because tasks (the unit of work) and code (the VCS artifact)
/// are independent dimensions.
///
/// Backends are obtained from `ProviderManager` rather than instantiated directly so
/// the factory can pin the `ShellRunner` and GitLab host config once.
public protocol TaskBackend: Sendable {
    /// Which provider this backend serves.
    var provider: Provider { get }

    /// What this backend can do, beyond the protocol's required methods.
    /// Callers branch on capabilities to gate optional behavior (project boards,
    /// batched queries) instead of switching on `provider`.
    var capabilities: Set<TaskCapability> { get }

    /// Fetch a single task by URL (issue, not PR — that's `CodeBackend`).
    func fetchTask(url: String) async throws -> TicketInfo

    /// Add and/or remove labels on a task by URL.
    /// - Parameters:
    ///   - url: Task URL.
    ///   - add: Labels to add. Pass `[]` to skip.
    ///   - remove: Labels to remove. Pass `[]` to skip.
    func setLabels(url: String, add: [String], remove: [String]) async throws

    /// Set the project-board status for a task.
    /// Capability-gated: only call when `capabilities.contains(.projectBoardStatus)`.
    /// Calling without the capability throws `ProviderError.unimplemented`.
    func setTaskStatus(url: String, status: TicketStatus) async throws
}

/// Optional capabilities a `TaskBackend` may declare.
///
/// Replaces today's `guard session.provider == .github` style guards. The match
/// becomes `if taskBackend.capabilities.contains(.projectBoardStatus)`, so adding
/// a third provider (or extending an existing one) doesn't ripple through call sites.
public enum TaskCapability: Sendable, Hashable {
    /// Can set project-board status (GitHub Projects v2 today).
    /// Gates `setTaskStatus`. Without this capability that method throws.
    case projectBoardStatus

    /// Can fulfill `listAssigned`-style queries in a single batched call rather
    /// than per-item. Informational — callers don't branch on it today, but it
    /// signals to maintainers that the backend has a cheaper bulk path.
    case batchedQuery
}
