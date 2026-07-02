import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

/// Polls GitHub/GitLab for issues assigned to the current user.
///
/// GitHub polling routes through `CrowProvider`'s `TaskBackend.listAssigned`
/// and `CodeBackend.listMonitoredPRs` (see ADR 0005). The PR side picks up
/// review requests, viewer PRs, and rate-limit observation in one batched
/// GraphQL call; the task side fetches open + recently-closed issues in
/// another. Per-session PR detection, PR status, and auto-complete all
/// piggyback on those two responses — no per-session `gh` calls. The
/// `rateLimit` block on each response feeds `AppState.githubRateLimit`,
/// and a soft threshold + 403 detection suspend polling when quotas are low.
@MainActor
final class IssueTracker {
    private let appState: AppState
    private let providerManager: ProviderManager
    private var timer: Timer?
    private let pollInterval: TimeInterval = 60 // 1 minute
    private var isRefreshing = false

    /// Local alias for the canonical `PRRecord` shape now living in
    /// `CrowProvider`. The migration kept the name in place to minimize the
    /// IssueTracker diff — every `ViewerPR` in this file is a `PRRecord`.
    typealias ViewerPR = PRRecord

    /// Callback for new review request notifications (set by AppDelegate).
    var onNewReviewRequests: (([ReviewRequest]) -> Void)?

    /// Fires when a newly assigned issue carries the auto-create label and
    /// has no existing session. Wired in AppDelegate to dispatch the
    /// `onWorkOnIssue` flow and post a notification.
    var onAutoCreateRequest: ((AssignedIssue) -> Void)?

    /// Callback fired on every successful review-request refresh with the full
    /// post-cross-reference snapshot (including the first fetch). Used by the
    /// auto-review opt-in path so requests already pending at app launch
    /// trigger a session, not just newly-arrived ones.
    var onReviewRequestsRefreshed: (([ReviewRequest]) -> Void)?

    /// Callback for detected PR status transitions — fires once per
    /// transition, after dedupe. Wired in AppDelegate to drive notifications
    /// and the auto-respond coordinator.
    var onPRStatusTransitions: (([PRStatusTransition]) -> Void)?

    /// Callback fired to delete a session during auto-cleanup.
    /// Wired in AppDelegate to call `appState.onDeleteSession`.
    var onDeleteSession: ((UUID) async -> Void)?

    /// Reads the latest `AppConfig.autoMergeWatcherEnabled` snapshot on
    /// every poll. Closure rather than direct AppConfig binding so toggling
    /// the setting in Settings takes effect on the next refresh without
    /// re-initializing the tracker. Defaults to a closure that returns
    /// `false` so the watcher is inert until AppDelegate wires it (CROW-299).
    var autoMergeWatcherEnabledProvider: () -> Bool = { false }

    /// Reads the latest `AppConfig.autoCreateWatcherEnabled` snapshot on
    /// every poll. Closure-based so toggling the setting in Settings takes
    /// effect on the next refresh without re-initializing the tracker.
    /// Defaults to `false` so the `crow:auto`-label automation is inert
    /// until AppDelegate wires it (CROW-312).
    var autoCreateWatcherEnabledProvider: () -> Bool = { false }

    /// Fires after Crow has successfully enabled GitHub native auto-merge
    /// on a PR. Wired in AppDelegate to post the user-facing notification.
    /// (The durable audit-log line is `NSLog`'d at the call site so it
    /// lands in Console regardless of notification settings.)
    var onAutoMergeEnabled: ((UUID, String, Int) -> Void)?

    /// Reads the latest `AutoRespondSettings.autoRebaseAndResolveConflicts`
    /// snapshot on every poll. Closure (not a stored value) so toggling the
    /// setting takes effect on the next refresh. Defaults to a closure
    /// returning `false` so the watcher is inert until AppDelegate wires it
    /// (CROW-318, moved into AutoRespondSettings by CROW-551).
    var autoRebaseAndResolveConflictsProvider: () -> Bool = { false }

    /// Reads the latest `AutoRespondSettings.respondToChangesRequested`
    /// snapshot on every poll. Gates the stateless "needs refine" emission
    /// (CROW-508) — when the user has opted out, we suppress both the
    /// notification and the dispatch, so they don't see fresh "Changes
    /// Requested" banners every cooldown window. Defaults to a closure
    /// returning `false` so the path stays inert until AppDelegate wires it.
    var respondToChangesRequestedProvider: () -> Bool = { false }

    /// Fires after Crow rebased a PR branch and force-pushed it. Wired in
    /// AppDelegate to post a notification.
    var onAutoRebasePushed: ((UUID, String, Int) -> Void)?

    /// Fires when an auto-rebase hit conflicts that need a human/Claude.
    /// Wired in AppDelegate to delegate resolution to the session's Claude
    /// terminal (the `fixConflicts` quick action) and notify.
    var onAutoRebaseConflicts: ((UUID, String, Int) -> Void)?

    /// Runs `git rebase` / force-push for the auto-rebase watcher. Owns its
    /// own instance (no `WorkspaceConfig` needed for path-scoped operations).
    private let gitManager = GitManager()

    /// Previously seen review request IDs for delta detection.
    private var previousReviewRequestIDs: Set<String> = []
    private var isFirstFetch = true

    /// Issue URLs we've already dispatched for auto-create but whose session
    /// hasn't yet landed in `appState`. Prevents repeat dispatches during the
    /// window between trigger and session registration.
    private var autoCreateInFlight: Set<String> = []

    /// Label that triggers the auto-create flow when present on an open
    /// assigned issue. Removed after a successful dispatch (best-effort) so
    /// the trigger is one-shot and visible across machines.
    static let autoCreateLabel = "crow:auto"

    /// Label that opts a PR into GitHub native auto-merge. Crow only acts
    /// when the PR is Crow-authored (Crow-Session trailer matches a known
    /// session). One-shot per PR: persisted via `Session.autoMergeEnabledAt`,
    /// and gated in-process by `autoMergeInFlight` between dispatch and
    /// persisted update (CROW-299). `nonisolated` so the pure
    /// `shouldAttemptAutoMerge` helper can read it without main-actor hops.
    nonisolated static let autoMergeLabel = "crow:merge"

    /// PR URLs we've already started an auto-merge enable attempt for.
    /// Cleared on failure (so the next poll retries) and effectively frozen
    /// on success once `Session.autoMergeEnabledAt` is persisted, which
    /// the gating guard checks first.
    private var autoMergeInFlight: Set<String> = []

    /// Per-head-commit guard for `gh pr update-branch`. Keyed
    /// `"<url>\n<headRefOid>"` so a PR that is `BEHIND` its base gets exactly
    /// one update attempt per head state — a successful update adds a merge
    /// commit (new `headRefOid` → new key), so a base that keeps moving can
    /// still re-update, while a stuck/no-op head isn't hammered every poll.
    /// In-memory only; a restart re-evaluates, which is harmless.
    private var autoUpdateBranchAttempted: Set<String> = []

    /// PR URLs with an auto-rebase attempt currently in flight. Cleared when
    /// the attempt finishes so the next poll can re-evaluate.
    private var autoRebaseInFlight: Set<String> = []

    /// Per-head-commit guard for auto-rebase, keyed `"<url>\n<headRefOid>"`.
    /// One rebase attempt per head state — a successful rebase rewrites the
    /// head (new key), and a delegated conflict resolution that pushes a new
    /// head also re-arms. Transient outcomes (`.dirtyWorktree`,
    /// `.outOfSyncWithRemote`, and bounded `.failed` retries) un-set the key so
    /// the next poll retries. In-memory only.
    private var autoRebaseAttempted: Set<String> = []

    /// Consecutive `.failed` rebase attempts per head-key, so a transient git
    /// failure (fetch flake, rejected lease, unreachable base) is retried a
    /// bounded number of times rather than either stalling forever or
    /// hot-looping on a genuinely-broken config. Cleared on any non-failure
    /// outcome. In-memory only.
    private var autoRebaseFailureCounts: [String: Int] = [:]

    /// Max consecutive `.failed` auto-rebase attempts per head state before
    /// the watcher gives up until the head commit changes.
    nonisolated static let maxAutoRebaseFailureRetries = 3

    /// Last observed `PRStatus` per session. Ephemeral (not persisted across
    /// Crow restarts post-CROW-508): only used for in-process `.checksFailing`
    /// edge detection. `.changesRequested` no longer reads from this map —
    /// the stateless `PRStatus.needsRefine` rule derives the answer from the
    /// PR snapshot on every poll.
    /// Internal (not private) so `@testable` tests can seed it without going
    /// through a full poll.
    var previousPRStatus: [UUID: PRStatus] = [:]

    /// PR URLs we've observed at least once in this Crow process. First poll
    /// records the URL but does NOT dispatch — the next poll is the earliest
    /// the stateless "needs refine" rule can emit. Ephemeral; a Crow restart
    /// re-arms the skip so a single duplicate prompt across a restart
    /// (acceptable per CROW-508) is the worst case.
    var seenPRs: Set<String> = []

    /// Per-PR cooldown clock for "needs refine" dispatches. Keyed by PR URL
    /// rather than session UUID so that two sessions linked to the same PR
    /// can't both burn through the cooldown. Ephemeral by design — surviving
    /// a restart isn't worth the persistence cost (worst case after restart
    /// is one extra prompt, then the cooldown re-applies).
    var lastRefineDispatchAt: [String: Date] = [:]

    /// Per-PR record of the `lastChangesRequestedAt` we most recently posted
    /// a macOS notification for. When a cooldown re-fire dispatches for the
    /// same reviewer submission (same timestamp), the emitted transition
    /// carries `isCooldownReFire = true` so `AppDelegate.onPRStatusTransitions`
    /// skips the notification — the agent re-prompt is still useful, but a
    /// fresh banner every 7 min for the same review is pure noise. A new
    /// reviewer submission advances `lastChangesRequestedAt`, so the very
    /// next dispatch is `isCooldownReFire = false` and notifies again.
    /// Ephemeral; restart cost is one duplicate banner per PR, bounded.
    var lastNotifiedChangesRequestedAt: [String: Date] = [:]

    /// Minimum gap between consecutive "needs refine" dispatches for the same
    /// PR (CROW-508). 7 min is a deliberate middle of the 5–10 min range the
    /// ticket suggested: long enough that an agent thinking through a hard
    /// finding doesn't get re-prompted mid-thought, short enough that a true
    /// stall surfaces within ~3 poll cycles. Constant so it can be tuned if
    /// real-world telemetry calls for it.
    nonisolated static let needsRefineCooldown: TimeInterval = 7 * 60

    /// Guards the GitHub-scope console warning so it fires once per session.
    private var didLogGitHubScopeWarning = false

    /// Guards the GitHub-SAML console warning so it fires once per session.
    private var didLogGitHubSAMLWarning = false

    /// When non-nil and in the future, all polls are skipped.
    private var suspendedUntil: Date?

    /// Below this many remaining GraphQL points we proactively skip a cycle.
    private let rateLimitThreshold = 50

    init(appState: AppState, providerManager: ProviderManager) {
        self.appState = appState
        self.providerManager = providerManager
    }

