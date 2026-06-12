import Foundation
import CrowCore

/// Tracker-side operations: issues, tasks, labels, assignment, project status.
///
/// `TaskBackend` is paired with a `CodeBackend` (separate protocol — see ADR 0005)
/// when a session also produces a PR. A Corveil-tasked session that delegates its
/// PR work to GitHub will use a `CorveilTaskBackend` here and a `GitHubCodeBackend`
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

    /// Open + recently-closed issues assigned to the authenticated user.
    /// Returning both halves in one call lets callers diff the new closed set
    /// against the prior open set to flush issues that fell off the user's
    /// queue.
    /// - Parameter includeClosed: When false, the backend skips the closed
    ///   half. GitHub still issues one batched GraphQL call either way; GitLab
    ///   avoids a second REST round-trip. The returned `AssignedListing.closed`
    ///   is empty when false.
    func listAssigned(includeClosed: Bool) async throws -> AssignedListing

    /// Add and/or remove labels on a task by URL.
    /// - Parameters:
    ///   - url: Task URL.
    ///   - add: Labels to add. Pass `[]` to skip.
    ///   - remove: Labels to remove. Pass `[]` to skip.
    func setLabels(url: String, add: [String], remove: [String]) async throws

    /// Set the project-board status for a task.
    /// Capability-gated on `.projectBoardStatus`. Backends without the
    /// capability throw `ProviderError.unimplemented`. With the foundation +
    /// migration of ADR 0005 in place, GitHub now actually runs the GraphQL
    /// mutation here — no more legacy escape-hatch through IssueTracker.
    func setTaskStatus(url: String, status: TicketStatus) async throws

    /// Assign an issue to `login` (e.g. `@me` for the authenticated user).
    /// Used by session setup to claim a ticket and by skill flows.
    func assign(url: String, to login: String) async throws

    /// Create a new task in `repo` ("org/repo" slug). Returns the created
    /// ticket's identity (number, URL, etc.) so callers can link the new
    /// session to the new ticket immediately.
    func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo
}

extension TaskBackend {
    /// Convenience: fetch both open and recently-closed assigned issues.
    /// Equivalent to `listAssigned(includeClosed: true)`.
    public func listAssigned() async throws -> AssignedListing {
        try await listAssigned(includeClosed: true)
    }
}

/// Optional capabilities a `TaskBackend` may declare.
///
/// Replaces today's `guard session.provider == .github` style guards. The match
/// becomes `if taskBackend.capabilities.contains(.projectBoardStatus)`, so adding
/// a third provider (or extending an existing one) doesn't ripple through call sites.
public enum TaskCapability: Sendable, Hashable {
    /// Declares that the provider exposes a project-board status concept the
    /// UI should surface (GitHub Projects v2 today). Gates UI affordances such
    /// as the "Mark as In Review" button **and** guarantees that
    /// `setTaskStatus` actually performs the mutation (no longer a UI-only
    /// declaration — the legacy escape-hatch through IssueTracker.markInReview
    /// was closed in the #454 migration; see ADR 0005).
    case projectBoardStatus

    /// Can fulfill `listAssigned`-style queries in a single batched call rather
    /// than per-item. Informational — callers don't branch on it today, but it
    /// signals to maintainers that the backend has a cheaper bulk path.
    case batchedQuery
}
