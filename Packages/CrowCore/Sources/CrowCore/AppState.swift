import Foundation

/// Check whether a repo name matches any of the exclude patterns.
/// Supports exact matches and simple glob patterns with `*` (e.g., `org/*`, `*/repo`).
public func repoMatchesExcludePatterns(_ repo: String, patterns: [String]) -> Bool {
    let lowerRepo = repo.lowercased()
    for pattern in patterns {
        let lowerPattern = pattern.lowercased()
        if lowerPattern.contains("*") {
            let parts = lowerPattern.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
            let prefix = String(parts[0])
            let suffix = parts.count > 1 ? String(parts[1]) : ""
            if lowerRepo.hasPrefix(prefix) && lowerRepo.hasSuffix(suffix) {
                return true
            }
        } else if lowerRepo == lowerPattern {
            return true
        }
    }
    return false
}

/// Observable application state shared across the app.
@MainActor
@Observable
public final class AppState {
    public var sessions: [Session] = []
    public var selectedSessionID: UUID?

    /// Whether notification sounds are muted (toggled via sidebar speaker icon).
    public var soundMuted: Bool = false

    /// Whether subtitle rows (ticket title, repo/branch) are hidden in sidebar session rows.
    public var hideSessionDetails: Bool = false

    /// Whether new Claude Code sessions are launched with `--rc` so they can be
    /// controlled from claude.ai / the Claude mobile app. Mirrors `AppConfig.remoteControlEnabled`.
    public var remoteControlEnabled: Bool = false

    /// Whether the Manager terminal launches with `--permission-mode auto` so it
    /// can run `crow`, `gh`, and `git` commands without per-call approval.
    /// Mirrors `AppConfig.managerAutoPermissionMode`. Applies only to the Manager
    /// launch; worker sessions and CLI-spawned terminals are unaffected.
    public var managerAutoPermissionMode: Bool = true

    /// Terminal IDs whose Claude Code was launched with `--rc` — drives the
    /// per-session indicator badge. Survives toggle changes so existing sessions
    /// keep showing the badge until they're restarted.
    public var remoteControlActiveTerminals: Set<UUID> = []

    /// Worktrees keyed by session ID.
    public var worktrees: [UUID: [SessionWorktree]] = [:]

    /// Links keyed by session ID.
    public var links: [UUID: [SessionLink]] = [:]

    /// Terminals keyed by session ID.
    public var terminals: [UUID: [SessionTerminal]] = [:]

    /// Active terminal tab per session.
    public var activeTerminalID: [UUID: UUID] = [:]

    // MARK: - Manager Session

    /// Fixed UUID for the always-present manager session.
    nonisolated public static let managerSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Fixed UUID for the ticket board tab.
    nonisolated public static let ticketBoardSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Fixed UUID for the allow list tab.
    nonisolated public static let allowListSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Fixed UUID for the review board tab.
    nonisolated public static let reviewBoardSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    /// Fixed UUID for the global terminals page.
    nonisolated public static let globalTerminalSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    public var managerSession: Session? {
        sessions.first { $0.id == Self.managerSessionID }
    }

    // MARK: - Issue Tracking

    /// Issues assigned to the current user across all workspaces.
    public var assignedIssues: [AssignedIssue] = []
    public var isLoadingIssues: Bool = false

    /// Number of issues completed (closed) in the last 24 hours.
    public var doneIssuesLast24h: Int = 0

    /// Currently selected pipeline filter on the ticket board (nil = show all).
    public var selectedTicketStatus: TicketStatus? = .inProgress

    /// Text search for ticket board filtering.
    public var ticketSearchText: String = ""

    /// Sort order for the ticket board.
    public var ticketSortOrder: TicketSortOrder = .updatedDesc

    // MARK: - Allow List

    /// Aggregated allow-list entries from all worktrees.
    public var allowEntries: [AllowEntry] = []
    public var isLoadingAllowList: Bool = false

    /// Called to scan and aggregate allow-list entries.
    public var onLoadAllowList: (() -> Void)?

    /// Called to promote selected patterns to the global settings.
    public var onPromoteToGlobal: ((Set<String>) -> Void)?

    /// Called when the user clicks the gear icon in the sidebar toolbar.
    /// AppDelegate wires this to its `showSettings()` method.
    public var onShowSettings: (() -> Void)?

    // MARK: - PR & Tool Status