    func start() {
        // Initial fetch. Post-CROW-508 the tracker is stateless across
        // restarts — the "needs refine" rule derives from PR data on every
        // poll, so there's no `hydratePersistedState` to call here.
        Task { await refresh() }

        // Poll on interval
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Warnings

    /// Surface a missing-scope warning: console once per session, UI banner every time.
    private func reportScopeWarning(_ scope: String) {
        let msg = "GitHub token missing '\(scope)' scope — run 'gh auth refresh -s \(scope)'"
        if !didLogGitHubScopeWarning {
            print("[IssueTracker] \(msg)")
            didLogGitHubScopeWarning = true
        }
        appState.githubScopeWarning = msg
    }

    /// Drop the warning after a successful poll. Re-arms the once-per-session log
    /// so a future regression will print again.
    private func clearScopeWarning() {
        if appState.githubScopeWarning != nil {
            appState.githubScopeWarning = nil
        }
        didLogGitHubScopeWarning = false
    }

    /// Surface a SAML-enforcement warning: console once per session, UI banner
    /// every time. Fires when an org's SAML SSO blocks the OAuth token — the
    /// backend recovers accessible-org tickets and flags the response, so this
    /// is informational, not fatal.
    private func reportSAMLWarning() {
        let msg = "GitHub: an org enforces SAML SSO and your token isn't authorized — its tickets are hidden. "
            + "Authorize it at github.com/settings/connections, or ignore if you don't use it on this machine."
        if !didLogGitHubSAMLWarning {
            print("[IssueTracker] \(msg)")
            didLogGitHubSAMLWarning = true
        }
        appState.githubSAMLWarning = msg
    }

    /// Drop the SAML warning after a poll with no SAML restriction. Re-arms the
    /// once-per-session log so a future regression will print again.
    private func clearSAMLWarning() {
        if appState.githubSAMLWarning != nil {
            appState.githubSAMLWarning = nil
        }
        didLogGitHubSAMLWarning = false
    }

    private func reportRateLimitWarning(resetAt: Date) {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        appState.rateLimitWarning = "GitHub rate-limited, retrying at \(fmt.string(from: resetAt))"
    }

    private func clearRateLimitWarning() {
        if appState.rateLimitWarning != nil {
            appState.rateLimitWarning = nil
        }
        suspendedUntil = nil
    }

    // MARK: - Rate-Limit Guard

    /// Returns false if polling is suspended (recent 403) or the observed
    /// `rateLimit.remaining` is below the threshold with a future reset.
    private func shouldPoll() -> Bool {
        let now = Date()
        if let suspendedUntil, suspendedUntil > now {
            return false
        }
        if let rl = appState.githubRateLimit,
           rl.remaining < rateLimitThreshold,
           rl.resetAt > now {
            if appState.rateLimitWarning == nil {
                reportRateLimitWarning(resetAt: rl.resetAt)
            }
            return false
        }
        return true
    }

    /// If `stderr` indicates a rate-limit error, suspend polling until `resetAt`
    /// (or ~5 min if no reset could be parsed) and return true.
    @discardableResult
    private func handleGraphQLRateLimit(stderr: String) -> Bool {
        let s = stderr.lowercased()
        let isRateLimit = s.contains("rate limit")
            || s.contains("was submitted too quickly")
            || s.contains("abuse")
        guard isRateLimit else { return false }

        let resetAt = parseResetAt(from: stderr) ?? Date().addingTimeInterval(5 * 60)
        suspendedUntil = resetAt
        reportRateLimitWarning(resetAt: resetAt)
        print("[IssueTracker] GitHub rate-limited — suspending polling until \(resetAt)")
        return true
    }

    /// Best-effort parse of `X-RateLimit-Reset` (epoch seconds) or `Retry-After`
    /// (seconds) from `gh` stderr. gh usually surfaces neither in stderr, so this
    /// often returns nil and we fall back to a default window.
    private func parseResetAt(from stderr: String) -> Date? {
        // Look for "X-RateLimit-Reset: 1723456789" style lines.
        if let match = stderr.range(of: #"X-RateLimit-Reset:\s*(\d+)"#, options: .regularExpression) {
            let num = stderr[match]
                .split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
            if let num, let epoch = TimeInterval(num) {
                return Date(timeIntervalSince1970: epoch)
            }
        }
        if let match = stderr.range(of: #"Retry-After:\s*(\d+)"#, options: .regularExpression) {
            let num = stderr[match]
                .split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
            if let num, let secs = TimeInterval(num) {
                return Date().addingTimeInterval(secs)
            }
        }
        return nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        guard shouldPoll() else {
            if let suspendedUntil {
                print("[IssueTracker] skipping refresh — rate-limited until \(suspendedUntil)")
            }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        appState.isLoadingIssues = true
        defer { appState.isLoadingIssues = false }

        let startedAt = Date()

        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return }

        // Iterate by **task** provider — a workspace's tickets may live somewhere
        // other than its code host (ADR 0005). A Jira-task / GitHub-code workspace
        // contributes Jira issues here but still uses the GitHub code path below.
        let hasGitHub = config.workspaces.contains(where: { $0.derivedTaskProvider == "github" })
        var gitLabHosts: [String] = []
        for ws in config.workspaces where ws.derivedTaskProvider == "gitlab" {
            if let host = ws.host, !gitLabHosts.contains(host) {
                gitLabHosts.append(host)
            }
        }
        // Collect distinct Jira queries (the site/JQL/project triple is what
        // actually varies). Resolve the shared Jira REST credential once (it may
        // shell `op read`) and thread it into every config so the board read-back
        // can list assigned issues over REST instead of acli (#533).
        let jiraAuthorization = config.jiraCredential.flatMap { JiraCredentialResolver.resolve($0) }
        var jiraConfigs: [JiraConfig] = []
        for ws in config.workspaces where ws.derivedTaskProvider == "jira" {
            let cfg = JiraConfig(site: ws.jiraSite, projectKey: ws.jiraProjectKey, jql: ws.jiraJQL, statusMap: ws.jiraStatusMap, authorization: jiraAuthorization)
            if !jiraConfigs.contains(cfg) { jiraConfigs.append(cfg) }
        }
        // Collect distinct Corveil configs. The corveil CLI is authed to one
        // host, so the workspace host (used only for URL routing) is what
        // varies; we dedupe by host to avoid fanning out to the same authed
        // session twice.
        var corveilConfigs: [CorveilConfig] = []
        for ws in config.workspaces where ws.derivedTaskProvider == "corveil" {
            let cfg = CorveilConfig(host: ws.corveilHost)
            if !corveilConfigs.contains(cfg) { corveilConfigs.append(cfg) }
        }

        var allIssues: [AssignedIssue] = []
        // Recently-done count, accumulated across every provider this refresh.
        // Each provider contributes its 24h closed/Done window; assigned once
        // at the end so a non-GitHub (e.g. Jira-only) workspace updates it too
        // instead of leaving a stale value from a prior GitHub-backed refresh.
        var doneCount = 0

        // GitHub — one consolidated GraphQL query
        let ghResult: ConsolidatedGitHubResponse? = hasGitHub ? await runConsolidatedGitHubQuery() : nil
        if let ghResult {
            if let rl = ghResult.rateLimit { appState.githubRateLimit = rl }

            var openIssues = ghResult.openIssues
            // Match viewer's open PRs to issues by closingIssuesReferences (repo + number)
            for pr in ghResult.viewerPRs where pr.state == "OPEN" {
                for linked in pr.linkedIssueReferences {
                    if let idx = openIssues.firstIndex(where: {
                        $0.provider == .github && $0.number == linked.number && $0.repo == linked.repo
                    }) {
                        openIssues[idx].prNumber = pr.number
                        openIssues[idx].prURL = pr.url
                    }
                }
            }
            allIssues.append(contentsOf: openIssues)

            let openIDs = Set(openIssues.map(\.id))
            let uniqueDone = ghResult.closedIssues.filter { !openIDs.contains($0.id) }
            allIssues.append(contentsOf: uniqueDone)
            doneCount += ghResult.closedTotalCount
        }

        // GitLab — unchanged fan-out (one call per host)
        for host in gitLabHosts {
            let issues = await fetchGitLabIssues(host: host)
            allIssues.append(contentsOf: issues)
        }

        // Jira — one search per distinct config (best-effort, like GitLab).
        // Include the recently-Done half (#536): a Jira ticket in its mapped
        // Done status is a workflow status, not a closed issue, so it only lands
        // in the board's Done section once its `.done`-mapped issue reaches
        // `assignedIssues`. Mirror GitHub's open + deduped-closed merge.
        for cfg in jiraConfigs {
            let listing = await fetchJiraIssues(config: cfg)
            let merged = Self.mergeJiraListing(listing)
            allIssues.append(contentsOf: merged.issues)
            doneCount += merged.doneCount
        }

        // Corveil — one list per distinct config (best-effort).
        for cfg in corveilConfigs {
            let issues = await fetchCorveilIssues(config: cfg)
            allIssues.append(contentsOf: issues)
        }

        appState.assignedIssues = allIssues
        appState.doneIssuesLast24h = doneCount

        let ticketExcludePatterns = config.defaults.excludeTicketRepos
        let autoCreateCandidates = ticketExcludePatterns.isEmpty
            ? allIssues
            : allIssues.filter { !repoMatchesPatterns($0.repo, patterns: ticketExcludePatterns) }
        detectAutoCreateCandidates(issues: autoCreateCandidates)

        if let ghResult {
            // Session PR link detection runs against open PRs only — we only
            // ever want to attach a fresh link when there's an open PR.
            applySessionPRLinks(viewerPRs: ghResult.viewerPRs)

            // For sessions with an existing .pr link whose PR isn't in the open
            // viewer set, fetch the state in one batched aliased query. This
            // surfaces merged/closed state without pulling MERGED/CLOSED PRs
            // for every viewer (which routinely returned 100 PRs / ~86 KB).
            let openPRURLs = Set(ghResult.viewerPRs.map(\.url))
            let staleCandidateURLs = collectStalePRURLs(excluding: openPRURLs)
            // `complete == false` means at least one provider's follow-up errored
            // (rate limit, exit != 0, parse failure). We thread that through to
            // auto-complete so "PR missing from payload" doesn't get treated as
            // "PR is closed" on a degraded response. Partial-success is allowed:
            // PRs from the working provider still flow through so merged badges
            // can flip even if the other provider failed.
            let staleFetch = staleCandidateURLs.isEmpty
                ? StalePRFetchResult(prs: [], complete: true)
                : await fetchStalePRStates(urls: staleCandidateURLs)
            let stalePRs = staleFetch.prs
            let prDataComplete = staleFetch.complete
            let allKnownPRs = Self.dedupedByURL(ghResult.viewerPRs + stalePRs)

            applyPRStatuses(viewerPRs: allKnownPRs)

            // Review requests (search result) + cross-reference with review sessions
            appState.isLoadingReviews = true
            var reviews = ghResult.reviewRequests
            for i in reviews.indices {
                if let session = appState.reviewSessions.first(where: {
                    appState.links(for: $0.id).contains(where: { $0.linkType == .pr && $0.url == reviews[i].url })
                }) {
                    reviews[i].reviewSessionID = session.id
                }
            }
            let allCurrentIDs = Set(reviews.map(\.id))
            let reviewExcludePatterns = config.effectiveExcludeReviewRepos
            if !reviewExcludePatterns.isEmpty {
                reviews = reviews.filter { !repoMatchesPatterns($0.repo, patterns: reviewExcludePatterns) }
            }
            let ignoreLabels = config.defaults.ignoreReviewLabels
            if !ignoreLabels.isEmpty {
                let lowerLabels = Set(ignoreLabels.map { $0.lowercased() })
                reviews = reviews.filter { request in
                    !request.labels.contains(where: { lowerLabels.contains($0.name.lowercased()) })
                }
            }
            let currentIDs = Set(reviews.map(\.id))
            let newIDs = currentIDs.subtracting(previousReviewRequestIDs)
            previousReviewRequestIDs = allCurrentIDs
            if !isFirstFetch && !newIDs.isEmpty {
                let newRequests = reviews.filter { newIDs.contains($0.id) }
                onNewReviewRequests?(newRequests)
            }
            isFirstFetch = false
            appState.reviewRequests = reviews
            appState.isLoadingReviews = false

            onReviewRequestsRefreshed?(reviews)

            syncInReviewSessions(issues: allIssues)
            autoCompleteFinishedSessions(
                openIssues: allIssues.filter { $0.state == "open" },
                closedIssueURLs: Set(ghResult.closedIssues.map(\.url)),
                viewerPRs: allKnownPRs,
                prDataComplete: prDataComplete
            )
            autoCompleteFinishedReviews(
                openReviewPRURLs: Set(reviews.map(\.url)),
                prsByURL: Dictionary(allKnownPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords),
                reviewRequestsByPRURL: Dictionary(reviews.map { ($0.url, $0) }, uniquingKeysWith: { lhs, _ in lhs }),
                prDataComplete: prDataComplete
            )

            clearRateLimitWarning()
        }

        // Reconcile any session still missing a .pr link by querying the
        // provider directly on (repoSlug, headBranch). Covers PRs that aren't
        // in the viewer's open-PR payload (other author, merged/closed, etc).
        // Runs after the reactive path so we only ask providers for the
        // sessions that actually need it. Safe for GitLab-only or no-GitHub
        // workspaces — the GitHub branch is gated by candidate count.
        await reconcileMissingPRLinks()

        // Auto-cleanup expired completed/archived sessions. Runs outside
        // the ghResult block so it fires even without GitHub data. Placed
        // after auto-complete so freshly completed sessions respect the
        // full retention window.
        await autoCleanupExpiredSessions(config: config)

        logRefreshSummary(elapsed: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Auto-create on assign

    /// Dispatches `onAutoCreateRequest` for open assigned issues carrying the
    /// `crow:auto` label, then asynchronously strips the label so the trigger
    /// is one-shot and visible across machines. Issues that already have an
    /// active session are treated as "work picked up elsewhere" — we still
    /// strip the stale label but don't re-dispatch.
    ///
    /// No-op when the global `autoCreateWatcherEnabled` setting is off
    /// (CROW-312). The label is intentionally left in place while disabled
    /// so a later opt-in still picks up the issue on the next poll.
    private func detectAutoCreateCandidates(issues: [AssignedIssue]) {
        guard autoCreateWatcherEnabledProvider() else { return }
        // Purge in-flight URLs that now have an active session — the dispatch
        // succeeded and the set can shrink.
        if !autoCreateInFlight.isEmpty {
            let active = Set(appState.activeSessions.compactMap(\.ticketURL))
            autoCreateInFlight.subtract(active)
        }

        for issue in issues where issue.state == "open" {
            let labeled = issue.labels.contains { $0.name.caseInsensitiveCompare(Self.autoCreateLabel) == .orderedSame }
            guard labeled else { continue }
            guard !autoCreateInFlight.contains(issue.url) else { continue }

            if appState.linkedSession(for: issue) != nil {
                // Stale label — work already picked up elsewhere. Best-effort cleanup.
                Task { [weak self] in await self?.removeAutoCreateLabel(from: issue) }
                continue
            }

            autoCreateInFlight.insert(issue.url)
            onAutoCreateRequest?(issue)
            Task { [weak self] in await self?.removeAutoCreateLabel(from: issue) }
        }
    }

    /// Best-effort removal of the auto-create label. Failure is logged and
    /// otherwise ignored — the in-memory `autoCreateInFlight` + active-session
    /// dedup keeps duplicate spawns at bay until the label is gone.
    private func removeAutoCreateLabel(from issue: AssignedIssue) async {
        // issue.id format for GitLab: "gitlab:host:org/repo#number". Need the
        // host segment to pick the right `GITLAB_HOST` for the backend.
        let host: String?
        if issue.provider == .gitlab {
            let parts = issue.id.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else {
                print("[IssueTracker] cannot strip label, malformed gitlab id: \(issue.id)")
                return
            }
            host = parts[1]
        } else {
            host = nil
        }
        let backend = providerManager.taskBackend(for: issue.provider, host: host)
        do {
            try await backend.setLabels(url: issue.url, add: [], remove: [Self.autoCreateLabel])
        } catch {
            print("[IssueTracker] failed to remove \(Self.autoCreateLabel) from \(issue.url): \(error.localizedDescription)")
        }
    }

    private func logRefreshSummary(elapsed: TimeInterval) {
        let elapsedStr = String(format: "%.2fs", elapsed)
        if let rl = appState.githubRateLimit {
            let mins = Int(max(0, rl.resetAt.timeIntervalSinceNow / 60))
            print("[IssueTracker] refresh: \(elapsedStr), GraphQL \(rl.remaining)/\(rl.limit) remaining, resets in \(mins)m")
        } else {
            print("[IssueTracker] refresh: \(elapsedStr)")
        }
    }

    // MARK: - Consolidated GraphQL Query

    private struct ConsolidatedGitHubResponse: Sendable {
        let openIssues: [AssignedIssue]
        let closedIssues: [AssignedIssue]
        /// True 24h closed total (search `issueCount`) — `closedIssues` holds
        /// at most the 50 fetched nodes, so the done badge counts this instead.
        let closedTotalCount: Int
        let viewerPRs: [ViewerPR]
        let reviewRequests: [ReviewRequest]
        let rateLimit: GitHubRateLimit?
    }

    // MARK: - PR Dedup

    /// State-rank precedence used when the same PR URL appears in multiple
    /// source lists (viewer vs stale-PR follow-up). Higher rank wins.
    nonisolated static func stateRank(_ state: String) -> Int {
        switch state {
        case "MERGED": return 3
        case "CLOSED": return 2
        case "OPEN":   return 1
        default:       return 0
        }
    }

    /// Merge two `ViewerPR` records for the same URL. The record with the
    /// higher state rank wins the state/isDraft/number fields; empty fields
    /// on the winner are backfilled from the loser so that (e.g.) an
    /// OPEN→MERGED demotion mid-refresh still carries the checks/reviews
    /// from the OPEN record (the stale-PR follow-up query leaves those
    /// fields empty).
    nonisolated static func mergePRRecords(_ lhs: ViewerPR, _ rhs: ViewerPR) -> ViewerPR {
        let (winner, loser) = stateRank(lhs.state) >= stateRank(rhs.state)
            ? (lhs, rhs) : (rhs, lhs)
        return ViewerPR(
            number: winner.number,
            url: winner.url,
            state: winner.state,
            mergeable: winner.mergeable != "UNKNOWN" ? winner.mergeable : loser.mergeable,
            mergeStateStatus: winner.mergeStateStatus != "UNKNOWN" ? winner.mergeStateStatus : loser.mergeStateStatus,
            reviewDecision: winner.reviewDecision.isEmpty ? loser.reviewDecision : winner.reviewDecision,
            isDraft: winner.isDraft,
            headRefName: winner.headRefName.isEmpty ? loser.headRefName : winner.headRefName,
            headRefOid: winner.headRefOid.isEmpty ? loser.headRefOid : winner.headRefOid,
            baseRefName: winner.baseRefName.isEmpty ? loser.baseRefName : winner.baseRefName,
            repoNameWithOwner: winner.repoNameWithOwner.isEmpty ? loser.repoNameWithOwner : winner.repoNameWithOwner,
            labels: winner.labels.isEmpty ? loser.labels : winner.labels,
            linkedIssueReferences: winner.linkedIssueReferences.isEmpty ? loser.linkedIssueReferences : winner.linkedIssueReferences,
            checksState: winner.checksState.isEmpty ? loser.checksState : winner.checksState,
            failedCheckNames: winner.failedCheckNames.isEmpty ? loser.failedCheckNames : winner.failedCheckNames,
            latestReviewStates: winner.latestReviewStates.isEmpty ? loser.latestReviewStates : winner.latestReviewStates,
            lastChangesRequestedAt: winner.lastChangesRequestedAt ?? loser.lastChangesRequestedAt,
            lastSubstantiveCommitAt: winner.lastSubstantiveCommitAt ?? loser.lastSubstantiveCommitAt
        )
    }

    /// Collapse duplicate URLs using `mergePRRecords`, preserving first-seen
    /// order so downstream iteration remains deterministic.
    nonisolated static func dedupedByURL(_ prs: [ViewerPR]) -> [ViewerPR] {
        var byURL: [String: ViewerPR] = [:]
        var order: [String] = []
        for pr in prs {
            if let existing = byURL[pr.url] {
                byURL[pr.url] = mergePRRecords(existing, pr)
            } else {
                byURL[pr.url] = pr
                order.append(pr.url)
            }
        }
        return order.compactMap { byURL[$0] }
    }

    /// Pull the viewer's assigned issues, monitored PRs, and review requests
    /// via the GitHub backends. Issues + PRs go in parallel — the GitHub
    /// backend issues two GraphQL calls in flight at once (one for assigned
    /// issues, one for PRs + reviews).
    private func runConsolidatedGitHubQuery() async -> ConsolidatedGitHubResponse? {
        let taskBackend = providerManager.taskBackend(for: .github)
        let codeBackend = providerManager.codeBackend(for: .github)!

        async let assignedAsync = taskBackend.listAssigned()
        async let monitoredAsync = codeBackend.listMonitoredPRs()

        let assigned: AssignedListing
        let monitored: MonitoredPRListing
        do {
            assigned = try await assignedAsync
        } catch {
            handleGitHubBackendError(error, operation: "listAssigned")
            // Drain the second task so we don't leak an unawaited future.
            _ = try? await monitoredAsync
            return nil
        }
        do {
            monitored = try await monitoredAsync
        } catch {
            handleGitHubBackendError(error, operation: "listMonitoredPRs")
            return nil
        }

        if let scope = assigned.missingScope {
            // listAssigned silently degrades on INSUFFICIENT_SCOPES (drops
            // projectItems) and reports the scope here so the warning UI
            // stays lit instead of getting cleared on the next poll. This
            // preserves the prior `reportScopeWarning("read:project")`
            // behavior the consolidated query had inline.
            reportScopeWarning(scope)
        } else {
            clearScopeWarning()
        }

        // The backends recover accessible-org data on SAML enforcement and
        // flag the listing rather than throwing, so the response is still
        // assembled above. Light the one-time warning while any org stays
        // blocked; clear it once a clean poll returns.
        if assigned.samlRestricted || monitored.samlRestricted {
            reportSAMLWarning()
        } else {
            clearSAMLWarning()
        }
        return ConsolidatedGitHubResponse(
            openIssues: assigned.open,
            closedIssues: assigned.closed,
            closedTotalCount: assigned.closedTotalCount,
            viewerPRs: monitored.viewerPRs,
            reviewRequests: monitored.reviewRequests,
            rateLimit: assigned.rateLimit ?? monitored.rateLimit
        )
    }

    /// Route typed `ProviderError`s from GitHub backends to the matching
    /// IssueTracker UI side-effect (scope warning, rate-limit suspension).
    /// Untyped errors get a console line and otherwise propagate as "this
    /// cycle is degraded" via the caller's nil-return.
    private func handleGitHubBackendError(_ error: Error, operation: String) {
        switch error {
        case ProviderError.insufficientScope(let scope):
            reportScopeWarning(scope)
        case ProviderError.rateLimited(let stderr):
            _ = handleGraphQLRateLimit(stderr: stderr)
        case ProviderError.samlRestricted:
            // Secondary calls (prStates, findRecentPRsForBranches) don't
            // recover partial data; route their SAML failures to the same
            // one-time warning instead of spamming the console each cycle.
            reportSAMLWarning()
        default:
            print("[IssueTracker] \(operation) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stale PR Follow-up

    /// PR URLs linked to active/paused/inReview sessions that are NOT in
    /// `openPRURLs`. These are the PRs we need to fetch state for to surface
    /// merged/closed status on the badge and drive auto-complete.
    /// Completed sessions are skipped — their badge state is set in-memory
    /// during the cycle they auto-complete and is preserved thereafter.
    private func collectStalePRURLs(excluding openPRURLs: Set<String>) -> [String] {
        var urls: Set<String> = []
        for session in appState.sessions where !session.isManager {
            switch session.status {
            case .active, .paused, .inReview:
                break
            default:
                continue
            }
            for link in appState.links(for: session.id) where link.linkType == .pr {
                if !openPRURLs.contains(link.url) {
                    urls.insert(link.url)
                }
            }
        }
        return Array(urls)
    }

    /// Result of a stale-PR follow-up: any PRs successfully fetched, plus
    /// whether every provider call returned cleanly. `complete == false`
    /// signals downstream auto-completion to treat the cycle as degraded.
    private struct StalePRFetchResult {
        var prs: [ViewerPR]
        var complete: Bool
    }

    /// Fetch state for a small set of PRs/MRs that are linked to a session
    /// but no longer in the open viewer set (typically merged or closed).
    /// Splits URLs by provider — GitHub PRs go through one batched aliased
    /// `gh`/`glab` call, GitLab MRs go through one REST call per
    /// MR (with `GITLAB_HOST` set per host). A failure on either side marks
    /// the result incomplete but doesn't suppress the other side's PRs.
    /// Returns minimal `ViewerPR` records — only `state`, `url`, repo, and
    /// branch refs are populated; checks/reviews are left empty since
    /// they're moot for closed PRs.
    private func fetchStalePRStates(urls: [String]) async -> StalePRFetchResult {
        // Bucket URLs by (provider, host). GitLab self-hosted needs the host so the
        // backend pins the right GITLAB_HOST env var.
        var githubRefs: [PRRef] = []
        var githubURLByRef: [PRRef: String] = [:]
        var gitlabByHost: [String: [PRRef]] = [:]
        var gitlabURLByRef: [PRRef: String] = [:]

        for url in urls {
            if let g = Self.parseGitLabMRURL(url) {
                let parts = g.slug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                guard parts.count == 2 else { continue }
                let ref = PRRef(owner: parts[0], repo: parts[1], number: g.number)
                gitlabByHost[g.host, default: []].append(ref)
                gitlabURLByRef[ref] = url
                continue
            }
            guard let p = ProviderManager.parseTicketURLComponents(url) else { continue }
            if let host = URL(string: url)?.host, host != "github.com" {
                continue
            }
            let ref = PRRef(owner: p.org, repo: p.repo, number: p.number)
            githubRefs.append(ref)
            githubURLByRef[ref] = url
        }
        guard !githubRefs.isEmpty || !gitlabByHost.isEmpty else {
            return StalePRFetchResult(prs: [], complete: true)
        }

        var prs: [ViewerPR] = []
        var complete = true

        if !githubRefs.isEmpty {
            let backend = providerManager.codeBackend(for: .github)!
            do {
                let states = try await backend.prStates(refs: githubRefs)
                // Keying by PRRef means we don't lose records when the API
                // returns a canonical URL different from the stored one.
                // Fall back to the stored URL when the API didn't provide
                // one (defensive — usually populated).
                for ref in githubRefs {
                    guard var rec = states[ref] else { continue }
                    if rec.url.isEmpty, let stored = githubURLByRef[ref] {
                        rec = Self.withURL(rec, url: stored)
                    }
                    prs.append(rec)
                }
            } catch {
                handleGitHubBackendError(error, operation: "prStates(github)")
                complete = false
            }
        }

        for (host, refs) in gitlabByHost {
            let backend = providerManager.codeBackend(for: .gitlab, host: host)!
            do {
                let states = try await backend.prStates(refs: refs)
                for ref in refs {
                    guard var rec = states[ref] else { continue }
                    if rec.url.isEmpty, let stored = gitlabURLByRef[ref] {
                        rec = Self.withURL(rec, url: stored)
                    }
                    prs.append(rec)
                }
            } catch {
                print("[IssueTracker] Stale-PR follow-up via backend failed for host \(host): \(error.localizedDescription.prefix(200))")
                complete = false
            }
        }

        return StalePRFetchResult(prs: prs, complete: complete)
    }

    /// Copy `pr` with a different `url`. Used by the stale-PR follow-up to
    /// substitute the session-link URL when the backend returned an empty
    /// `web_url` (defensive — GitLab's REST shape always populates it, but
    /// we'd rather preserve the link than lose the record).
    nonisolated static func withURL(_ pr: ViewerPR, url: String) -> ViewerPR {
        PRRecord(
            number: pr.number,
            url: url,
            state: pr.state,
            mergeable: pr.mergeable,
            mergeStateStatus: pr.mergeStateStatus,
            reviewDecision: pr.reviewDecision,
            isDraft: pr.isDraft,
            headRefName: pr.headRefName,
            headRefOid: pr.headRefOid,
            baseRefName: pr.baseRefName,
            repoNameWithOwner: pr.repoNameWithOwner,
            labels: pr.labels,
            linkedIssueReferences: pr.linkedIssueReferences,
            checksState: pr.checksState,
            failedCheckNames: pr.failedCheckNames,
            latestReviewStates: pr.latestReviewStates,
            lastChangesRequestedAt: pr.lastChangesRequestedAt,
            lastSubstantiveCommitAt: pr.lastSubstantiveCommitAt,
            updatedAt: pr.updatedAt
        )
    }

    /// Parse a GitLab MR URL into (host, slug, number). Robust to nested
    /// groups (slug is everything between the host and `/-/merge_requests/`).
    /// Returns nil for non-GitLab-MR URLs. Kept here (not in CrowProvider)
    /// because it's used by the URL-routing logic above.
    nonisolated static func parseGitLabMRURL(_ url: String) -> (host: String, slug: String, number: Int)? {
        guard let protoRange = url.range(of: "://") else { return nil }
        let afterProto = String(url[protoRange.upperBound...])
        guard let mrRange = afterProto.range(of: "/-/merge_requests/") else { return nil }
        let leading = String(afterProto[..<mrRange.lowerBound])
        let trailing = String(afterProto[mrRange.upperBound...])

        let leadParts = leading.split(separator: "/").map(String.init)
        guard leadParts.count >= 3 else { return nil }
        let host = leadParts[0]
        let slug = leadParts.dropFirst().joined(separator: "/")

        let trailParts = trailing.split(separator: "/").map(String.init)
        guard let first = trailParts.first, let number = Int(first) else { return nil }
        return (host, slug, number)
    }

    /// Thin alias so test code keeps working through the migration. The real
    /// normalization lives on `GitLabCodeBackend` (CrowProvider).
    nonisolated static func normalizeGitLabPRState(_ raw: String) -> String {
        GitLabCodeBackend.normalizeState(raw)
    }

    /// Thin alias so test code keeps working through the migration. The real
    /// parsing lives on `GitLabCodeBackend` (CrowProvider).
    nonisolated static func parseGitLabStaleMRResponse(
        _ output: String,
        fallbackURL: String,
        fallbackSlug: String
    ) -> ViewerPR? {
        GitLabCodeBackend.parseStaleMRResponse(
            output,
            fallbackURL: fallbackURL,
            fallbackSlug: fallbackSlug
        )
    }

    // Consolidated GraphQL parsing now lives in CrowProvider's GitHubTaskBackend
    // and GitHubCodeBackend (see ADR 0005). The IssueTracker pulls assembled
    // `AssignedListing` / `MonitoredPRListing` from the backends in
    // `runConsolidatedGitHubQuery` above and consumes them directly.

    // MARK: - Session PR Link Detection (piggyback)

    /// Build an index of viewer PRs keyed by `(repoSlug, branch)` and `url`, then
    /// attach PR links to sessions whose primary worktree branch matches.
    private func applySessionPRLinks(viewerPRs: [ViewerPR]) {
        guard !viewerPRs.isEmpty else { return }

        // Prefer OPEN PRs over closed ones when a branch has multiple.
        var byBranch: [String: ViewerPR] = [:]  // key = "repo/slug#branch"
        for pr in viewerPRs {
            let key = "\(pr.repoNameWithOwner)#\(pr.headRefName)"
            if let existing = byBranch[key] {
                if pr.state == "OPEN" && existing.state != "OPEN" {
                    byBranch[key] = pr
                }
            } else {
                byBranch[key] = pr
            }
        }

        // Accumulate new links and persist them in a single store write below.
        // Writing per-session inside the loop meant N full-store encode + atomic
        // disk writes when a burst of PRs got linked at once — the dominant
        // main-thread stall behind the concurrent-review freeze (#304).
        var newLinks: [SessionLink] = []

        for session in appState.sessions {
            guard !session.isManager else { continue }
            let wts = appState.worktrees(for: session.id)
            let links = appState.links(for: session.id)

            guard !links.contains(where: { $0.linkType == .pr }) else { continue }
            guard let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first else { continue }

            let branch = primaryWt.branch
            guard !branch.isEmpty else { continue }

            let repoSlug = resolveRepoSlug(worktree: primaryWt)
            guard !repoSlug.isEmpty else { continue }

            guard let pr = byBranch["\(repoSlug)#\(branch)"] else { continue }

            let link = SessionLink(
                sessionID: session.id,
                label: "PR #\(pr.number)",
                url: pr.url,
                linkType: .pr
            )
            appState.links[session.id, default: []].append(link)
            newLinks.append(link)
        }

        guard !newLinks.isEmpty else { return }
        JSONStore().mutate { data in
            data.links.append(contentsOf: newLinks)
        }
    }

    // MARK: - Session PR Link Reconciliation

    /// A session that the reconcile pass should query a provider for. Built from
    /// non-archived, non-review sessions that have a primary worktree branch
    /// but no `.pr` link yet.
    struct ReconcileCandidate: Sendable, Equatable {
        let sessionID: UUID
        let provider: Provider
        let repoSlug: String       // "radiusmethod/corveil"
        let branch: String
        let gitlabHost: String?    // nil for github.com
    }

    /// A Jira-tasked session whose PR should be found by the *ticket key* it
    /// references (e.g. `MAXX-6859`) rather than by branch. Jira PR branches
    /// are renamed by the working agent and rarely match the session's
    /// registered worktree branch, so branch matching can't find them.
    struct ReconcileKeyCandidate: Sendable, Equatable {
        let sessionID: UUID
        let provider: Provider     // code provider (.github today)
        let repoSlug: String
        let key: String            // "MAXX-6859"
        let gitlabHost: String?
    }

    /// A branch match returned by the provider. `state` follows GitHub's
    /// `PullRequestState` for GitHub and a normalized "OPEN"/"MERGED"/"CLOSED"
    /// for GitLab (mapping `opened|merged|closed`). `updatedAt` drives
    /// tie-breaking when a branch has multiple non-OPEN PRs.
    struct ReconcileBranchMatch: Sendable, Equatable {
        let sessionID: UUID
        let number: Int
        let url: String
        let state: String
        let updatedAt: Date?
    }

    /// Given a set of matches per session, decide which link to create for
    /// each session. Prefers OPEN over non-OPEN; falls back to most-recent
    /// `updatedAt`. Deterministic when timestamps are absent (highest `number`
    /// wins as a stable tie-breaker). Pure — no appState, no I/O.
    nonisolated static func decideReconcileLinks(
        matches: [ReconcileBranchMatch]
    ) -> [ReconcileBranchMatch] {
        let bySession = Dictionary(grouping: matches, by: { $0.sessionID })
        var picks: [ReconcileBranchMatch] = []
        for (_, group) in bySession {
            guard let pick = group.max(by: { lhs, rhs in
                // Returns true when lhs should sort BEFORE rhs (i.e. rhs wins).
                let lhsOpen = lhs.state == "OPEN"
                let rhsOpen = rhs.state == "OPEN"
                if lhsOpen != rhsOpen { return !lhsOpen }  // rhs open → rhs wins
                switch (lhs.updatedAt, rhs.updatedAt) {
                case let (l?, r?):
                    if l != r { return l < r }  // newer wins
                case (nil, _?):
                    return true                  // rhs has date → rhs wins
                case (_?, nil):
                    return false                 // lhs has date → lhs wins
                case (nil, nil):
                    break
                }
                return lhs.number < rhs.number   // tie-break on number
            }) else { continue }
            picks.append(pick)
        }
        return picks
    }

    /// Enforce that a single PR attaches to at most one work item. Groups the
    /// final per-session picks by PR URL; if a URL is claimed by sessions with
    /// more than one distinct work-item identity (ticket key, else branch), the
    /// PR can't be attributed to one of them with confidence, so it is dropped
    /// from all of them — never guess (#520). Duplicate sessions sharing one
    /// identity (same key/branch) keep the link. Pure — no appState, no I/O.
    nonisolated static func dedupeContestedPRs(
        _ picks: [ReconcileBranchMatch],
        identityBySession: [UUID: String]
    ) -> [ReconcileBranchMatch] {
        let byURL = Dictionary(grouping: picks, by: { $0.url })
        var out: [ReconcileBranchMatch] = []
        for (_, group) in byURL {
            let identities = Set(group.compactMap { identityBySession[$0.sessionID] })
            if identities.count > 1 { continue }   // contested across tickets → none
            out.append(contentsOf: group)
        }
        return out
    }

    /// Route a reconcile candidate to a *code* backend. A task-only provider
    /// (`.jira`/`.corveil`) has no code surface, so a session tracked by one
    /// resolves PRs through its `codeProvider` — mirroring the
    /// `codeProvider ?? provider` convention in `SessionService.findPRLink` and
    /// `AutoRespondCoordinator`. Falls back to host sniffing when no
    /// code-bearing provider is recorded (e.g. sessions predating the field).
    /// Pure — no appState, no I/O.
    nonisolated static func resolveReconcileProvider(
        codeProvider: Provider?, provider: Provider?, host: String
    ) -> (provider: Provider, gitlabHost: String?) {
        if let p = codeProvider ?? provider, !p.isTaskOnly {
            return (p, p == .gitlab ? (host.isEmpty ? nil : host) : nil)
        }
        if host == "github.com" || host.isEmpty { return (.github, nil) }
        return (.gitlab, host)
    }

    /// Whether `session` may add the `crow:merge` label to its PR — i.e. its
    /// **code** backend declares `.autoMergeLabel`. Resolves the code provider
    /// via the `codeProvider ?? provider ?? .github` convention (ADR 0005) so a
    /// Jira/Corveil-tasked GitHub-code session is gated on GitHub, not on its
    /// task provider (CROW-532). Pure — easily unit-tested.
    nonisolated static func canAddMergeLabel(session: Session, providerManager: ProviderManager) -> Bool {
        let provider = session.codeProvider ?? session.provider ?? .github
        return providerManager.codeBackend(for: provider)?.capabilities.contains(.autoMergeLabel) ?? false
    }

    /// For each non-archived, non-review session missing a `.pr` link with a
    /// resolvable (repoSlug, branch), query the provider directly and upsert
    /// a link when a PR exists on that branch. Runs once per refresh cycle
    /// after the reactive `applySessionPRLinks` pass.
    private func reconcileMissingPRLinks() async {
        let candidates = buildReconcileCandidates()
        let keyCandidates = buildReconcileKeyCandidates()
        guard !candidates.isEmpty || !keyCandidates.isEmpty else { return }

        var matches: [ReconcileBranchMatch] = []

        let github = candidates.filter { $0.provider == .github }
        if !github.isEmpty, let hits = await fetchPRsForReconcile(candidates: github) {
            matches.append(contentsOf: hits)
        }

        let gitlab = candidates.filter { $0.provider == .gitlab }
        let hostsSeen = Set(gitlab.compactMap { $0.gitlabHost })
        for host in hostsSeen {
            let forHost = gitlab.filter { $0.gitlabHost == host }
            matches.append(contentsOf: await fetchGitLabMRsForReconcile(candidates: forHost, host: host))
        }

        // Jira-tasked sessions: find the PR by the ticket key it references,
        // since the PR branch won't match the worktree branch. Feeds the same
        // `decideReconcileLinks` so a key-found and branch-found PR for one
        // session resolve to a single best pick.
        matches.append(contentsOf: await fetchPRsByKeyForReconcile(candidates: keyCandidates))

        // Each session's work-item identity (key preferred, else branch) so the
        // de-dup pass can tell a legitimate duplicate-session match from one PR
        // being claimed by two different tickets.
        var identityBySession: [UUID: String] = [:]
        for c in candidates { identityBySession[c.sessionID] = c.branch }
        for c in keyCandidates { identityBySession[c.sessionID] = c.key }

        let decided = Self.decideReconcileLinks(matches: matches)
        applyReconciledPRLinks(Self.dedupeContestedPRs(decided, identityBySession: identityBySession))
    }

    /// Walk appState and build the set of sessions needing a reconcile pass.
    /// Runs on MainActor; safe to read appState directly.
    private func buildReconcileCandidates() -> [ReconcileCandidate] {
        var out: [ReconcileCandidate] = []
        for session in appState.sessions {
            guard !session.isManager else { continue }
            guard session.status != .archived else { continue }
            guard session.kind == .work else { continue }  // review sessions get PR links at creation
            let links = appState.links(for: session.id)
            guard !links.contains(where: { $0.linkType == .pr }) else { continue }

            let wts = appState.worktrees(for: session.id)
            guard let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first else { continue }
            guard !primaryWt.branch.isEmpty else { continue }

            let info = resolveRepoInfo(worktree: primaryWt)
            guard !info.slug.isEmpty else { continue }

            // Route by the *code* provider: a Jira/Corveil task-only session
            // codes against GitHub/GitLab via `codeProvider`, so resolving on
            // `session.provider` alone (→ `.jira`) would drop the candidate.
            // Falls back to host sniffing when no code-bearing provider exists.
            let (provider, gitlabHost) = Self.resolveReconcileProvider(
                codeProvider: session.codeProvider,
                provider: session.provider,
                host: info.host
            )

            // GitLab candidates require a known host — GITLAB_HOST env var is
            // how the glab wrapper picks an auth token. Skip silently rather
            // than fall through to a wrong-host call.
            if provider == .gitlab, gitlabHost == nil { continue }

            out.append(ReconcileCandidate(
                sessionID: session.id,
                provider: provider,
                repoSlug: info.slug,
                branch: primaryWt.branch,
                gitlabHost: gitlabHost
            ))
        }
        return out
    }

    /// Build key-based reconcile candidates: Jira-tasked sessions missing a PR
    /// link, whose PR is discoverable by the ticket key (e.g. `MAXX-6859`)
    /// rather than by branch. Gated on a Jira ticket URL so GitHub/GitLab-tasked
    /// sessions are untouched (they keep pure branch matching). Runs on
    /// MainActor; safe to read appState directly.
    private func buildReconcileKeyCandidates() -> [ReconcileKeyCandidate] {
        var out: [ReconcileKeyCandidate] = []
        for session in appState.sessions {
            guard !session.isManager else { continue }
            guard session.status != .archived else { continue }
            guard session.kind == .work else { continue }
            let links = appState.links(for: session.id)
            guard !links.contains(where: { $0.linkType == .pr }) else { continue }

            let wts = appState.worktrees(for: session.id)
            guard let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first else { continue }

            // Resolve the ticket key: prefer a Jira ticket URL, else derive it
            // from the worktree branch (e.g. `feature/max-monorepo-maxx-7035-…`
            // → `MAXX-7035`). The branch fallback covers the prefix-drop case
            // where the PR head loses the repo prefix the worktree carries (#520).
            //
            // The branch fallback is gated to task-only trackers (Jira/Corveil):
            // a lowercased branch can't distinguish a real Jira project ("maxx")
            // from an ordinary word/repo segment ("api"), so a GitHub/GitLab
            // issue branch like `feature/acme-api-197-fix` would yield a bogus
            // "API-197" key. Those sessions resolve via the branch path instead.
            let urlKey = session.ticketURL.flatMap {
                Validation.isJiraSpec($0) ? Validation.jiraKey(from: $0) : nil
            }
            let branchKey = (session.provider?.isTaskOnly == true)
                ? Validation.ticketKey(fromBranch: primaryWt.branch) : nil
            guard let key = urlKey ?? branchKey else { continue }

            let info = resolveRepoInfo(worktree: primaryWt)
            guard !info.slug.isEmpty else { continue }

            let (provider, gitlabHost) = Self.resolveReconcileProvider(
                codeProvider: session.codeProvider,
                provider: session.provider,
                host: info.host
            )
            if provider == .gitlab, gitlabHost == nil { continue }

            out.append(ReconcileKeyCandidate(
                sessionID: session.id,
                provider: provider,
                repoSlug: info.slug,
                key: key,
                gitlabHost: gitlabHost
            ))
        }
        return out
    }

    /// Resolve PR links for Jira-tasked sessions by searching the code repo for
    /// the ticket key. GitHub only today (the `CodeBackend` default returns no
    /// matches for providers without text PR search). Best-effort: a backend
    /// error skips the cycle rather than dropping links.
    private func fetchPRsByKeyForReconcile(candidates: [ReconcileKeyCandidate]) async -> [ReconcileBranchMatch] {
        let github = candidates.filter { $0.provider == .github }
        guard !github.isEmpty, let backend = providerManager.codeBackend(for: .github) else { return [] }
        do {
            let matches = try await backend.findPRsMatchingKeys(Self.dedupedKeyCandidates(github))
            return Self.fanOutKeyMatches(matches, across: github)
        } catch {
            handleGitHubBackendError(error, operation: "findPRsMatchingKeys(github)")
            return []
        }
    }

    /// Project `ReconcileKeyCandidate`s onto de-duplicated `(repoSlug, key)`
    /// pairs for the backend. Mirrors `dedupedBranchCandidates`.
    nonisolated static func dedupedKeyCandidates(_ candidates: [ReconcileKeyCandidate]) -> [KeyCandidate] {
        var seen: Set<KeyCandidate> = []
        var out: [KeyCandidate] = []
        for c in candidates {
            let kc = KeyCandidate(repoSlug: c.repoSlug, key: c.key)
            if seen.insert(kc).inserted { out.append(kc) }
        }
        return out
    }

    /// Fan each `KeyPRMatch` back to every session sharing its `(repoSlug, key)`.
    /// Mirrors `fanOutMatches` for the branch path.
    nonisolated static func fanOutKeyMatches(
        _ matches: [KeyPRMatch],
        across candidates: [ReconcileKeyCandidate]
    ) -> [ReconcileBranchMatch] {
        var sessionsByKey: [KeyCandidate: [UUID]] = [:]
        for c in candidates {
            sessionsByKey[KeyCandidate(repoSlug: c.repoSlug, key: c.key), default: []].append(c.sessionID)
        }
        var out: [ReconcileBranchMatch] = []
        for match in matches {
            guard let sids = sessionsByKey[match.candidate] else { continue }
            for sid in sids {
                out.append(ReconcileBranchMatch(
                    sessionID: sid,
                    number: match.number,
                    url: match.url,
                    state: match.state,
                    updatedAt: match.updatedAt
                ))
            }
        }
        return out
    }

    /// One batched call per backend: GitHub issues a single aliased GraphQL
    /// query covering every candidate; GitLab issues one REST call per
    /// (host, candidate) tuple. Returns `nil` on backend error so the
    /// reconcile pass can skip the cycle without treating a degraded
    /// response as "no PRs found".
    private func fetchPRsForReconcile(candidates: [ReconcileCandidate]) async -> [ReconcileBranchMatch]? {
        guard !candidates.isEmpty else { return [] }
        let backend = providerManager.codeBackend(for: .github)!
        do {
            let matches = try await backend.findRecentPRsForBranches(
                Self.dedupedBranchCandidates(candidates)
            )
            return Self.fanOutMatches(matches, across: candidates)
        } catch {
            handleGitHubBackendError(error, operation: "findRecentPRsForBranches(github)")
            return nil
        }
    }

    /// GitLab equivalent: route through the GitLab `CodeBackend` for the given host.
    private func fetchGitLabMRsForReconcile(
        candidates: [ReconcileCandidate],
        host: String
    ) async -> [ReconcileBranchMatch] {
        guard !candidates.isEmpty else { return [] }
        let backend = providerManager.codeBackend(for: .gitlab, host: host)!
        do {
            let matches = try await backend.findRecentPRsForBranches(
                Self.dedupedBranchCandidates(candidates)
            )
            return Self.fanOutMatches(matches, across: candidates)
        } catch {
            print("[IssueTracker] Reconcile via backend failed for host \(host): \(error.localizedDescription.prefix(200))")
            return []
        }
    }

    /// Project `ReconcileCandidate`s onto the de-duplicated `(repoSlug, branch)`
    /// pairs the backend needs. Two sessions on the same branch (a duplicated
    /// session, or reconcile firing before the first session's PR link lands)
    /// produce a single backend query — we fan the matches back out per
    /// session in `fanOutMatches`.
    nonisolated static func dedupedBranchCandidates(_ candidates: [ReconcileCandidate]) -> [BranchCandidate] {
        var seen: Set<BranchCandidate> = []
        var out: [BranchCandidate] = []
        for c in candidates {
            let bc = BranchCandidate(repoSlug: c.repoSlug, branch: c.branch)
            if seen.insert(bc).inserted { out.append(bc) }
        }
        return out
    }

    /// Each backend `BranchPRMatch` is duplicated for every `ReconcileCandidate`
    /// that shares its `(repoSlug, branch)`. This preserves the prior
    /// per-session sessionID-threading even when two sessions point at the
    /// same branch — collapsing them via `Dictionary(uniqueKeysWithValues:)`
    /// would either trap or silently drop one session's PR link.
    nonisolated static func fanOutMatches(
        _ matches: [BranchPRMatch],
        across candidates: [ReconcileCandidate]
    ) -> [ReconcileBranchMatch] {
        // Group sessions by their (repoSlug, branch) so a single match maps
        // to every session that owns that key.
        var sessionsByBranch: [BranchCandidate: [UUID]] = [:]
        for c in candidates {
            let bc = BranchCandidate(repoSlug: c.repoSlug, branch: c.branch)
            sessionsByBranch[bc, default: []].append(c.sessionID)
        }
        var out: [ReconcileBranchMatch] = []
        for match in matches {
            guard let sids = sessionsByBranch[match.candidate] else { continue }
            for sid in sids {
                out.append(ReconcileBranchMatch(
                    sessionID: sid,
                    number: match.number,
                    url: match.url,
                    state: match.state,
                    updatedAt: match.updatedAt
                ))
            }
        }
        return out
    }

    /// Persist the reconciliation decisions. Re-checks `appState.links` at
    /// write time so a concurrent `applySessionPRLinks` or hand-added PR link
    /// (identified by URL match) wins without leaving a duplicate row.
    private func applyReconciledPRLinks(_ picks: [ReconcileBranchMatch]) {
        guard !picks.isEmpty else { return }
        // Accumulate then persist once — see `applySessionPRLinks` (#304).
        var newLinks: [SessionLink] = []
        for pick in picks {
            let existing = appState.links(for: pick.sessionID)
            if existing.contains(where: { $0.linkType == .pr || $0.url == pick.url }) { continue }
            let link = SessionLink(
                sessionID: pick.sessionID,
                label: "PR #\(pick.number)",
                url: pick.url,
                linkType: .pr
            )
            appState.links[pick.sessionID, default: []].append(link)
            newLinks.append(link)
        }

        guard !newLinks.isEmpty else { return }
        JSONStore().mutate { data in
            data.links.append(contentsOf: newLinks)
        }
    }

    /// Resolve the org/repo slug (e.g. "radiusmethod/citadel") from a worktree's git remote.
    private func resolveRepoSlug(worktree: SessionWorktree) -> String {
        return resolveRepoInfo(worktree: worktree).slug
    }

    /// Info derived from a worktree's git remote URL: org/repo slug and (for
    /// GitLab) the host name. Host is empty for github.com remotes.
    struct RepoInfo: Sendable, Equatable {
        let slug: String
        let host: String
    }

    private func resolveRepoInfo(worktree: SessionWorktree) -> RepoInfo {
        if let output = try? shellSync(
            "git", "-C", worktree.repoPath, "remote", "get-url", "origin"
        ) {
            var url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
            let host = Self.extractHost(fromRemote: url)
            let slug = Self.extractSlug(fromRemote: url)
            if !slug.isEmpty {
                return RepoInfo(slug: slug, host: host)
            }
        }
        if worktree.repoName.contains("/") {
            return RepoInfo(slug: worktree.repoName, host: "")
        }
        return RepoInfo(slug: "", host: "")
    }

    /// Extract the host ("github.com", "gitlab.example.com") from a git remote URL.
    /// Handles both SSH (`git@host:org/repo`) and HTTPS (`https://host/org/repo`).
    /// Returns "" when the URL can't be parsed.
    nonisolated static func extractHost(fromRemote url: String) -> String {
        // SSH: git@host:org/repo
        if let range = url.range(of: #"^[^@]+@([^:]+):"#, options: .regularExpression) {
            let match = String(url[range])
            if let at = match.firstIndex(of: "@"), let colon = match.lastIndex(of: ":") {
                return String(match[match.index(after: at)..<colon])
            }
        }
        // HTTPS: https://host/...
        if let range = url.range(of: #"^https?://([^/]+)/"#, options: .regularExpression) {
            let match = String(url[range])
            let trimmed = match
                .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ""
    }

    /// Extract the project slug ("org/repo", "group/sub/repo", ...) from a git
    /// remote URL. Handles both SSH (`git@host:path`) and HTTPS
    /// (`https://host/path`), and preserves nested-group paths so that GitLab
    /// projects under nested groups (e.g.
    /// `big-bang/product/packages/elasticsearch-kibana`) keep their full path.
    /// Strips a trailing `.git` if present. Returns "" when the URL can't be
    /// parsed.
    nonisolated static func extractSlug(fromRemote url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }

        // SSH: git@host:org/repo or user@host:group/sub/repo
        if let range = trimmed.range(of: #"^[^@/\s]+@[^:/\s]+:"#, options: .regularExpression) {
            let path = String(trimmed[range.upperBound...])
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // HTTPS: https://host/org/repo
        if let range = trimmed.range(of: #"^https?://[^/]+/"#, options: .regularExpression) {
            let path = String(trimmed[range.upperBound...])
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ""
    }

    /// Parse the `owner/repo` (or `group/sub/repo`) slug from a PR/MR *web* URL
    /// such as `https://github.com/owner/repo/pull/123` or
    /// `https://gitlab.com/group/sub/repo/-/merge_requests/12`. Returns the path
    /// segments before the `pull` / `merge_requests` / `-` marker, or "" when the
    /// URL can't be parsed. Distinct from `extractSlug(fromRemote:)`, which
    /// parses git *remote* URLs (no `/pull/...` suffix).
    nonisolated static func repoSlug(fromPRURL url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"^https?://[^/]+/"#, options: .regularExpression) else {
            return ""
        }
        let path = String(trimmed[range.upperBound...])
        var segments: [String] = []
        for segment in path.split(separator: "/").map(String.init) {
            if segment == "pull" || segment == "merge_requests" || segment == "-" { break }
            segments.append(segment)
        }
        return segments.joined(separator: "/")
    }

    private func shellSync(_ args: String...) throws -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = args.joined(separator: " ")
            let desc = "`\(cmd)` exited \(process.terminationStatus)"
                + (stderr.isEmpty ? "" : ": \(stderr)")
            throw NSError(
                domain: "IssueTracker",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: desc]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    // MARK: - PR Status (piggyback)

    /// Build `PRStatus` for each session with a `.pr` link by looking up the PR
    /// in the viewer-PR payload. No extra gh calls. Emits two kinds of
    /// transitions:
    /// - `.checksFailing`: still edge-detected from `previousPRStatus` so a
    ///   new failing commit only fires once per head.
    /// - `.changesRequested`: stateless `PRStatus.needsRefine` rule (CROW-508).
    ///   Compares the latest CHANGES_REQUESTED review timestamp against the
    ///   latest substantive (non-merge, non-rebase) commit timestamp; emits
    ///   when the review is newer, gated by managed-terminal-idle, the
    ///   `respondToChangesRequested` user setting, the first-observation
    ///   skip (a PR's first poll never dispatches), and a per-PR cooldown.
    func applyPRStatuses(viewerPRs: [ViewerPR]) {
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        var transitions: [PRStatusTransition] = []
        let now = Date()
        let respondToChangesRequested = respondToChangesRequestedProvider()
        // Snapshot `seenPRs` BEFORE the loop so the first-observation skip
        // is consistent for every session this poll, regardless of order.
        // Two sessions linked to the same PR URL: if we read live state,
        // session A inserts and session B sees the URL already-seen and
        // dispatches on the very first poll. With the snapshot, both
        // sessions see "not seen yet" → both skip, then we record the
        // URL once. Cooldown still bounds it either way, but the snapshot
        // matches the documented "first poll for a PR never dispatches"
        // behavior precisely. (PR #509 review.)
        let seenPRsAtStart = seenPRs
        let sessionsWithPRs = appState.sessions.filter { !$0.isManager }
        // Collect live PR URLs as we go so we can drop stale entries at the
        // end of the pass. Without this, deleting a session (or its `.pr`
        // link) leaves its PR URL in `seenPRs`/`lastRefineDispatchAt`/
        // `lastNotifiedChangesRequestedAt` for the rest of the process —
        // bounded but not strictly clean.
        var livePRURLs: Set<String> = []
        for session in sessionsWithPRs {
            let links = appState.links(for: session.id)
            guard let prLink = links.first(where: { $0.linkType == .pr }) else { continue }
            guard let pr = byURL[prLink.url] else { continue }
            livePRURLs.insert(prLink.url)

            let newStatus = buildPRStatus(from: pr)
            let oldStatus = previousPRStatus[session.id]

            // Checks-failing edge: fire only when transitioning from
            // non-failing to failing. `transitions(from:to:…)` returns at
            // most one `.checksFailing` and handles the `old == nil` first-
            // observation case (only fires if `new` is itself failing).
            transitions.append(contentsOf: PRStatus.transitions(
                from: oldStatus,
                to: newStatus,
                sessionID: session.id,
                prURL: prLink.url,
                prNumber: pr.number
            ))

            // Stateless "needs refine" rule (CROW-508). First-observation
            // skip uses the start-of-poll snapshot so two sessions sharing
            // a PR can't race each other through the gate.
            if respondToChangesRequested,
               session.kind != .review,
               seenPRsAtStart.contains(prLink.url),
               PRStatus.needsRefine(
                   status: newStatus,
                   terminalIdle: isManagedTerminalIdle(sessionID: session.id)
               ),
               cooldownElapsed(prURL: prLink.url, now: now) {
                lastRefineDispatchAt[prLink.url] = now
                // Same-review cooldown re-fire suppresses the macOS
                // notification (the dispatch + agent prompt are still
                // valuable; the banner duplicates info the user already
                // saw). A new reviewer submission advances
                // `lastChangesRequestedAt`, flipping the flag back off so
                // the next dispatch notifies.
                let isCooldownReFire = lastNotifiedChangesRequestedAt[prLink.url] == newStatus.lastChangesRequestedAt
                if !isCooldownReFire {
                    lastNotifiedChangesRequestedAt[prLink.url] = newStatus.lastChangesRequestedAt
                }
                transitions.append(PRStatusTransition(
                    kind: .changesRequested,
                    sessionID: session.id,
                    prURL: prLink.url,
                    prNumber: pr.number,
                    headSha: newStatus.headSha,
                    failedCheckNames: [],
                    isCooldownReFire: isCooldownReFire
                ))
                NSLog("[IssueTracker] needs-refine fired — session=%@, sha=%@, lastCR=%@, lastCommit=%@, reFire=%@",
                      session.id.uuidString as NSString,
                      (newStatus.headSha ?? "") as NSString,
                      Self.iso(newStatus.lastChangesRequestedAt) as NSString,
                      Self.iso(newStatus.lastSubstantiveCommitAt) as NSString,
                      (isCooldownReFire ? "yes" : "no") as NSString)
            }
            seenPRs.insert(prLink.url)

            previousPRStatus[session.id] = newStatus
            appState.prStatus[session.id] = newStatus
        }

        // Prune ephemeral state for PRs no longer linked to any live
        // session. Cheap (Set intersection / dictionary filter) and keeps
        // the maps bounded by current PR count rather than lifetime
        // process activity.
        if !seenPRs.isEmpty { seenPRs.formIntersection(livePRURLs) }
        lastRefineDispatchAt = lastRefineDispatchAt.filter { livePRURLs.contains($0.key) }
        lastNotifiedChangesRequestedAt = lastNotifiedChangesRequestedAt.filter { livePRURLs.contains($0.key) }

        if !transitions.isEmpty {
            onPRStatusTransitions?(transitions)
        }

        applyAutoMerge(viewerPRs: viewerPRs)
        applyAutoRebase(viewerPRs: viewerPRs)
    }

    /// True when the managed terminal for the session is at agent-launched
    /// readiness with the agent available to accept a prompt — either
    /// `.idle` (fresh, never run) or `.done` (finished a top-level task and
    /// waiting). `.working` and `.waiting` still gate: firing into a busy
    /// or blocked agent would interrupt it. A pre-launch terminal also
    /// gates, because the agent never had a chance to run.
    private func isManagedTerminalIdle(sessionID: UUID) -> Bool {
        guard let managedTerminal = appState.terminals(for: sessionID).first(where: { $0.isManaged }) else {
            return false
        }
        guard appState.terminalReadiness[managedTerminal.id] == .agentLaunched else { return false }
        let state = appState.hookState(for: sessionID).activityState
        return state == .idle || state == .done
    }

    /// True when no prior dispatch is recorded for this PR or the cooldown
    /// has elapsed since the last one. Driven by `needsRefineCooldown`.
    private func cooldownElapsed(prURL: String, now: Date) -> Bool {
        guard let last = lastRefineDispatchAt[prURL] else { return true }
        return now.timeIntervalSince(last) >= Self.needsRefineCooldown
    }

    /// ISO-8601 timestamp string for logging, or "-" for nil.
    nonisolated static func iso(_ date: Date?) -> String {
        guard let date else { return "-" }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    // MARK: - Auto-Merge Watcher (CROW-299)

    /// Pattern matching a Crow-Session commit trailer line. Anchored to
    /// line start (multiline) so trailing footers are required, not just
    /// anywhere in the body. The captured group is the UUID string.
    /// `nonisolated` because it's consumed from the `nonisolated static`
    /// extraction helper (which is in turn called by unit tests).
    nonisolated private static let crowSessionTrailerPattern = #"^Crow-Session:\s*([0-9A-Fa-f-]{36})\s*$"#

    /// Extract every Crow-Session UUID from a commit message. Returns an
    /// empty array when no trailers match. Pure for testability. Compiles
    /// the regex per call — NSRegularExpression isn't trivially Sendable
    /// across `nonisolated` boundaries in Swift 6, and the cost is
    /// negligible (only called on PRs entering the auto-merge flow).
    nonisolated static func extractCrowSessionUUIDs(from message: String) -> [UUID] {
        guard let regex = try? NSRegularExpression(
            pattern: crowSessionTrailerPattern,
            options: [.anchorsMatchLines]
        ) else { return [] }
        let range = NSRange(message.startIndex..., in: message)
        var result: [UUID] = []
        regex.enumerateMatches(in: message, range: range) { match, _, _ in
            guard let m = match,
                  let uuidRange = Range(m.range(at: 1), in: message),
                  let uuid = UUID(uuidString: String(message[uuidRange])) else { return }
            result.append(uuid)
        }
        return result
    }

    /// Decide whether `pr` (paired with `session`) is a candidate for
    /// `gh pr merge --auto`. Pure so unit tests can exercise every guard
    /// without spinning up an `IssueTracker`. Returns `false` when:
    /// - the session has already had auto-merge enabled (one-shot guard)
    /// - the PR is not OPEN, or is a draft
    /// - the `crow:merge` label is absent
    /// - the PR is in CONFLICTING or CHANGES_REQUESTED state
    nonisolated static func shouldAttemptAutoMerge(pr: ViewerPR, session: Session) -> Bool {
        guard session.autoMergeEnabledAt == nil else { return false }
        guard pr.state == "OPEN" else { return false }
        guard !pr.isDraft else { return false }
        guard pr.labels.contains(where: { $0.name.caseInsensitiveCompare(autoMergeLabel) == .orderedSame }) else { return false }
        guard pr.mergeable != "CONFLICTING" else { return false }
        guard pr.reviewDecision != "CHANGES_REQUESTED" else { return false }
        return true
    }

    /// Decide whether a merge candidate should have its branch updated from
    /// base *before* merging. True only when the PR is otherwise mergeable
    /// (`shouldAttemptAutoMerge`) but GitHub reports it `BEHIND` its base —
    /// the "out-of-date with the base branch" state that makes `gh pr merge`
    /// fail with HTTP 422. Real conflicts never qualify: `CONFLICTING` is
    /// already gated by `shouldAttemptAutoMerge`, and `DIRTY` is not `BEHIND`.
    nonisolated static func shouldUpdateBranchBeforeMerge(pr: ViewerPR, session: Session) -> Bool {
        guard shouldAttemptAutoMerge(pr: pr, session: session) else { return false }
        return pr.mergeStateStatus == "BEHIND"
    }

    /// Return true when at least one of the supplied commit messages
    /// carries a `Crow-Session: <uuid>` trailer whose UUID matches a
    /// session in `knownSessionIDs`. Trailer-with-unknown-session is
    /// treated as NOT Crow-authored (acceptance criterion #4).
    nonisolated static func crowAuthored(commitMessages: [String], knownSessionIDs: Set<UUID>) -> Bool {
        for message in commitMessages {
            for uuid in extractCrowSessionUUIDs(from: message) {
                if knownSessionIDs.contains(uuid) { return true }
            }
        }
        return false
    }

    /// Per-refresh entry point. Picks candidate (session, PR) pairs and
    /// kicks off the async enable flow once each. No-op when the global
    /// `autoMergeWatcherEnabled` setting is off.
    private func applyAutoMerge(viewerPRs: [ViewerPR]) {
        guard autoMergeWatcherEnabledProvider() else { return }
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        for session in appState.sessions where !session.isManager {
            guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else { continue }
            guard !autoMergeInFlight.contains(prLink.url) else { continue }
            guard let pr = byURL[prLink.url] else { continue }
            guard Self.shouldAttemptAutoMerge(pr: pr, session: session) else { continue }

            let capturedSession = session
            if Self.shouldUpdateBranchBeforeMerge(pr: pr, session: session) {
                // Behind base: bring the branch up to date this turn instead
                // of merging. One attempt per head commit (loop safety); the
                // next poll re-evaluates once GitHub recomputes mergeability.
                let key = "\(prLink.url)\n\(pr.headRefOid)"
                guard !autoUpdateBranchAttempted.contains(key) else { continue }
                autoUpdateBranchAttempted.insert(key)
                autoMergeInFlight.insert(prLink.url)
                Task { await self.attemptUpdateBranch(session: capturedSession, pr: pr) }
            } else {
                autoMergeInFlight.insert(prLink.url)
                Task { await self.attemptEnableAutoMerge(session: capturedSession, pr: pr) }
            }
        }
    }

    /// Resolve the `CodeBackend` for a session's PR/merge actions, following the
    /// `codeProvider ?? provider ?? .github` convention (ADR 0005) so a
    /// Jira/Corveil-tasked GitHub-code session routes to GitHub rather than its
    /// task provider (CROW-532). `nil` only for a task-only resolution with no
    /// code surface — callers must bow out.
    private func codeBackend(for session: Session) -> CodeBackend? {
        providerManager.codeBackend(for: session.codeProvider ?? session.provider ?? .github)
    }

    /// Verify Crow authorship, lazily ensure the label exists, then enable
    /// auto-merge with squash + delete branch. Idempotent: success persists
    /// `Session.autoMergeEnabledAt`; failure clears the in-flight marker so
    /// the next poll retries.
    private func attemptEnableAutoMerge(session: Session, pr: ViewerPR) async {
        guard let backend = codeBackend(for: session) else {
            autoMergeInFlight.remove(pr.url)
            return
        }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            NSLog("[Crow] crow:merge ignored on %@ — no Crow-Session trailer matching a known session",
                  pr.url as NSString)
            return
        }

        await ensureMergeLabel(repo: pr.repoNameWithOwner, backend: backend)

        guard backend.capabilities.contains(.autoMerge) else {
            // Capability gate: don't even try if the backend can't enable auto-merge.
            autoMergeInFlight.remove(pr.url)
            return
        }
        do {
            try await backend.enableAutoMerge(prURL: pr.url)
            let now = Date()
            if let idx = appState.sessions.firstIndex(where: { $0.id == session.id }) {
                appState.sessions[idx].autoMergeEnabledAt = now
                appState.sessions[idx].updatedAt = now
            }
            JSONStore().mutate { data in
                if let idx = data.sessions.firstIndex(where: { $0.id == session.id }) {
                    data.sessions[idx].autoMergeEnabledAt = now
                    data.sessions[idx].updatedAt = now
                }
            }
            NSLog("[Crow] Auto-merge enabled on %@ (session %@, squash)",
                  pr.url as NSString, session.id.uuidString as NSString)
            onAutoMergeEnabled?(session.id, pr.url, pr.number)
        } catch {
            autoMergeInFlight.remove(pr.url)
            NSLog("[Crow] enableAutoMerge failed for %@: %@",
                  pr.url as NSString, error.localizedDescription as NSString)
        }
    }

    /// Bring a `BEHIND` PR up to date by merging the latest base into its
    /// branch (`gh pr update-branch`, i.e. the GitHub "Update branch" button),
    /// then bow out — the merge itself happens on a later poll once GitHub has
    /// recomputed mergeability and checks have re-run. Deliberately does NOT
    /// persist `Session.autoMergeEnabledAt`: an update must not burn the
    /// one-shot merge guard. The same Crow-authorship check as the merge path
    /// applies. The per-head `autoUpdateBranchAttempted` key (set by the
    /// caller) is left in place so a failed/no-op update isn't retried until
    /// the head commit changes.
    private func attemptUpdateBranch(session: Session, pr: ViewerPR) async {
        guard let backend = codeBackend(for: session) else { return }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            NSLog("[Crow] crow:merge update-branch skipped on %@ — no Crow-Session trailer matching a known session",
                  pr.url as NSString)
            return
        }

        defer { autoMergeInFlight.remove(pr.url) }
        guard backend.capabilities.contains(.updateBranch) else { return }
        do {
            try await backend.updateBranch(prURL: pr.url)
            NSLog("[Crow] Updated branch for %@ (session %@, was BEHIND base)",
                  pr.url as NSString, session.id.uuidString as NSString)
        } catch {
            NSLog("[Crow] updateBranch failed for %@: %@",
                  pr.url as NSString, error.localizedDescription as NSString)
        }
    }

    /// Fetch the PR's commits and return true iff at least one carries a
    /// `Crow-Session: <uuid>` trailer matching a known session.
    private func prHasCrowAuthoredCommit(pr: ViewerPR, backend: CodeBackend) async -> Bool {
        let commits: [CommitInfo]
        do {
            commits = try await backend.fetchCrowAuthoredCommits(
                prURL: pr.url,
                repoSlug: pr.repoNameWithOwner,
                prNumber: pr.number
            )
        } catch {
            NSLog("[Crow] fetchCrowAuthoredCommits failed for %@: %@",
                  pr.url as NSString, error.localizedDescription as NSString)
            return false
        }
        let messages = commits.map(\.message)
        let knownIDs = Set(appState.sessions.map(\.id))
        return Self.crowAuthored(commitMessages: messages, knownSessionIDs: knownIDs)
    }

    /// Best-effort: ensure the `crow:merge` label exists in the repo so
    /// repo owners don't need to pre-create it. The backend swallows the
    /// "already exists" failure.
    private func ensureMergeLabel(repo: String, backend: CodeBackend) async {
        guard !repo.isEmpty else { return }
        guard backend.capabilities.contains(.autoMergeLabel) else { return }
        do {
            try await backend.ensureMergeLabel(repo: repo)
        } catch {
            // Best-effort — swallow.
        }
    }

    // MARK: - Auto-Rebase Watcher (CROW-318)

    /// Decide whether `pr` is a candidate for auto-rebase. Pure so unit tests
    /// can exercise it without an `IssueTracker`. Unlike `shouldAttemptAutoMerge`
    /// there is **no label requirement** and review state is irrelevant — a
    /// rebase doesn't need approval. Returns true when the PR is OPEN, not a
    /// draft, and either BEHIND its base or CONFLICTING. Crow-authorship and
    /// per-head loop-safety are enforced by the caller.
    nonisolated static func shouldAttemptAutoRebase(pr: ViewerPR) -> Bool {
        guard pr.state == "OPEN" else { return false }
        guard !pr.isDraft else { return false }
        return pr.mergeStateStatus == "BEHIND" || pr.mergeable == "CONFLICTING"
    }

    /// Whether a session may be considered by the auto-rebase watcher at all.
    /// Pure so unit tests can exercise it without an `IssueTracker`. The
    /// Manager session never owns a PR branch, and review sessions exist to
    /// review someone else's PR — never rewrite the branch under review,
    /// regardless of the toggle (same policy as
    /// `AutoRespondCoordinator.shouldSkipReviewSession`, CROW-551).
    nonisolated static func sessionEligibleForAutoRebase(_ session: Session) -> Bool {
        session.id != AppState.managerSessionID && session.kind != .review
    }

    /// Per-refresh entry point for the auto-rebase watcher. Picks candidate
    /// (session, PR) pairs and kicks off one rebase attempt per head commit.
    /// No-op when `autoRespond.autoRebaseAndResolveConflicts` is off.
    private func applyAutoRebase(viewerPRs: [ViewerPR]) {
        guard autoRebaseAndResolveConflictsProvider() else { return }
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        for session in appState.sessions where Self.sessionEligibleForAutoRebase(session) {
            guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else { continue }
            guard !autoRebaseInFlight.contains(prLink.url) else { continue }
            guard let pr = byURL[prLink.url] else { continue }
            guard Self.shouldAttemptAutoRebase(pr: pr) else { continue }

            // Precedence: when auto-merge is also enabled and this PR is a
            // crow:merge BEHIND candidate, let auto-merge's `gh pr update-branch`
            // own bringing it up to date so the two watchers don't fight over
            // the same branch. Auto-rebase still owns every CONFLICTING PR and
            // every BEHIND PR that isn't a crow:merge merge candidate.
            if autoMergeWatcherEnabledProvider(),
               Self.shouldUpdateBranchBeforeMerge(pr: pr, session: session) {
                continue
            }

            let key = "\(prLink.url)\n\(pr.headRefOid)"
            guard !autoRebaseAttempted.contains(key) else { continue }
            autoRebaseAttempted.insert(key)
            autoRebaseInFlight.insert(prLink.url)
            let capturedSession = session
            Task { await self.attemptRebase(session: capturedSession, pr: pr) }
        }
    }

    /// Whether a `.failed` rebase should be retried on the next poll given how
    /// many consecutive failures this head state has already seen. Pure so the
    /// retry policy is unit-testable without an `IssueTracker`.
    nonisolated static func shouldRetryFailedRebase(failureCount: Int) -> Bool {
        failureCount < maxAutoRebaseFailureRetries
    }

    /// Locate the session's primary worktree, verify Crow authorship, then
    /// rebase it onto base and force-push. On conflicts, fire
    /// `onAutoRebaseConflicts` so the caller hands resolution to Claude.
    /// Transient outcomes (dirty tree, out-of-sync branch, bounded failures)
    /// un-set the per-head key so the next poll retries.
    private func attemptRebase(session: Session, pr: ViewerPR) async {
        let headKey = "\(pr.url)\n\(pr.headRefOid)"
        defer { autoRebaseInFlight.remove(pr.url) }

        // Cheap local checks first — a completed/archived session may still
        // carry an open `.pr` link with no worktree to rebase into, and unlike
        // auto-merge there's no label gate, so avoid spending a backend call
        // (Crow-authorship) before discovering there's nothing to do.
        let worktrees = appState.worktrees(for: session.id)
        guard let primary = worktrees.first(where: { $0.isPrimary }) ?? worktrees.first,
              !primary.isMainRepoCheckout,
              primary.branch == pr.headRefName else {
            NSLog("[Crow] auto-rebase skipped on %@ — no usable worktree or branch mismatch (expected %@)",
                  pr.url as NSString, pr.headRefName as NSString)
            return
        }

        guard let backend = codeBackend(for: session) else { return }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            NSLog("[Crow] auto-rebase skipped on %@ — no Crow-Session trailer matching a known session",
                  pr.url as NSString)
            return
        }

        let outcome = await gitManager.rebaseOntoBase(
            worktreePath: primary.worktreePath,
            branch: primary.branch,
            baseBranch: pr.baseRefName
        )
        switch outcome {
        case .rebasedAndPushed:
            autoRebaseFailureCounts[headKey] = nil
            let priorState = pr.mergeable == "CONFLICTING" ? "CONFLICTING" : "BEHIND"
            NSLog("[Crow] Auto-rebased & force-pushed %@ (session %@, was %@)",
                  pr.url as NSString, session.id.uuidString as NSString, priorState as NSString)
            onAutoRebasePushed?(session.id, pr.url, pr.number)
        case .conflicts:
            autoRebaseFailureCounts[headKey] = nil
            NSLog("[Crow] Auto-rebase hit conflicts on %@ (session %@) — delegating to Claude",
                  pr.url as NSString, session.id.uuidString as NSString)
            onAutoRebaseConflicts?(session.id, pr.url, pr.number)
        case .dirtyWorktree:
            // Transient (a Claude session is mid-edit). Re-arm so the next
            // poll retries once the tree is clean.
            autoRebaseFailureCounts[headKey] = nil
            autoRebaseAttempted.remove(headKey)
            NSLog("[Crow] Auto-rebase deferred on %@ — worktree has uncommitted changes",
                  pr.url as NSString)
        case .outOfSyncWithRemote:
            // Transient: local branch has unpushed commits or is stale relative
            // to the remote. Re-arm so the next poll retries once it's in sync.
            autoRebaseFailureCounts[headKey] = nil
            autoRebaseAttempted.remove(headKey)
            NSLog("[Crow] Auto-rebase deferred on %@ — local branch not in sync with origin",
                  pr.url as NSString)
        case .failed(let msg):
            // Transient git failures (fetch flake, rejected lease, unreachable
            // base) shouldn't silently stall the watcher until the head commit
            // changes. Retry a bounded number of times, then give up for this
            // head state to avoid hot-looping on a broken config.
            let failures = (autoRebaseFailureCounts[headKey] ?? 0) + 1
            autoRebaseFailureCounts[headKey] = failures
            if Self.shouldRetryFailedRebase(failureCount: failures) {
                autoRebaseAttempted.remove(headKey)
                NSLog("[Crow] Auto-rebase failed on %@ (attempt %d/%d, will retry): %@",
                      pr.url as NSString, failures, Self.maxAutoRebaseFailureRetries, msg as NSString)
            } else {
                NSLog("[Crow] Auto-rebase failed on %@ (attempt %d/%d, giving up until head changes): %@",
                      pr.url as NSString, failures, Self.maxAutoRebaseFailureRetries, msg as NSString)
            }
        }
    }

    private func buildPRStatus(from pr: ViewerPR) -> PRStatus {
        // Checks
        let checksPass: PRStatus.CheckStatus
        var failedChecks: [String] = []
        switch pr.checksState {
        case "SUCCESS":
            checksPass = .passing
        case "FAILURE", "ERROR":
            checksPass = .failing
            failedChecks = pr.failedCheckNames
        case "PENDING", "EXPECTED":
            checksPass = .pending
        default:
            checksPass = .unknown
        }

        // Reviews — prefer reviewDecision (branch protection); fall back to latestReviews
        var reviewStatus: PRStatus.ReviewStatus
        switch pr.reviewDecision {
        case "APPROVED": reviewStatus = .approved
        case "CHANGES_REQUESTED": reviewStatus = .changesRequested
        case "REVIEW_REQUIRED": reviewStatus = .reviewRequired
        case "": reviewStatus = .reviewRequired
        default: reviewStatus = .unknown
        }
        if reviewStatus == .reviewRequired || reviewStatus == .unknown, !pr.latestReviewStates.isEmpty {
            if pr.latestReviewStates.contains("CHANGES_REQUESTED") {
                reviewStatus = .changesRequested
            } else if pr.latestReviewStates.contains("APPROVED") {
                reviewStatus = .approved
            }
        }

        // Merge — PR state first (MERGED set by the stale-PR follow-up query),
        // then fall back to mergeable for OPEN PRs.
        let mergeStatus: PRStatus.MergeStatus
        if pr.state == "MERGED" {
            mergeStatus = .merged
        } else {
            switch pr.mergeable {
            case "MERGEABLE": mergeStatus = .mergeable
            case "CONFLICTING": mergeStatus = .conflicting
            default: mergeStatus = .unknown
            }
        }

        return PRStatus(
            checksPass: checksPass,
            reviewStatus: reviewStatus,
            mergeable: mergeStatus,
            failedCheckNames: failedChecks,
            headSha: pr.headRefOid.isEmpty ? nil : pr.headRefOid,
            isOpen: pr.state == "OPEN",
            lastChangesRequestedAt: pr.lastChangesRequestedAt,
            lastSubstantiveCommitAt: pr.lastSubstantiveCommitAt
        )
    }

    // MARK: - Auto-Complete (piggyback)

    /// Sync active sessions whose linked ticket has "In Review" project status to .inReview session status.
    private func syncInReviewSessions(issues: [AssignedIssue]) {
        let inReviewURLs = Set(issues.filter { $0.projectStatus == .inReview }.map(\.url))

        for session in appState.activeSessions {
            guard let ticketURL = session.ticketURL else { continue }
            if inReviewURLs.contains(ticketURL) {
                print("[IssueTracker] Session '\(session.name)' — ticket is In Review on project board, updating session status")
                appState.onSetSessionInReview?(session.id)
            }
        }
    }

    /// Decision returned by `decideSessionCompletions` — carries both the
    /// session to complete and a short reason used in the log line emitted
    /// by the adapter.
    struct CompletionDecision: Equatable {
        let sessionID: UUID
        let reason: String
    }

    /// Result of a completion-decision pass. `floorGuardTriggered` is `true`
    /// when the decider refused to complete anything because the fetched
    /// open-issue set was empty while candidate sessions had ticket URLs —
    /// a strong indicator that the underlying GraphQL response was partial
    /// or errored. Surfaced so the adapter can log a warning and tests can
    /// assert the guard fired.
    struct CompletionResult: Equatable {
        let completions: [CompletionDecision]
        let floorGuardTriggered: Bool
    }

    /// Decide which candidate sessions should be auto-completed based on
    /// the current refresh payload. Requires positive evidence of closure:
    /// a PR-linked session needs its PR in `prsByURL` with state `MERGED`
    /// or `CLOSED`; an issue-only session needs its ticket URL in
    /// `closedIssueURLs`. Missing-from-open is no longer sufficient.
    ///
    /// `prDataComplete` is `false` when the stale-PR follow-up errored
    /// (rate-limited, non-zero exit, parse failure). In that case, PR-linked
    /// completions are skipped entirely to avoid completing on stale data.
    nonisolated static func decideSessionCompletions(
        candidateSessions: [Session],
        linksBySessionID: [UUID: [SessionLink]],
        openIssueURLs: Set<String>,
        closedIssueURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        prDataComplete: Bool
    ) -> CompletionResult {
        let withTickets = candidateSessions.filter { $0.ticketURL != nil }

        // Floor guard: if we have candidates but openIssueURLs is empty, the
        // consolidated query likely returned partial data. Skip this cycle.
        // This is belt-and-suspenders — the positive-evidence rules below
        // already refuse to complete without a MERGED/CLOSED PR or a
        // closedIssueURLs hit — but the guard catches future regressions
        // that reintroduce an absence-based path.
        if !withTickets.isEmpty && openIssueURLs.isEmpty {
            return CompletionResult(completions: [], floorGuardTriggered: true)
        }

        var decisions: [CompletionDecision] = []
        for session in withTickets {
            guard let ticketURL = session.ticketURL else { continue }
            if openIssueURLs.contains(ticketURL) { continue }

            let sessionLinks = linksBySessionID[session.id] ?? []
            if let prLink = sessionLinks.first(where: { $0.linkType == .pr }) {
                guard prDataComplete else { continue }
                guard let pr = prsByURL[prLink.url] else { continue }
                switch pr.state {
                case "MERGED":
                    decisions.append(CompletionDecision(sessionID: session.id, reason: "PR merged"))
                case "CLOSED":
                    decisions.append(CompletionDecision(sessionID: session.id, reason: "PR closed"))
                default:
                    break
                }
                continue
            }

            if session.provider == .github || session.provider == nil {
                if closedIssueURLs.contains(ticketURL) {
                    decisions.append(CompletionDecision(sessionID: session.id, reason: "issue closed"))
                }
            }
        }
        return CompletionResult(completions: decisions, floorGuardTriggered: false)
    }

    /// Decide which review sessions should be auto-completed. Three rules:
    ///   1. Viewer has submitted a formal review (APPROVED / CHANGES_REQUESTED
    ///      / DISMISSED) at a time strictly after `session.createdAt`. This
    ///      closes the round so that an author's subsequent `/refine` +
    ///      re-request lands as a fresh review request with no linked
    ///      session, letting the kickoff guard re-fire (CROW-290).
    ///   2. PR is MERGED — terminal state, always complete.
    ///   3. PR is CLOSED — terminal state, always complete.
    /// Rules 2 + 3 require the PR to be present in `prsByURL` with the
    /// matching state and `prDataComplete == true` so the old "missing
    /// from open review queue == done" rule isn't reintroduced under
    /// partial fetches. Rule 1 only needs the `ReviewRequest` payload (the
    /// PR is still open at this point so it's always present in `reviewRequestsByPRURL`).
    nonisolated static func decideReviewCompletions(
        reviewSessions: [Session],
        linksBySessionID: [UUID: [SessionLink]],
        openReviewPRURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        reviewRequestsByPRURL: [String: ReviewRequest],
        prDataComplete: Bool
    ) -> [CompletionDecision] {
        var decisions: [CompletionDecision] = []
        for session in reviewSessions {
            let sessionLinks = linksBySessionID[session.id] ?? []
            guard let prLink = sessionLinks.first(where: { $0.linkType == .pr }) else { continue }

            // Rule 1: viewer-submitted review after the session was created.
            if let request = reviewRequestsByPRURL[prLink.url],
               let reviewedAt = request.viewerLastReviewedAt,
               reviewedAt > session.createdAt {
                decisions.append(CompletionDecision(sessionID: session.id, reason: "viewer submitted review"))
                continue
            }

            // Rules 2 + 3 — terminal PR states. Require complete data.
            guard prDataComplete else { continue }
            if openReviewPRURLs.contains(prLink.url) { continue }
            guard let pr = prsByURL[prLink.url] else { continue }
            switch pr.state {
            case "MERGED":
                decisions.append(CompletionDecision(sessionID: session.id, reason: "PR merged"))
            case "CLOSED":
                decisions.append(CompletionDecision(sessionID: session.id, reason: "PR closed"))
            default:
                break
            }
        }
        return decisions
    }

    /// Check active sessions whose linked ticket is no longer in the open
    /// issues list. Delegates to `decideSessionCompletions` so the decision
    /// logic is covered by unit tests without a shell/Process abstraction.
    private func autoCompleteFinishedSessions(
        openIssues: [AssignedIssue],
        closedIssueURLs: Set<String>,
        viewerPRs: [ViewerPR],
        prDataComplete: Bool
    ) {
        let openIssueURLs = Set(openIssues.map(\.url))
        let prsByURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        let candidateSessions = appState.sessions.filter {
            !$0.isManager &&
            ($0.status == .active || $0.status == .paused || $0.status == .inReview)
        }
        var linksBySessionID: [UUID: [SessionLink]] = [:]
        for session in candidateSessions {
            linksBySessionID[session.id] = appState.links(for: session.id)
        }

        let result = Self.decideSessionCompletions(
            candidateSessions: candidateSessions,
            linksBySessionID: linksBySessionID,
            openIssueURLs: openIssueURLs,
            closedIssueURLs: closedIssueURLs,
            prsByURL: prsByURL,
            prDataComplete: prDataComplete
        )

        if result.floorGuardTriggered {
            let count = candidateSessions.filter { $0.ticketURL != nil }.count
            print("[IssueTracker] skipping auto-complete — openIssues empty with \(count) candidate sessions (likely partial fetch)")
            return
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: candidateSessions.map { ($0.id, $0) })
        for decision in result.completions {
            let name = sessionsByID[decision.sessionID]?.name ?? decision.sessionID.uuidString
            print("[IssueTracker] Session '\(name)' — \(decision.reason), marking completed")
            appState.onCompleteSession?(decision.sessionID)
        }
    }

    /// Auto-complete review sessions whose PR has been merged or closed.
    /// Delegates to `decideReviewCompletions` for testability.
    private func autoCompleteFinishedReviews(
        openReviewPRURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        reviewRequestsByPRURL: [String: ReviewRequest],
        prDataComplete: Bool
    ) {
        let activeReviews = appState.sessions.filter { $0.kind == .review && $0.status == .active }
        var linksBySessionID: [UUID: [SessionLink]] = [:]
        for session in activeReviews {
            linksBySessionID[session.id] = appState.links(for: session.id)
        }

        let decisions = Self.decideReviewCompletions(
            reviewSessions: activeReviews,
            linksBySessionID: linksBySessionID,
            openReviewPRURLs: openReviewPRURLs,
            prsByURL: prsByURL,
            reviewRequestsByPRURL: reviewRequestsByPRURL,
            prDataComplete: prDataComplete
        )

        let sessionsByID = Dictionary(uniqueKeysWithValues: activeReviews.map { ($0.id, $0) })
        for decision in decisions {
            let name = sessionsByID[decision.sessionID]?.name ?? decision.sessionID.uuidString
            print("[IssueTracker] Review session '\(name)' — \(decision.reason), marking completed")
            appState.onCompleteSession?(decision.sessionID)
        }
    }

    // MARK: - Auto-Cleanup

    /// Protected session IDs that must never be deleted by auto-cleanup.
    /// Includes the manager session and all fixed-UUID virtual tab sessions.
    nonisolated static let protectedSessionIDs: Set<UUID> = [
        AppState.managerSessionID,
        AppState.ticketBoardSessionID,
        AppState.allowListSessionID,
        AppState.reviewBoardSessionID,
    ]

    /// Pure decision function: returns session IDs eligible for auto-cleanup.
    /// A session is eligible when its status is `.completed` or `.archived`,
    /// its `updatedAt` is older than the retention cutoff, and its ID is not
    /// in the protected set.
    nonisolated static func sessionsEligibleForCleanup(
        sessions: [Session],
        retentionHours: Int,
        now: Date = Date()
    ) -> [UUID] {
        let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
        return sessions.compactMap { session in
            guard !protectedSessionIDs.contains(session.id) else { return nil }
            guard !session.isManager else { return nil }
            guard session.status == .completed || session.status == .archived else { return nil }
            guard session.updatedAt < cutoff else { return nil }
            return session.id
        }
    }

    /// Delete completed/archived sessions that have exceeded their retention
    /// window. Errors are logged per-session by the `onDeleteSession` callback
    /// and do not abort subsequent deletions.
    private func autoCleanupExpiredSessions(config: AppConfig) async {
        guard config.cleanup.enabled else { return }

        let eligible = Self.sessionsEligibleForCleanup(
            sessions: appState.sessions,
            retentionHours: config.cleanup.retentionHours
        )
        guard !eligible.isEmpty else { return }

        let sessionsByID = Dictionary(uniqueKeysWithValues: appState.sessions.map { ($0.id, $0) })
        for sessionID in eligible {
            let name = sessionsByID[sessionID]?.name ?? sessionID.uuidString
            print("[IssueTracker] Auto-cleanup: deleting session '\(name)' (retention: \(config.cleanup.retentionHours)h)")
            await onDeleteSession?(sessionID)
        }
    }

    // MARK: - GitLab

    private func fetchGitLabIssues(host: String) async -> [AssignedIssue] {
        let backend = providerManager.taskBackend(for: .gitlab, host: host)
        do {
            // Pass includeClosed: false so we don't fire a wasted closed-issues
            // REST call every 60s — only the open list is consumed by refresh()
            // for the GitLab path (the closed-diff logic is GitHub-only today).
            let listing = try await backend.listAssigned(includeClosed: false)
            return listing.open
        } catch {
            print("[IssueTracker] fetchGitLabIssues(host: \(host)) failed: \(error)")
            return []
        }
    }

    /// Fetch open Jira work items assigned to the user for one workspace config.
    /// Best-effort (the backend itself degrades to empty on failure), mirroring
    /// the GitLab path — `includeClosed: false` skips the wasted closed query
    /// since refresh()'s closed-issue diff is GitHub-only today.
    /// Find the configured Jira workspace whose project key (then exact site host,
    /// then sole-candidate fallback) matches `ticketURL`. Shared by the status-map
    /// and full-config resolvers so the matching can never drift. `candidates`
    /// lets callers pre-filter (e.g. to workspaces that define a status map).
    private static func matchJiraWorkspace(_ candidates: [WorkspaceInfo], forTicket ticketURL: String) -> WorkspaceInfo? {
        guard !candidates.isEmpty else { return nil }
        // Prefer a project-key match (the ticket key's project, e.g. PROPS-12 → PROPS).
        if let project = Validation.parseJiraKey(ticketURL)?.project,
           let ws = candidates.first(where: { $0.jiraProjectKey?.uppercased() == project.uppercased() }) {
            return ws
        }
        // Then an exact site-host match (acli is authed to a single site). Compare
        // parsed hosts, not a loose substring, so "acme.atlassian.net" doesn't
        // match a "dev.acme.atlassian.net" workspace (or vice versa).
        if let ticketHost = URL(string: ticketURL)?.host,
           let ws = candidates.first(where: { ws in
               guard let site = ws.jiraSite, !site.isEmpty else { return false }
               let siteHost = URL(string: site.hasPrefix("http") ? site : "https://\(site)")?.host ?? site
               return siteHost.caseInsensitiveCompare(ticketHost) == .orderedSame
           }) {
            return ws
        }
        // Single candidate → unambiguous; use it.
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Resolve the per-workspace Crow→Jira status-name map (#523) for a ticket.
    /// Returns `nil` when no workspace defines a map, so `JiraTaskBackend` falls
    /// back to its built-in defaults.
    private static func jiraStatusMap(forTicket ticketURL: String) -> [String: String]? {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return nil }
        let candidates = config.workspaces.filter {
            $0.derivedTaskProvider == "jira" && !($0.jiraStatusMap?.isEmpty ?? true)
        }
        return matchJiraWorkspace(candidates, forTicket: ticketURL)?.jiraStatusMap
    }

    /// Build the full ``JiraConfig`` for a ticket: the matching workspace's site /
    /// project / JQL / status-map (#523) plus the resolved Jira Cloud REST
    /// `Authorization` header (#529) so `setTaskStatus`/`closeTask` transition via
    /// REST rather than `acli`. The credential is the org-wide `jiraCredential`
    /// username + API token (HTTP Basic, #528), the same one the Settings status
    /// picker uses; nil when unconfigured, leaving the backend on its `acli`
    /// fallback.
    static func jiraConfig(forTicket ticketURL: String) -> JiraConfig {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return JiraConfig() }
        let candidates = config.workspaces.filter { $0.derivedTaskProvider == "jira" }
        let ws = matchJiraWorkspace(candidates, forTicket: ticketURL)
        let authorization = config.jiraCredential.flatMap { JiraCredentialResolver.resolve($0) }
        return JiraConfig(
            site: ws?.jiraSite,
            projectKey: ws?.jiraProjectKey,
            jql: ws?.jiraJQL,
            statusMap: ws?.jiraStatusMap,
            authorization: authorization
        )
    }

    /// Fetch assigned Jira issues for one workspace config, including the
    /// recently-Done half (#536) so tickets in their mapped Done status surface
    /// in the board's Done section. Best-effort: degrades to an empty listing on
    /// failure, mirroring the GitLab / Corveil paths.
    private func fetchJiraIssues(config: JiraConfig) async -> AssignedListing {
        let backend = providerManager.taskBackend(for: .jira, jira: config)
        do {
            return try await backend.listAssigned(includeClosed: true)
        } catch {
            print("[IssueTracker] fetchJiraIssues(project: \(config.projectKey ?? "—")) failed: \(error)")
            return AssignedListing(open: [], closed: [])
        }
    }

    /// Merge a Jira `AssignedListing` into the board's flat issue list: open
    /// issues plus the closed (Done) issues deduped by `id` against the open
    /// set, mirroring the GitHub closed-issue merge. `doneCount` is the full
    /// closed count (the 24h Done window), matching GitHub's `doneIssuesLast24h`
    /// semantics — it counts the window, not just the post-dedup remainder.
    nonisolated static func mergeJiraListing(_ listing: AssignedListing) -> (issues: [AssignedIssue], doneCount: Int) {
        let openIDs = Set(listing.open.map(\.id))
        let uniqueDone = listing.closed.filter { !openIDs.contains($0.id) }
        return (listing.open + uniqueDone, listing.closed.count)
    }

    /// Fetch open Corveil tasks assigned to the user for one workspace config.
    /// Best-effort (the backend itself degrades to empty on failure), mirroring
    /// the GitLab / Jira paths.
    private func fetchCorveilIssues(config: CorveilConfig) async -> [AssignedIssue] {
        let backend = providerManager.taskBackend(for: .corveil, corveil: config)
        do {
            let listing = try await backend.listAssigned(includeClosed: false)
            return listing.open
        } catch {
            print("[IssueTracker] fetchCorveilIssues(host: \(config.host ?? "—")) failed: \(error)")
            return []
        }
    }

    // MARK: - Mark In Review

    func markInReview(sessionID: UUID) async {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let ticketURL = session.ticketURL,
              let taskProvider = session.provider else { return }

        // For Jira, thread the matching workspace's per-project status-name map
        // (#523) so the transition honors a renamed workflow ("In Progress" →
        // "In Development"); other providers ignore the JiraConfig.
        let jiraConfig: JiraConfig? = (taskProvider == .jira)
            ? Self.jiraConfig(forTicket: ticketURL)
            : nil
        let backend = providerManager.taskBackend(for: taskProvider, jira: jiraConfig)
        // Capability-gated across providers: GitHub Projects v2 and Jira workflow
        // transitions both expose `.projectBoardStatus` and implement
        // `setTaskStatus`. GitLab (no capability) returns early.
        guard backend.capabilities.contains(.projectBoardStatus) else { return }

        appState.isMarkingInReview[sessionID] = true
        defer { appState.isMarkingInReview[sessionID] = false }

        do {
            try await backend.setTaskStatus(url: ticketURL, status: .inReview)
        } catch ProviderError.insufficientScope {
            reportScopeWarning("project")
            return
        } catch ProviderError.unimplemented(let msg) {
            print("[IssueTracker] markInReview: \(msg)")
            return
        } catch {
            print("[IssueTracker] markInReview failed for \(ticketURL): \(error.localizedDescription.prefix(200))")
            return
        }

        // Update local state — match by URL so it works regardless of provider.
        if let idx = appState.assignedIssues.firstIndex(where: { $0.url == ticketURL }) {
            appState.assignedIssues[idx].projectStatus = .inReview
        }

        print("[IssueTracker] Marked \(ticketURL) as In Review")

        // Update local session status to .inReview
        appState.onSetSessionInReview?(sessionID)
    }

    // MARK: - Mark Issue Done

    /// Move a session's linked issue to its done/closed state on the provider
    /// (GitHub/GitLab close the issue; Jira/Corveil transition to the mapped
    /// completed status), then flip the Crow session to `.completed`. Best-effort:
    /// auth / transition-not-allowed / already-closed failures are logged and
    /// swallowed (no crash). Mirrors `markInReview`'s in-flight/error handling.
    func markIssueDone(sessionID: UUID) async {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let ticketURL = session.ticketURL,
              let taskProvider = session.provider else { return }

        // For Jira, thread the matching workspace's per-project status-name map
        // (#523) so the transition targets a renamed "Done" workflow status. For
        // every other provider, resolve provider + host straight from the URL so
        // GitLab/Corveil self-hosted instances are targeted correctly.
        let backend: TaskBackend
        if taskProvider == .jira {
            backend = providerManager.taskBackend(for: .jira, jira: Self.jiraConfig(forTicket: ticketURL))
        } else {
            backend = providerManager.taskBackend(forURL: ticketURL)
        }

        appState.isMarkingIssueDone[sessionID] = true
        defer { appState.isMarkingIssueDone[sessionID] = false }

        do {
            try await backend.closeTask(url: ticketURL)
        } catch ProviderError.unimplemented(let msg) {
            print("[IssueTracker] markIssueDone: \(msg)")
            return
        } catch {
            print("[IssueTracker] markIssueDone failed for \(ticketURL): \(error.localizedDescription.prefix(200))")
            return
        }

        // Reflect locally — match by URL so it works regardless of provider.
        if let idx = appState.assignedIssues.firstIndex(where: { $0.url == ticketURL }) {
            appState.assignedIssues[idx].projectStatus = .done
        }

        print("[IssueTracker] Marked issue done: \(ticketURL)")

        // Flip the Crow session to .completed so the row reflects the closed issue.
        appState.onCompleteSession?(sessionID)
    }

    // MARK: - Transition ticket (session start, resync)

    /// Transition a session's linked ticket to an explicit pipeline `status`,
    /// honoring the per-workspace `jiraStatusMap` for Jira (#523/#529). This is the
    /// app-side entry point for the **session-start → In Progress** transition
    /// that `setup.sh` delegates here via `crow transition-ticket` — `setup.sh`
    /// only owns the GitHub Projects-v2 mutation, so a Jira session never moved
    /// off Backlog before. Capability-gated (`.projectBoardStatus`), so GitLab
    /// (no board status) is a no-op. Best-effort: auth / unavailable-transition
    /// failures are logged and swallowed, mirroring `markInReview`.
    func transitionTicket(sessionID: UUID, to status: TicketStatus) async {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let ticketURL = session.ticketURL,
              let taskProvider = session.provider else { return }

        let backend: TaskBackend
        if taskProvider == .jira {
            backend = providerManager.taskBackend(for: .jira, jira: Self.jiraConfig(forTicket: ticketURL))
        } else {
            backend = providerManager.taskBackend(forURL: ticketURL)
        }
        guard backend.capabilities.contains(.projectBoardStatus) else { return }

        do {
            try await backend.setTaskStatus(url: ticketURL, status: status)
        } catch {
            print("[IssueTracker] transitionTicket(\(status.rawValue)) failed for \(ticketURL): \(error.localizedDescription.prefix(200))")
            return
        }

        if let idx = appState.assignedIssues.firstIndex(where: { $0.url == ticketURL }) {
            appState.assignedIssues[idx].projectStatus = status
        }
        print("[IssueTracker] Transitioned \(ticketURL) to \(status.rawValue)")
    }

    /// One-shot remediation (#529): walk every Jira-backed session and transition
    /// its ticket to the status implied by the Crow session state — fixing tickets
    /// left in Backlog because session-start never transitioned them. Each move
    /// goes through the same graceful-degrade REST path, so tickets already in the
    /// right status (or lacking a valid transition) are no-ops. Returns the number
    /// of sessions it attempted. Drives `crow resync-jira`.
    @discardableResult
    func resyncJira() async -> Int {
        let targets: [(id: UUID, status: TicketStatus)] = appState.sessions.compactMap { session in
            guard session.provider == .jira, session.ticketURL != nil else { return nil }
            let status: TicketStatus
            switch session.status {
            case .inReview: status = .inReview
            case .completed, .archived: status = .done
            case .active, .paused: status = .inProgress
            }
            return (session.id, status)
        }
        for target in targets {
            await transitionTicket(sessionID: target.id, to: target.status)
        }
        print("[IssueTracker] resyncJira: attempted \(targets.count) Jira session(s)")
        return targets.count
    }

    /// Add the `crow:merge` auto-merge label to a session's PR, ensuring the
    /// label exists in the repo first. Capability-gated on `.autoMergeLabel`
    /// (GitHub only today). Mirrors `markInReview`'s in-flight/error handling.
    func addMergeLabel(sessionID: UUID) async {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let prLink = appState.links(for: sessionID).first(where: { $0.linkType == .pr }),
              let backend = codeBackend(for: session),
              backend.capabilities.contains(.autoMergeLabel) else { return }

        appState.isAddingMergeLabel[sessionID] = true
        defer { appState.isAddingMergeLabel[sessionID] = false }

        let repo = Self.repoSlug(fromPRURL: prLink.url)
        guard !repo.isEmpty else {
            // Without a repo slug we can't `ensureMergeLabel`, and the bare
            // `gh pr edit --add-label` would fail if the label doesn't already
            // exist. Bail loudly rather than silently half-doing the action.
            print("[IssueTracker] addMergeLabel: could not parse repo slug from \(prLink.url)")
            return
        }
        do {
            try await backend.ensureMergeLabel(repo: repo)
            try await backend.addMergeLabel(prURL: prLink.url)
            NSLog("[Crow] Added crow:merge to %@", prLink.url as NSString)
        } catch {
            print("[IssueTracker] addMergeLabel failed for \(prLink.url): \(error.localizedDescription.prefix(200))")
        }
    }
}
