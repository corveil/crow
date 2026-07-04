import Foundation
// `@Observable` is re-exported by Foundation on Apple platforms, but on Linux
// the Observation module must be imported explicitly for the macro to resolve.
// Importing it unconditionally is harmless on macOS and unblocks the headless
// `crowd` daemon reusing `AppState` on Linux (CROW-581).
import Observation

/// Check whether a repo name matches any of the given patterns.
/// Supports exact matches and simple glob patterns with `*` (e.g., `org/*`, `*/repo`).
public func repoMatchesPatterns(_ repo: String, patterns: [String]) -> Bool {
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

    /// Whether sessions launched by the Jobs scheduler start with
    /// `--permission-mode auto` so the job's prompts can run `crow`, `gh`, and
    /// `git` without per-call approval. Mirrors `AppConfig.jobsAutoPermissionMode`.
    /// Applies only to `.job`-kind sessions; manager/review/CLI sessions are unaffected.
    public var jobsAutoPermissionMode: Bool = true

    /// Whether newly launched work coder views start with
    /// `--permission-mode auto` (auto-accept) instead of plan mode. Mirrors
    /// `AppConfig.coderViewAutoPermissionMode`. Applies only to `.work`-kind
    /// sessions; manager/review/job sessions are unaffected (#586).
    public var coderViewAutoPermissionMode: Bool = false

    /// `true` when the Manager's `claude` process has exited (crash, kill, OOM)
    /// and has not yet been restarted. Drives the "Manager process exited" banner
    /// and enables the "Restart Manager" action. Reset when the Manager relaunches.
    public var managerProcessExited: Bool = false

    /// The agent seeded into new sessions when the caller doesn't pick one.
    /// Mirrors `AppConfig.defaultAgentKind` so creation flows can read the
    /// current default without a config round-trip.
    public var defaultAgentKind: AgentKind = .claudeCode

    /// Per-action agent overrides keyed by `SessionKind.rawValue`. Mirrors
    /// `AppConfig.agentsByKind`. Empty means every kind falls back to
    /// `defaultAgentKind` (CROW-421).
    public var agentsByKind: [String: AgentKind] = [:]

    /// Resolve the agent that should drive a newly-created session of the
    /// given kind. Prefers an `agentsByKind` override and falls back to
    /// `defaultAgentKind` when no override is set (CROW-421, CROW-433).
    public func agentKind(for sessionKind: SessionKind) -> AgentKind {
        return agentsByKind[sessionKind.rawValue] ?? defaultAgentKind
    }

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

    /// Legacy fixed UUID for the removed standalone-terminals page. Retained
    /// only so persisted terminal rows from that feature can be identified and
    /// purged on load (multiple Manager sessions replaced standalone terminals).
    nonisolated public static let globalTerminalSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    /// The primary (back-compat) Manager session identified by the well-known UUID.
    public var managerSession: Session? {
        sessions.first { $0.id == Self.managerSessionID }
    }

    /// All Manager-kind sessions (primary + any additional ones).
    public var managerSessions: [Session] {
        sessions.filter { $0.isManager }
    }

    /// Whether the session with the given id is a Manager. When the session row
    /// isn't loaded yet (e.g. during terminal creation before it's inserted) the
    /// fallback only recognizes the well-known *primary* UUID — a not-yet-loaded
    /// non-primary manager id returns `false`, so callers must not rely on this
    /// for non-primary managers pre-load.
    public func isManagerSession(_ id: UUID) -> Bool {
        if let session = sessions.first(where: { $0.id == id }) { return session.isManager }
        return id == Self.managerSessionID
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

    // MARK: - Allowlist

    /// Aggregated allow-list entries from all worktrees.
    public var allowEntries: [AllowEntry] = []
    public var isLoadingAllowList: Bool = false

    /// Called to scan and aggregate allow-list entries.
    public var onLoadAllowList: (() -> Void)?

    /// Called to promote selected patterns to the global settings.
    public var onPromoteToGlobal: ((Set<String>) -> Void)?

    /// Lists the repos available to a workspace, as `owner/repo` slugs, by
    /// expanding its `alwaysInclude` specs against the provider — along with any
    /// specs that couldn't be resolved. Wired in AppDelegate; used by the Jobs
    /// form's repo picker.
    public var onListWorkspaceRepos: ((WorkspaceInfo) async -> WorkspaceRepoListing)?

    /// Called when the user clicks the gear icon in the sidebar toolbar.
    /// AppDelegate wires this to its `showSettings()` method.
    public var onShowSettings: (() -> Void)?

    /// Called when the user requests a manual refresh (toolbar button or ⌘R).
    /// AppDelegate wires this to `IssueTracker.refresh()`, which re-fetches
    /// issues, review requests, PR status, and runs auto-create/auto-complete.
    public var onManualRefresh: (() -> Void)?

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
            result = result.filter { !repoMatchesPatterns($0.repo, patterns: excludeReviewRepos) }
        }
        if !ignoreReviewLabels.isEmpty {
            let lowerLabels = Set(ignoreReviewLabels.map { $0.lowercased() })
            result = result.filter { request in
                !request.labels.contains(where: { lowerLabels.contains($0.name.lowercased()) })
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

    /// Non-fatal GitHub SAML warning surfaced in Settings. `nil` means no warning.
    /// Set by `IssueTracker` when an org's SAML enforcement blocks the OAuth
    /// token (accessible-org tickets still load); cleared on the next poll with
    /// no SAML restriction.
    public var githubSAMLWarning: String?

    /// Last observed GitHub GraphQL rate-limit snapshot. `nil` before the first
    /// successful query. Populated from the `rateLimit` block on each refresh.
    public var githubRateLimit: GitHubRateLimit?

    /// Non-fatal rate-limit warning surfaced in Settings. `nil` when not throttled.
    /// Set by `IssueTracker` when polling is suspended; cleared on next success.
    public var rateLimitWarning: String?

    /// Non-fatal warning surfaced in Settings when the per-launch
    /// `corveil skill install` run fails (CROW-482). `nil` means the install
    /// either succeeded or wasn't attempted (no path configured). Set by
    /// `AppDelegate.launchMainApp` from the `Scaffolder` result.
    public var corveilSkillInstallWarning: String?

    /// Terminal readiness state per terminal ID.
    public var terminalReadiness: [UUID: TerminalReadiness] = [:]

    /// Terminal IDs eligible for auto-launch of `claude --continue`.
    /// Only restored (hydrated) and recovered orphan terminals are added here,
    /// not brand-new terminals created via the `new-terminal` RPC.
    public var autoLaunchTerminals: Set<UUID> = []

    /// Pending agent launch command per terminal ID, for brand-new managed
    /// terminals created via `new-terminal --command`. The command is NOT
    /// pasted immediately (that races the shell's line editor — issue #408);
    /// it is held here until the readiness sentinel fires `.shellReady`, at
    /// which point `SessionService.wireTerminalReadiness` pastes it. In-memory
    /// only — never persisted, so a relaunch can't re-paste a stale command.
    public var pendingLaunchCommands: [UUID: String] = [:]

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

    /// Snapshot every session's color-driving hook state for persistence (#367).
    public func allHookStateSnapshots() -> [UUID: PersistedHookState] {
        _sessionState.mapValues { $0.persistedSnapshot }
    }

    /// Seed a session's hook state from a persisted snapshot on launch, so the
    /// sidebar status colors are correct before any live hook event arrives.
    public func restoreHookState(_ snapshot: PersistedHookState, for sessionID: UUID) {
        hookState(for: sessionID).apply(snapshot)
    }

    /// Called when the user clicks the sidebar "+" to spawn a new Manager session.
    /// The optional `AgentKind` is a one-shot, per-session agent override chosen
    /// from the picker menu; `nil` means "use the configured default" (#582).
    public var onCreateManager: ((AgentKind?) -> Void)?

    /// Called when user clicks "Work on" for an assigned issue.
    public var onWorkOnIssue: ((String) -> Void)?  // receives issue URL

    /// Called when user clicks "Start Working" for multiple selected issues (batch mode).
    public var onBatchWorkOnIssues: (([String]) -> Void)?  // receives array of issue URLs

    /// Called when user clicks "Start Review" for a PR review request.
    public var onStartReview: ((String) -> Void)?  // receives PR URL

    /// Called when user clicks "Start Review" for multiple selected PR review requests (batch mode).
    public var onBatchStartReview: (([String]) -> Void)?  // receives array of PR URLs

    /// Called to launch the coding agent in a terminal that just became ready.
    public var onLaunchAgent: ((UUID) -> Void)?  // receives terminal ID

    /// Called to relaunch the Manager's `claude` process after it exited, while
    /// preserving the Manager session identity. Wired to `SessionService.restartManager`.
    public var onRestartManager: (() -> Void)?

    /// Called from the "Restart tmux Server" menu item (after confirmation) to
    /// kill the tmux server and rebuild every terminal surface. Wired to
    /// `SessionService.restartTmuxServer`.
    public var onRestartTmuxServer: (() -> Void)?

    /// Called when the user clicks "Retry" on a terminal whose tmux readiness
    /// watch timed out before the shell signaled it was interactive.
    public var onRetryReadiness: ((UUID) -> Void)?  // receives terminal ID

    /// Called when the user clicks "Copy diagnostics" on a terminal whose
    /// tmux readiness watch timed out. The handler captures a multi-section
    /// bundle (wrapper log, pane capture, ps tree, sentinel state) and
    /// places it on the clipboard (issue #256).
    public var onCopyDiagnostics: ((UUID) -> Void)?  // receives terminal ID

    /// Called to add a new plain-shell terminal tab to a session.
    public var onAddTerminal: ((UUID) -> Void)?  // receives session ID

    /// Called to close a non-managed terminal tab.
    public var onCloseTerminal: ((UUID, UUID) -> Void)?  // receives (sessionID, terminalID)

    /// Called to rename a terminal tab.
    public var onRenameTerminal: ((UUID, UUID, String) -> Void)?  // receives (sessionID, terminalID, newName)

    /// Called to rename a session (used for non-primary Manager rows).
    public var onRenameSession: ((UUID, String) -> Void)?  // receives (sessionID, newName)

    // MARK: - Closures wired by AppDelegate

    /// Called to delete a session and clean up its worktrees.
    public var onDeleteSession: ((UUID) async throws -> Void)?

    /// Called to mark a session as completed.
    public var onCompleteSession: ((UUID) -> Void)?

    /// Called to mark a session's ticket as "In Review" on the GitHub Project board.
    public var onMarkInReview: ((UUID) -> Void)?

    /// Called to move a session's linked issue to its done/closed state on the
    /// provider (GitHub close, GitLab close, Jira/Corveil transition to the
    /// mapped completed status). On success also flips the session to `.completed`.
    public var onMarkIssueDone: ((UUID) -> Void)?

    /// Called to add the `crow:merge` auto-merge label to a session's PR.
    public var onAddMergeLabel: ((UUID) -> Void)?

    /// Called to update session status to .inReview (persists to store).
    public var onSetSessionInReview: ((UUID) -> Void)?

    /// Called to update session status back to .active (persists to store).
    public var onSetSessionActive: ((UUID) -> Void)?

    /// Called to lock/unlock a session, exempting it from the retention cleanup
    /// reaper. Receives (sessionID, locked). Persists to store (CROW-573).
    public var onSetLocked: ((UUID, Bool) -> Void)?

    /// Whether a given session is currently being marked as "In Review" (loading state).
    /// Must be cleaned up when a session is deleted (see `SessionService.deleteSession`).
    public var isMarkingInReview: [UUID: Bool] = [:]

    /// Whether a session's linked issue is currently being closed/transitioned to
    /// done (loading state). Cleaned up when a session is deleted.
    public var isMarkingIssueDone: [UUID: Bool] = [:]

    /// Whether a session's PR is currently being labeled with `crow:merge` (loading state).
    /// Must be cleaned up when a session is deleted (see `SessionService.deleteSession`).
    public var isAddingMergeLabel: [UUID: Bool] = [:]

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

    /// Fire a job immediately, ignoring its enabled flag and schedule (job ID).
    public var onRunJob: ((UUID) -> Void)?

    // MARK: - Computed Properties

    public var selectedSession: Session? {
        guard selectedSessionID != Self.ticketBoardSessionID,
              selectedSessionID != Self.allowListSessionID,
              selectedSessionID != Self.reviewBoardSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var activeSessions: [Session] {
        sessions.filter { $0.status == .active && $0.kind == .work }
    }

    public var jobSessions: [Session] {
        sessions.filter { $0.status == .active && $0.kind == .job }
    }

    public var inReviewSessions: [Session] {
        sessions.filter { $0.status == .inReview && !$0.isManager }
    }

    public var completedSessions: [Session] {
        sessions.filter { ($0.status == .completed || $0.status == .archived) && !$0.isManager }
    }

    public var reviewSessions: [Session] {
        sessions.filter { $0.kind == .review && $0.status != .completed && $0.status != .archived }
    }

    public func worktrees(for sessionID: UUID) -> [SessionWorktree] {
        worktrees[sessionID] ?? []
    }

    /// Resolve a session UUID by matching against the worktree path of every
    /// known session. Returns the first match, or `nil` if no session has a
    /// worktree at the given path. Used by the hook-event RPC handler when
    /// the agent (e.g. Codex) doesn't carry the session UUID in its hook
    /// invocation — the `cwd` field of the payload is matched against
    /// worktree paths to recover the session.
    public func sessionID(forWorktreePath path: String) -> UUID? {
        for (sessionID, wts) in worktrees {
            if wts.contains(where: { $0.worktreePath == path }) {
                return sessionID
            }
        }
        return nil
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

    /// Resolves whether a session's task backend declares the
    /// `.projectBoardStatus` capability. Wired by `AppDelegate` using
    /// `ProviderManager.taskBackend(for:)`. CrowUI does not depend on
    /// CrowProvider, so the capability lookup is injected as a closure
    /// (same pattern as `onMarkInReview`, `onListWorkspaceRepos`).
    /// Defaults to `nil` so unwired contexts (tests, previews) treat the
    /// capability as absent. See ADR 0005.
    public var canSetProjectStatusResolver: ((Session) -> Bool)?

    /// Whether the session's provider supports setting project-board status,
    /// based on the `TaskBackend` capability set. Replaces the previous
    /// `session.provider == .github` UI guards. See ADR 0005.
    public func canSetProjectStatus(for session: Session) -> Bool {
        canSetProjectStatusResolver?(session) ?? false
    }

    /// Resolves whether a session's code backend declares the `.autoMergeLabel`
    /// capability (i.e. supports adding `crow:merge` to a PR). Wired by
    /// `AppDelegate` using `ProviderManager.codeBackend(for:)`. CrowUI does not
    /// depend on CrowProvider, so the capability lookup is injected as a closure
    /// (same pattern as `canSetProjectStatusResolver`). Defaults to `nil` so
    /// unwired contexts (tests, previews) treat the capability as absent.
    public var canAddMergeLabelResolver: ((Session) -> Bool)?

    /// Whether the session's provider supports adding the `crow:merge` label to
    /// its PR, based on the `CodeBackend` capability set. Used to gate the
    /// "Add label crow:merge to PR" sidebar context-menu item.
    public func canAddMergeLabel(for session: Session) -> Bool {
        canAddMergeLabelResolver?(session) ?? false
    }

    public func primaryWorktree(for sessionID: UUID) -> SessionWorktree? {
        worktrees[sessionID]?.first(where: { $0.isPrimary }) ?? worktrees[sessionID]?.first
    }

    // MARK: - Ticket Board Helpers

    /// Issues after applying repo exclusion filter.
    public var filteredAssignedIssues: [AssignedIssue] {
        guard !excludeTicketRepos.isEmpty else { return assignedIssues }
        return assignedIssues.filter { !repoMatchesPatterns($0.repo, patterns: excludeTicketRepos) }
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
                || issue.labels.contains(where: { $0.name.lowercased().contains(query) })
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

    /// Work sessions eligible to be shown as "linked" on the ticket board: every
    /// non-terminal session (`.active`, `.paused`, `.inReview`), excluding the
    /// terminal `.completed`/`.archived`. Broader than ``activeSessions`` so a
    /// ticket whose session has moved to In Review still shows as linked (#533).
    public var linkableSessions: [Session] {
        sessions.filter { $0.kind == .work && $0.status != .completed && $0.status != .archived }
    }

    /// Whether `session` is the Crow session for `issue`. Exact `ticketURL` match
    /// for all providers, plus a Jira-key fallback (`PROJ-123`) so Jira browse-URL
    /// variants still link (#533). GitHub/GitLab keep exact-URL matching only.
    private func ticketMatches(session: Session, issue: AssignedIssue) -> Bool {
        guard let url = session.ticketURL else { return false }
        if url == issue.url { return true }
        guard issue.provider == .jira,
              let sessionKey = Validation.jiraKey(from: url),
              let issueKey = Validation.jiraKey(from: issue.url) else { return false }
        return sessionKey.caseInsensitiveCompare(issueKey) == .orderedSame
    }

    /// Find the non-terminal session linked to a given issue. Considers Active,
    /// Paused, and In-Review sessions and matches Jira tickets robustly (#533) —
    /// the board uses this to show the linked-session indicator vs "Start Working".
    public func linkedSession(for issue: AssignedIssue) -> Session? {
        linkableSessions.first { ticketMatches(session: $0, issue: issue) }
    }

    /// Find the assigned issue linked to a given session. Matches exact ticket
    /// URL, plus a Jira-key fallback so labels/metadata resolve for In-Review and
    /// browse-URL-variant Jira sessions (#533).
    public func assignedIssue(for session: Session) -> AssignedIssue? {
        guard session.ticketURL != nil else { return nil }
        return assignedIssues.first { ticketMatches(session: session, issue: $0) }
    }

    /// Find the review request linked to a given session (by matching PR link URL).
    public func reviewRequest(for session: Session) -> ReviewRequest? {
        guard session.kind == .review else { return nil }
        guard let prLink = links(for: session.id).first(where: { $0.linkType == .pr }) else { return nil }
        return reviewRequests.first { $0.url == prLink.url }
    }

    /// Authoritative lookup for "is there already an active review session
    /// for this PR URL?". Cross-references `reviewSessions` (which already
    /// excludes completed/archived) against `links` by `.pr` linkType +
    /// exact URL match. Used by the kickoff watcher, the review-board
    /// buttons, and `SessionService.createReviewSession` as a single source
    /// of truth so they don't rely on the lagging `ReviewRequest.reviewSessionID`
    /// cross-reference that IssueTracker populates one tick late (CROW-406).
    public func existingReviewSession(forPRURL url: String) -> Session? {
        reviewSessions.first { session in
            links(for: session.id).contains { $0.linkType == .pr && $0.url == url }
        }
    }

    /// Labels for a session, sourced from its linked AssignedIssue or ReviewRequest.
    public func labels(forSession session: Session) -> [LabelInfo] {
        if let issue = assignedIssue(for: session) {
            return issue.labels
        }
        if let review = reviewRequest(for: session) {
            return review.labels
        }
        return []
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

/// Observable wrapper for per-session agent/hook state.
/// Using a reference-type @Observable class ensures that mutations to one session's
/// state only invalidate views observing THAT session's instance — not all sessions.
@MainActor
@Observable
public final class SessionHookState {
    public var activityState: AgentActivityState = .idle
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

/// Codable, value-type snapshot of the *color-driving* subset of
/// `SessionHookState`, persisted to the store so sidebar status colors are
/// correct immediately on relaunch — before any live hook event arrives (#367).
///
/// Only the fields that drive `SessionListView.statusIndicator` /
/// `rowBackgroundColor` are persisted. `lastToolActivity` is intentionally
/// excluded: it changes on every `PostToolUse` (very high frequency), only
/// feeds the badge text (not colors), and would be stale after relaunch anyway.
public struct PersistedHookState: Codable, Sendable, Equatable {
    public var activityState: AgentActivityState
    public var pendingNotification: HookNotification?
    public var lastTopLevelStopAt: Date?

    public init(
        activityState: AgentActivityState = .idle,
        pendingNotification: HookNotification? = nil,
        lastTopLevelStopAt: Date? = nil
    ) {
        self.activityState = activityState
        self.pendingNotification = pendingNotification
        self.lastTopLevelStopAt = lastTopLevelStopAt
    }
}

@MainActor
extension SessionHookState {
    /// Capture the persistable, color-driving subset of this state.
    public var persistedSnapshot: PersistedHookState {
        PersistedHookState(
            activityState: activityState,
            pendingNotification: pendingNotification,
            lastTopLevelStopAt: lastTopLevelStopAt
        )
    }

    /// Seed this state from a persisted snapshot (used on launch).
    public func apply(_ snapshot: PersistedHookState) {
        activityState = snapshot.activityState
        pendingNotification = snapshot.pendingNotification
        lastTopLevelStopAt = snapshot.lastTopLevelStopAt
    }
}