    /// PR status per session (pipeline, review, merge readiness).
    /// Must be cleaned up when a session is deleted (see `SessionService.deleteSession`).
    public var prStatus: [UUID: PRStatus] = [:]

    // MARK: - Review Requests

    /// PRs where the current user has been requested as a reviewer.
    public var reviewRequests: [ReviewRequest] = []
    public var isLoadingReviews: Bool = false

    public var excludeReviewRepos: [String] = []
    public var excludeTicketRepos: [String] = []
    public var ignoreReviewLabels: [String] = []

    public var filteredReviewRequests: [ReviewRequest] {
        var result = reviewRequests
        if !excludeReviewRepos.isEmpty {
            result = result.filter { !repoMatchesExcludePatterns($0.repo, patterns: excludeReviewRepos) }
        }
        if !ignoreReviewLabels.isEmpty {
            let lowerLabels = Set(ignoreReviewLabels.map { $0.lowercased() })
            result = result.filter { request in
                !request.labels.contains(where: { lowerLabels.contains($0.lowercased()) })
            }
        }
        return result
    }

    /// IDs of review requests the user has already seen (for badge count).
    public var seenReviewRequestIDs: Set<String> = []

    /// Number of unseen review requests (for sidebar badge).
    public var unseenReviewCount: Int {
        filteredReviewRequests.filter { !seenReviewRequestIDs.contains($0.id) }.count
    }

    /// Whether the VS Code `code` CLI is available on this system.
    public var vsCodeAvailable: Bool = false

    /// Runtime dependencies that were not found at startup (e.g., "gh", "git", "claude").
    public var missingDependencies: [String] = []

    /// Non-fatal GitHub auth warning surfaced in Settings. `nil` means no warning.
    /// Set by `IssueTracker` when the token lacks a required scope; cleared on next success.
    public var githubScopeWarning: String?

    /// Last observed GitHub GraphQL rate-limit snapshot. `nil` before the first
    /// successful query. Populated from the `rateLimit` block on each refresh.
    public var githubRateLimit: GitHubRateLimit?

    /// Non-fatal rate-limit warning surfaced in Settings. `nil` when not throttled.
    /// Set by `IssueTracker` when polling is suspended; cleared on next success.
    public var rateLimitWarning: String?

    /// Terminal readiness state per terminal ID.
    public var terminalReadiness: [UUID: TerminalReadiness] = [:]

    /// Terminal IDs eligible for auto-launch of `claude --continue`.
    /// Only restored (hydrated) and recovered orphan terminals are added here,
    /// not brand-new terminals created via the `new-terminal` RPC.
    public var autoLaunchTerminals: Set<UUID> = []

    // MARK: - Hook Events (per-session Observable wrappers)

    /// Per-session hook state. Using @Observable class wrappers so mutations to one
    /// session's state only invalidate views reading THAT session — not all sessions.
    /// (Plain dictionaries with @Observable cause ALL readers to re-render on any key change.)
    private var _sessionState: [UUID: SessionHookState] = [:]

    /// Get or create the hook state for a session. Views should hold the returned reference
    /// to benefit from scoped observation.
    public func hookState(for sessionID: UUID) -> SessionHookState {
        if let existing = _sessionState[sessionID] { return existing }
        let new = SessionHookState()
        _sessionState[sessionID] = new
        return new
    }

    /// Remove hook state for a deleted session.
    public func removeHookState(for sessionID: UUID) {
        _sessionState.removeValue(forKey: sessionID)
    }

    /// Called when user clicks "Work on" for an assigned issue.
    public var onWorkOnIssue: ((String) -> Void)?  // receives issue URL

    /// Called when user clicks "Start Working" for multiple selected issues (batch mode).
    public var onBatchWorkOnIssues: (([String]) -> Void)?  // receives array of issue URLs

    /// Called when user clicks "Start Review" for a PR review request.
    public var onStartReview: ((String) -> Void)?  // receives PR URL

    /// Called when user clicks "Start Review" for multiple selected PR review requests (batch mode).
    public var onBatchStartReview: (([String]) -> Void)?  // receives array of PR URLs

    /// Called to launch Claude in a terminal that just became ready.
    public var onLaunchClaude: ((UUID) -> Void)?  // receives terminal ID

    /// Called when the user clicks "Retry" on a failed terminal surface.
    public var onRetryTerminal: ((UUID) -> Void)?  // receives terminal ID

    /// Called when the user clicks "Retry" on a terminal whose tmux readiness
    /// watch timed out before the shell signaled it was interactive.
    public var onRetryReadiness: ((UUID) -> Void)?  // receives terminal ID

    /// Called to add a new plain-shell terminal tab to a session.
    public var onAddTerminal: ((UUID) -> Void)?  // receives session ID

    /// Called to close a non-managed terminal tab.
    public var onCloseTerminal: ((UUID, UUID) -> Void)?  // receives (sessionID, terminalID)

    /// Called to rename a terminal tab.
    public var onRenameTerminal: ((UUID, UUID, String) -> Void)?  // receives (sessionID, terminalID, newName)

    /// Called to add a new global terminal tab.
    public var onAddGlobalTerminal: (() -> Void)?

    /// Called to close a global terminal tab.
    public var onCloseGlobalTerminal: ((UUID) -> Void)?  // receives terminalID

    // MARK: - Closures wired by AppDelegate

    /// Called to delete a session and clean up its worktrees.
    public var onDeleteSession: ((UUID) async throws -> Void)?

    /// Called to mark a session as completed.
    public var onCompleteSession: ((UUID) -> Void)?

    /// Called to mark a session's ticket as "In Review" on the GitHub Project board.
    public var onMarkInReview: ((UUID) -> Void)?

    /// Called to update session status to .inReview (persists to store).
    public var onSetSessionInReview: ((UUID) -> Void)?

    /// Called to update session status back to .active (persists to store).
    public var onSetSessionActive: ((UUID) -> Void)?

    /// Whether a given session is currently being marked as "In Review" (loading state).
    /// Must be cleaned up when a session is deleted (see `SessionService.deleteSession`).
    public var isMarkingInReview: [UUID: Bool] = [:]

    /// Sessions whose async deletion (worktree teardown, branch removal, persistence)
    /// is currently in progress. Set on the main actor at the start of
    /// `SessionService.deleteSession` and cleared when the session is fully removed.
    public var isDeletingSession: [UUID: Bool] = [:]

    /// Most recent delete-cleanup error for a session, surfaced inline on the row
    /// so failures aren't silent. Auto-cleared after a short delay or on retry.
    public var sessionDeletionError: [UUID: String] = [:]

    /// Called to open a session's primary worktree in VS Code.
    public var onOpenInVSCode: ((UUID) -> Void)?

    /// Called to open a terminal at a session's primary worktree path.
    public var onOpenTerminal: ((UUID) -> Void)?

    /// Called when the user clicks a quick action button on a session card
    /// (e.g. "Merge PR", "Rebase & Fix Conflicts"). Receives the session ID
    /// and the action chosen; the wired handler injects the corresponding
    /// prompt into the session's managed Claude Code terminal.
    public var onQuickAction: ((UUID, QuickAction) -> Void)?

    /// Called when the sound mute toggle is changed.
    public var onSoundMutedChanged: ((Bool) -> Void)?

    // MARK: - Computed Properties

    public var selectedSession: Session? {
        guard selectedSessionID != Self.ticketBoardSessionID,
              selectedSessionID != Self.allowListSessionID,
              selectedSessionID != Self.reviewBoardSessionID,
              selectedSessionID != Self.globalTerminalSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var activeSessions: [Session] {
        sessions.filter { $0.status == .active && $0.id != Self.managerSessionID && $0.kind == .work }
    }

    public var inReviewSessions: [Session] {
        sessions.filter { $0.status == .inReview && $0.id != Self.managerSessionID }
    }

    public var completedSessions: [Session] {
        sessions.filter { $0.status == .completed || $0.status == .archived }
    }

    public var reviewSessions: [Session] {
        sessions.filter { $0.kind == .review && $0.status != .completed && $0.status != .archived }
    }

    public func worktrees(for sessionID: UUID) -> [SessionWorktree] {
        worktrees[sessionID] ?? []
    }

    public func links(for sessionID: UUID) -> [SessionLink] {
        links[sessionID] ?? []
    }

    public func terminals(for sessionID: UUID) -> [SessionTerminal] {
        terminals[sessionID] ?? []
    }

    /// Whether a session has a managed Claude Code terminal that quick
    /// actions can be dispatched into. The dispatcher in AppDelegate
    /// re-checks the surface state before sending; this is the lighter
    /// gate the view uses to decide whether to enable the buttons.
    public func canDispatchQuickAction(sessionID: UUID) -> Bool {
        terminals(for: sessionID).contains(where: { $0.isManaged })
    }

    public func primaryWorktree(for sessionID: UUID) -> SessionWorktree? {
        worktrees[sessionID]?.first(where: { $0.isPrimary }) ?? worktrees[sessionID]?.first
    }

    // MARK: - Ticket Board Helpers

    /// Issues after applying repo exclusion filter.
    public var filteredAssignedIssues: [AssignedIssue] {
        guard !excludeTicketRepos.isEmpty else { return assignedIssues }
        return assignedIssues.filter { !repoMatchesExcludePatterns($0.repo, patterns: excludeTicketRepos) }
    }

    /// Count of issues in a given pipeline status. Treats `.unknown` as `.backlog`.
    public func issueCount(for status: TicketStatus) -> Int {
        filteredAssignedIssues.filter { effectiveStatus($0) == status }.count
    }

    /// Issues filtered by the given pipeline status. Treats `.unknown` as `.backlog`.
    public func issues(for status: TicketStatus) -> [AssignedIssue] {
        filteredAssignedIssues.filter { effectiveStatus($0) == status }
    }

    /// Filtered and sorted issues for the ticket board, applying status filter, search, and sort.
    public var filteredSortedIssues: [AssignedIssue] {
        var result = filteredAssignedIssues

        // Status filter
        if let status = selectedTicketStatus {
            result = result.filter { effectiveStatus($0) == status }
        }

        // Text search
        if !ticketSearchText.isEmpty {
            let query = ticketSearchText.lowercased()
            result = result.filter { issue in
                issue.title.lowercased().contains(query)
                || issue.repo.lowercased().contains(query)
                || "#\(issue.number)".contains(query)
                || issue.labels.contains(where: { $0.lowercased().contains(query) })
            }
        }

        // Sort
        result.sort { a, b in
            switch ticketSortOrder {
            case .updatedDesc:
                return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
            case .updatedAsc:
                return (a.updatedAt ?? .distantPast) < (b.updatedAt ?? .distantPast)
            case .titleAsc:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .titleDesc:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedDescending
            case .numberDesc:
                return a.number > b.number
            case .numberAsc:
                return a.number < b.number
            }
        }

        return result
    }

    /// Find the active session linked to a given issue (by matching ticket URL).
    public func activeSession(for issue: AssignedIssue) -> Session? {
        activeSessions.first { $0.ticketURL == issue.url }
    }

    /// Maps `.unknown` project status to `.backlog` for display purposes.
    private func effectiveStatus(_ issue: AssignedIssue) -> TicketStatus {
        issue.projectStatus == .unknown ? .backlog : issue.projectStatus
    }

    public init() {}
}

// MARK: - GitHub Rate Limit

/// Snapshot of the GitHub GraphQL rate-limit state observed from the `rateLimit`
/// block on the last successful query.
public struct GitHubRateLimit: Equatable, Sendable {
    public let remaining: Int
    public let limit: Int
    public let resetAt: Date
    public let cost: Int
    public let observedAt: Date

    public init(remaining: Int, limit: Int, resetAt: Date, cost: Int, observedAt: Date) {
        self.remaining = remaining
        self.limit = limit
        self.resetAt = resetAt
        self.cost = cost
        self.observedAt = observedAt
    }
}

// MARK: - Per-Session Hook State

/// Observable wrapper for per-session hook/Claude state.
/// Using a reference-type @Observable class ensures that mutations to one session's
/// state only invalidate views observing THAT session's instance — not all sessions.
@MainActor
@Observable
public final class SessionHookState {
    public var claudeState: ClaudeState = .idle
    public var pendingNotification: HookNotification?
    public var lastToolActivity: ToolActivity?
    public var hookEvents: [HookEvent] = []
    public var analytics: SessionAnalytics?
    /// Timestamp of the most recent top-level Stop / StopFailure for this session.
    /// Used to suppress state elevation from background activity (e.g. the
    /// `awaySummaryEnabled` recap subagent in Claude Code ≥ 2.1.108) that
    /// fires after the user's turn has ended. Cleared on the next
    /// UserPromptSubmit, which marks the start of a new real turn.
    public var lastTopLevelStopAt: Date?

    public init() {}
}
