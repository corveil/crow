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
public final class IssueTracker {
    let appState: AppState
    let providerManager: ProviderManager
    /// Shared store instance (injected by AppDelegate). PR attributions MUST
    /// be written through the same `JSONStore` that `SessionService` mutates
    /// — an ad-hoc `JSONStore()` write would be clobbered by the next
    /// mutation of the shared instance's older in-memory snapshot. Every
    /// attribution write is followed by `syncPRAttributionMirror()` so the
    /// read-only `appState.prAttributions` mirror (the v2 combined score's
    /// input, #699) stays current.
    let store: JSONStore
    private var timer: Timer?
    private let pollInterval: TimeInterval = 60 // 1 minute
    private var isRefreshing = false

    /// Local alias for the canonical `PRRecord` shape now living in
    /// `CrowProvider`. The migration kept the name in place to minimize the
    /// IssueTracker diff — every `ViewerPR` in this file is a `PRRecord`.
    typealias ViewerPR = PRRecord

    /// Callback for new review request notifications (set by AppDelegate).
    public var onNewReviewRequests: (([ReviewRequest]) -> Void)?

    /// Fires when a newly assigned issue carries the auto-create label and
    /// has no existing session. Wired in AppDelegate to dispatch the
    /// work-on-issue flow and post a notification.
    public var onAutoCreateRequest: ((AssignedIssue) -> Void)?

    /// Callback fired on every successful review-request refresh with the full
    /// post-cross-reference snapshot (including the first fetch). Used by the
    /// auto-review opt-in path so requests already pending at app launch
    /// trigger a session, not just newly-arrived ones.
    public var onReviewRequestsRefreshed: (([ReviewRequest]) -> Void)?

    /// Callback fired immediately after `appState.isLoadingIssues` flips, in
    /// both directions. Lets a client-facing UI be nudged at the moment the
    /// flag is observable, rather than guessing around `refresh()` from the
    /// outside: a nudge issued *before* `refresh()` races the flag being set,
    /// and fires spuriously when the rate-limit guard skips the poll
    /// (CROW-771). Fires only on a real transition, so a skipped poll is
    /// silent.
    public var onLoadingIssuesChanged: (() -> Void)?

    /// Callback for detected PR status transitions — fires once per
    /// transition, after dedupe. Wired in AppDelegate to drive notifications
    /// and the auto-respond coordinator.
    public var onPRStatusTransitions: (([PRStatusTransition]) -> Void)?

    /// Callback fired to delete a session during auto-cleanup.
    /// Wired in AppDelegate to call `appState.onDeleteSession`.
    public var onDeleteSession: ((UUID) async -> Void)?

    /// Reads the latest `AppConfig.autoMergeWatcherEnabled` snapshot on
    /// every poll. Closure rather than direct AppConfig binding so toggling
    /// the setting in Settings takes effect on the next refresh without
    /// re-initializing the tracker. Defaults to a closure that returns
    /// `false` so the watcher is inert until AppDelegate wires it (CROW-299).
    public var autoMergeWatcherEnabledProvider: () -> Bool = { false }

    /// Reads the latest `AppConfig.autoCreateWatcherEnabled` snapshot on
    /// every poll. Closure-based so toggling the setting in Settings takes
    /// effect on the next refresh without re-initializing the tracker.
    /// Defaults to `false` so the `crow:auto`-label automation is inert
    /// until AppDelegate wires it (CROW-312).
    public var autoCreateWatcherEnabledProvider: () -> Bool = { false }

    /// Fires after Crow has successfully enabled GitHub native auto-merge
    /// on a PR. Wired in AppDelegate to post the user-facing notification.
    /// (The durable audit-log line is `NSLog`'d at the call site so it
    /// lands in Console regardless of notification settings.)
    public var onAutoMergeEnabled: ((UUID, String, Int) -> Void)?

    /// Fires the first time Crow concludes it will NOT merge a `crow:merge` PR
    /// for a reason a human has to fix. The counterpart to `onAutoMergeEnabled`
    /// — and the more important of the two, because a permanent skip latches:
    /// there is no later poll that will notice it again, so this callback and
    /// the automation log are the only channels that ever mention it (#888).
    /// Fires at most once per (PR, reason); see `autoMergeBlockNotified`.
    public var onAutoMergeBlocked: ((UUID, String, Int, AutoMergeState) -> Void)?

    /// Reads the latest `AutoRespondSettings.autoRebaseAndResolveConflicts`
    /// snapshot on every poll. Closure (not a stored value) so toggling the
    /// setting takes effect on the next refresh. Defaults to a closure
    /// returning `false` so the watcher is inert until AppDelegate wires it
    /// (CROW-318, moved into AutoRespondSettings by CROW-551).
    public var autoRebaseAndResolveConflictsProvider: () -> Bool = { false }

    /// Reads the latest `AutoRespondSettings.respondToChangesRequested`
    /// snapshot on every poll. Gates the stateless "needs refine" emission
    /// (CROW-508) — when the user has opted out, we suppress both the
    /// notification and the dispatch, so they don't see fresh "Changes
    /// Requested" banners every cooldown window. Defaults to a closure
    /// returning `false` so the path stays inert until AppDelegate wires it.
    public var respondToChangesRequestedProvider: () -> Bool = { false }

    /// Reads the latest `AutoRespondSettings.autoReRequestReview` snapshot on
    /// every poll. Gates the auto-re-request watcher (CROW-921). Defaults to a
    /// closure returning `false` so the watcher is inert until CrowDaemon
    /// wires it — the failure mode that left CROW-782 dark for weeks, and the
    /// reason `wireTrackerAutomations` runs unconditionally.
    public var autoReRequestReviewProvider: () -> Bool = { false }

    /// Fires after Crow rebased a PR branch and force-pushed it. Wired in
    /// AppDelegate to post a notification.
    public var onAutoRebasePushed: ((UUID, String, Int) -> Void)?

    /// Fires when an auto-rebase hit conflicts that need a human/Claude.
    /// Wired in AppDelegate to delegate resolution to the session's Claude
    /// terminal (the `fixConflicts` quick action) and notify.
    public var onAutoRebaseConflicts: ((UUID, String, Int) -> Void)?

    /// Fires when an auto-rebase has deferred often enough that only a human
    /// can unwedge it (#944) — a dirty worktree, or a branch holding commits
    /// `origin` doesn't. The twin of `onAutoMergeBlocked`, and it takes the
    /// state for the same reason: the daemon renders `state.message` verbatim
    /// rather than re-deriving a sentence from the reason token.
    ///
    /// Unlike `onAutoRebaseConflicts` this must **not** hand off to the agent.
    /// There are no conflicts to resolve, and a diverged branch by definition
    /// holds work a `git reset --hard` would destroy.
    public var onAutoRebaseStuck: ((UUID, String, Int, AutoRebaseState) -> Void)?

    /// Runs `git rebase` / force-push for the auto-rebase watcher. Owns its
    /// own instance (no `WorkspaceConfig` needed for path-scoped operations).
    let gitManager = GitManager()

    /// Previously seen review request IDs for delta detection.
    private var previousReviewRequestIDs: Set<String> = []
    private var isFirstFetch = true

    /// Label that triggers the auto-create flow when present on an open
    /// assigned issue. Removed after a successful dispatch (best-effort) so
    /// the trigger is one-shot and visible across machines.
    static let autoCreateLabel = "crow:auto"


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

    /// Last automation line emitted per `(channel, PR URL)`, with its
    /// timestamp (CROW-921). Two callers share it: the gated needs-refine
    /// evaluation and the auto-re-request skip reasons.
    ///
    /// `applyPRStatuses` used to log only when needs-refine *fired*, so a PR
    /// that sat in CHANGES_REQUESTED without ever dispatching left no trace at
    /// all — diagnosing #921 meant pulling `prStatus` out of `crow get-state`
    /// and hand-converting Apple reference-date timestamps. But a line every
    /// poll is ~1440/day/PR, which buries the signal just as effectively. So a
    /// line is emitted when the message *changes* (the interesting event) and
    /// at most hourly otherwise — the same rate-limiting shape
    /// `lastAutoRebaseIdleLogAt` uses. Ephemeral; pruned to live PR URLs.
    var steadyStateLogDedupe: [String: (message: String, at: Date)] = [:]

    /// Re-emit an unchanged steady-state line at most this often.
    nonisolated static let steadyStateLogHeartbeat: TimeInterval = 3600

    /// Channel prefixes for `steadyStateLogDedupe` keys. Two channels can
    /// describe the same PR in one poll and must not evict each other.
    nonisolated static let needsRefineLogChannel = "needs-refine"
    nonisolated static let autoReReviewLogChannel = "auto-re-request"

    nonisolated static func steadyStateLogKey(channel: String, prURL: String) -> String {
        "\(channel)\n\(prURL)"
    }

    /// Sessions whose PR just had `crow:merge` added via `addMergeLabel` but
    /// whose next fetched snapshot may not yet reflect it (#838). Two windows
    /// leave a fresh label temporarily invisible: an in-flight poll that
    /// *started before* the add will overwrite `prStatus` in `applyPRStatuses`
    /// with pre-label data (clearing the optimistic flag), and GitHub's
    /// read-your-write consistency lag. While a session sits here,
    /// `applyPRStatuses` keeps its merge icon lit (ORs `hasMergeLabel`) and
    /// drops the marker the moment a fetched record actually confirms the label
    /// — so the icon never flickers off between the add and the durable
    /// stale-query/union fixes catching up. Ephemeral; pruned to live sessions.
    /// Internal (not private) so `@testable` tests can seed it without driving
    /// a full `addMergeLabel` (which needs a live backend + `gh` call).
    var pendingMergeLabelSessions: Set<UUID> = []

    /// Guards the GitHub-scope console warning so it fires once per session.
    private var didLogGitHubScopeWarning = false

    /// Guards the GitHub-SAML console warning so it fires once per session.
    private var didLogGitHubSAMLWarning = false

    /// When non-nil and in the future, all polls are skipped.
    private var suspendedUntil: Date?

    /// Below this many remaining GraphQL points we proactively skip a cycle.
    private let rateLimitThreshold = 50

    // MARK: - Collaborators (CROW-1094)

    /// PR→session attribution + the #694 rework/revert signals. Extracted from
    /// this file per CROW-1094; `lazy` so it can take an `unowned` back-ref to
    /// this fully-initialized tracker. `refresh()` still drives it in order.
    lazy var attribution = PRAttributionRecorder(owner: self)

    /// Auto-complete + auto-cleanup, and the public review-kickoff decision.
    /// Extracted per CROW-1094; `refresh()` still drives it in order.
    lazy var completion = SessionCompletionController(owner: self)

    /// Session ↔ PR link detection + reconciliation, and the public
    /// session-capability predicates. Extracted per CROW-1094.
    lazy var reconciler = PRLinkReconciler(owner: self)

    /// GitHub/GitLab/Jira board poll, stale-PR follow-up, PR dedup, and the
    /// `crow:auto` dispatch. Extracted per CROW-1094; `refresh()` drives it.
    lazy var boardPoller = BoardPoller(owner: self)

    /// Auto re-request-review watcher (CROW-921). Extracted per CROW-1094;
    /// `applyPRStatuses` drives it each poll.
    lazy var autoReReview = AutoReReviewController(owner: self)

    /// Auto-rebase watcher (CROW-318). Extracted per CROW-1094; `applyPRStatuses`
    /// drives it each poll.
    lazy var autoRebase = AutoRebaseController(owner: self)

    /// Auto-merge watcher (CROW-299) and the shared codeBackend /
    /// prHasCrowAuthoredCommit helpers. Extracted per CROW-1094.
    lazy var autoMerge = AutoMergeController(owner: self)

    public init(appState: AppState, providerManager: ProviderManager, store: JSONStore) {
        self.appState = appState
        self.providerManager = providerManager
        self.store = store
    }

    public func start() {
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

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Warnings

    /// Surface a missing-scope warning: console once per session, UI banner every time.
    func reportScopeWarning(_ scope: String) {
        let msg = "GitHub token missing '\(scope)' scope — run 'gh auth refresh -s \(scope)'"
        if !didLogGitHubScopeWarning {
            print("[IssueTracker] \(msg)")
            didLogGitHubScopeWarning = true
        }
        appState.githubScopeWarning = msg
    }

    /// Drop the warning after a successful poll. Re-arms the once-per-session log
    /// so a future regression will print again.
    func clearScopeWarning() {
        if appState.githubScopeWarning != nil {
            appState.githubScopeWarning = nil
        }
        didLogGitHubScopeWarning = false
    }

    /// Surface a SAML-enforcement warning: console once per session, UI banner
    /// every time. Fires when an org's SAML SSO blocks the OAuth token — the
    /// backend recovers accessible-org tickets and flags the response, so this
    /// is informational, not fatal.
    func reportSAMLWarning() {
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
    func clearSAMLWarning() {
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

    public func refresh() async {
        guard !isRefreshing else { return }
        guard shouldPoll() else {
            if let suspendedUntil {
                print("[IssueTracker] skipping refresh — rate-limited until \(suspendedUntil)")
            }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // Announce the in-flight window only once the flag is actually set, so
        // an observer that re-reads on the nudge can never miss it (CROW-771).
        appState.isLoadingIssues = true
        onLoadingIssuesChanged?()
        defer {
            appState.isLoadingIssues = false
            onLoadingIssuesChanged?()
        }

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

        var allIssues: [AssignedIssue] = []
        // Recently-done count, accumulated across every provider this refresh.
        // Each provider contributes its 24h closed/Done window; assigned once
        // at the end so a non-GitHub (e.g. Jira-only) workspace updates it too
        // instead of leaving a stale value from a prior GitHub-backed refresh.
        var doneCount = 0

        // GitHub — one consolidated GraphQL query
        let ghResult: ConsolidatedGitHubResponse? = hasGitHub ? await boardPoller.runConsolidatedGitHubQuery() : nil
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
                        // Surface PR health inline on the board (#751): PRRecord
                        // already carries these from monitoredPRsQuery, so no
                        // extra fetch. A draft PR reports "draft"; otherwise the
                        // normalized state lowercased ("open"/"merged"/"closed").
                        openIssues[idx].prState = pr.isDraft ? "draft" : pr.state.lowercased()
                        openIssues[idx].checksState = pr.checksState.isEmpty ? nil : pr.checksState
                        openIssues[idx].failedCheckNames = pr.failedCheckNames.isEmpty ? nil : pr.failedCheckNames
                    }
                }
            }
            allIssues.append(contentsOf: openIssues)

            let openIDs = Set(openIssues.map(\.id))
            let uniqueDone = ghResult.closedIssues.filter { !openIDs.contains($0.id) }
            allIssues.append(contentsOf: uniqueDone)
            doneCount += ghResult.closedTotalCount
        }

        // GitLab — one call per host; includes the recently-closed half (#697)
        // so GitLab-backed workspaces count toward doneIssuesLast24h, mirroring
        // GitHub's open + deduped-closed merge.
        for host in gitLabHosts {
            let merged = Self.mergeListing(await boardPoller.fetchGitLabIssues(host: host))
            let enriched = await boardPoller.enrichGitLabMRStatus(merged.issues, host: host)
            allIssues.append(contentsOf: enriched)
            doneCount += merged.doneCount
        }

        // Jira — one search per distinct config (best-effort, like GitLab).
        // Include the recently-Done half (#536): a Jira ticket in its mapped
        // Done status is a workflow status, not a closed issue, so it only lands
        // in the board's Done section once its `.done`-mapped issue reaches
        // `assignedIssues`. Mirror GitHub's open + deduped-closed merge.
        for cfg in jiraConfigs {
            let listing = await boardPoller.fetchJiraIssues(config: cfg)
            let merged = Self.mergeListing(listing)
            allIssues.append(contentsOf: merged.issues)
            doneCount += merged.doneCount
        }

        appState.assignedIssues = allIssues
        appState.doneIssuesLast24h = doneCount

        let ticketExcludePatterns = config.defaults.excludeTicketRepos
        let autoCreateCandidates = ticketExcludePatterns.isEmpty
            ? allIssues
            : allIssues.filter { !repoMatchesPatterns($0.repo, patterns: ticketExcludePatterns) }
        boardPoller.detectAutoCreateCandidates(issues: autoCreateCandidates)

        if let ghResult {
            // Session PR link detection runs against open PRs only — we only
            // ever want to attach a fresh link when there's an open PR.
            reconciler.applySessionPRLinks(viewerPRs: ghResult.viewerPRs)

            // For sessions with an existing .pr link whose PR isn't in the open
            // viewer set, fetch the state in one batched aliased query. This
            // surfaces merged/closed state without pulling MERGED/CLOSED PRs
            // for every viewer (which routinely returned 100 PRs / ~86 KB).
            let openPRURLs = Set(ghResult.viewerPRs.map(\.url))
            let staleCandidateURLs = boardPoller.collectStalePRURLs(excluding: openPRURLs)
            // `complete == false` means at least one provider's follow-up errored
            // (rate limit, exit != 0, parse failure). We thread that through to
            // auto-complete so "PR missing from payload" doesn't get treated as
            // "PR is closed" on a degraded response. Partial-success is allowed:
            // PRs from the working provider still flow through so merged badges
            // can flip even if the other provider failed.
            let staleFetch = staleCandidateURLs.isEmpty
                ? StalePRFetchResult(prs: [], complete: true)
                : await boardPoller.fetchStalePRStates(urls: staleCandidateURLs, viewerLogin: ghResult.viewerLogin)
            let stalePRs = staleFetch.prs
            let prDataComplete = staleFetch.complete
            let allKnownPRs = Self.dedupedByURL(ghResult.viewerPRs + stalePRs)

            applyPRStatuses(viewerPRs: allKnownPRs)
            attribution.updatePRAttributions(viewerPRs: allKnownPRs)

            // Rework signals (#694): capture file lists for fresh merges,
            // stamp reverts, then post-merge fixes — in that order, so a
            // revert never double-counts as a fix (heuristic rule 4).
            await attribution.captureChangedFilesForNewMerges()
            await attribution.scanDefaultBranchesForReverts()
            attribution.detectPostMergeFixes()

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
            // How many requested reviews the filters swallowed (CROW-982). The
            // board shows this so "No review requests" can't be mistaken for
            // "GitHub is asking nothing of me" — the #953 failure mode, where
            // `ignoreReviewLabels` hid live requests and the board looked empty.
            appState.hiddenReviewCount = max(0, allCurrentIDs.count - reviews.count)

            // The post-request half of the board (CROW-982, widened by
            // CROW-990). Cross-referenced against review sessions on the same
            // rule as the requested queue, so a PR you reviewed that still has a
            // live session renders under In review rather than jumping straight
            // to a finished heading. Repo/label filters are applied at
            // serialization time via `filteredReviewedPRs` — the same place the
            // requested queue is filtered — so the two lists can't drift apart
            // on which repos are visible.
            //
            // Deliberately outside the notification path: a submitted review is
            // work finished, not work arriving, and chiming `reviewRequested`
            // for it would be a lie.
            var reviewed = ghResult.reviewedPRs
            for i in reviewed.indices {
                if let session = appState.reviewSessions.first(where: {
                    appState.links(for: $0.id).contains(where: { $0.linkType == .pr && $0.url == reviewed[i].url })
                }) {
                    reviewed[i].reviewSessionID = session.id
                }
            }
            // A PR can legitimately be in both searches (you reviewed it, then
            // the author pushed and re-requested). The requested queue owns it
            // in that case — it is asking for something — so drop the duplicate
            // here rather than letting it render in two groups at once.
            //
            // This can only ever discard an *open* row: the requested search is
            // `review-requested:@me state:open`, so a merged or closed PR is
            // never in `requestedURLs` and a Recently completed row cannot be
            // swallowed by a stale request.
            let requestedURLs = Set(reviews.map(\.url))
            appState.reviewedPRs = reviewed.filter { !requestedURLs.contains($0.url) }
            appState.isLoadingReviews = false

            onReviewRequestsRefreshed?(reviews)

            completion.syncInReviewSessions(issues: allIssues)
            completion.autoCompleteFinishedSessions(
                openIssues: allIssues.filter { $0.state == "open" },
                closedIssueURLs: Set(ghResult.closedIssues.map(\.url)),
                viewerPRs: allKnownPRs,
                prDataComplete: prDataComplete
            )
            completion.autoCompleteFinishedReviews(
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
        await reconciler.reconcileMissingPRLinks()

        // Auto-cleanup expired completed/archived sessions. Runs outside
        // the ghResult block so it fires even without GitHub data. Placed
        // after auto-complete so freshly completed sessions respect the
        // full retention window.
        await completion.autoCleanupExpiredSessions(config: config)

        logRefreshSummary(elapsed: Date().timeIntervalSince(startedAt))
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


    /// Route typed `ProviderError`s from GitHub backends to the matching
    /// IssueTracker UI side-effect (scope warning, rate-limit suspension).
    /// Untyped errors get a console line and otherwise propagate as "this
    /// cycle is degraded" via the caller's nil-return.
    func handleGitHubBackendError(_ error: Error, operation: String) {
        switch error {
        case ProviderError.insufficientScope(let scope):
            reportScopeWarning(scope)
        case ProviderError.rateLimited(let stderr):
            _ = handleGraphQLRateLimit(stderr: stderr)
        case ProviderError.samlRestricted:
            // `findRecentPRsForBranches` doesn't recover partial data; route
            // its SAML failures to the same one-time warning instead of
            // spamming the console each cycle. (`prStates` recovers its
            // accessible aliases since #894, so it no longer lands here.)
            reportSAMLWarning()
        default:
            print("[IssueTracker] \(operation) failed: \(error.localizedDescription)")
        }
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

            var newStatus = Self.buildPRStatus(from: pr)
            let oldStatus = previousPRStatus[session.id]

            // #838: after a successful `addMergeLabel`, keep the merge icon lit
            // until a fetch actually confirms `crow:merge`. An in-flight poll
            // that started before the add carries pre-label data and would
            // otherwise clear the optimistic flag here; GitHub's read-your-write
            // lag can do the same. Once a snapshot reports the label, the
            // durable path (stale-query labels + `unionLabels`) has caught up —
            // drop the marker so a genuine later removal isn't masked. Applied
            // before the assignments below; `hasMergeLabel` isn't a transition
            // input, so this doesn't affect checks-failing/needs-refine edges.
            if pendingMergeLabelSessions.contains(session.id) {
                if newStatus.hasMergeLabel {
                    pendingMergeLabelSessions.remove(session.id)
                } else {
                    newStatus.hasMergeLabel = true
                }
            }

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
            let terminalIdle = isManagedTerminalIdle(sessionID: session.id)
            let firstObservation = !seenPRsAtStart.contains(prLink.url)
            let cooldownOK = cooldownElapsed(prURL: prLink.url, now: now)
            let refineGate = Self.needsRefineGate(
                status: newStatus,
                toggleOn: respondToChangesRequested,
                isReviewSession: session.kind == .review,
                firstObservation: firstObservation,
                terminalIdle: terminalIdle,
                cooldownElapsed: cooldownOK
            )
            if refineGate == nil {
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
                lastNeedsRefineGateCleared(prURL: prLink.url)
                CrowLog.automation(
                    "auto-respond: needs-refine fired — session=\(session.id.uuidString), "
                    + "sha=\(newStatus.headSha ?? ""), lastCR=\(Self.iso(newStatus.lastChangesRequestedAt)), "
                    + "lastCommit=\(Self.iso(newStatus.lastSubstantiveCommitAt)), "
                    + "reFire=\(isCooldownReFire ? "yes" : "no")")
            } else if let gate = refineGate,
                      gate != .reviewSession,
                      newStatus.reviewStatus == .changesRequested,
                      newStatus.isOpen {
                // Suppressed evaluation (CROW-921). Only for PRs actually
                // sitting in CHANGES_REQUESTED — logging every healthy PR
                // every poll would bury the signal it exists to surface.
                // `.reviewSession` is excluded too: a review session's linked
                // PR being changes-requested is the *normal* outcome of a
                // review, not a stall worth a line every hour.
                logNeedsRefineGate(
                    prURL: prLink.url,
                    prNumber: pr.number,
                    status: newStatus,
                    gate: gate,
                    terminalIdle: terminalIdle,
                    cooldownElapsed: cooldownOK,
                    now: now
                )
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
        // Steady-state log dedupe is keyed `(channel, url)`, so build the live
        // key set rather than intersecting on URL.
        let liveLogKeys = Set(livePRURLs.flatMap {
            [
                Self.steadyStateLogKey(channel: Self.needsRefineLogChannel, prURL: $0),
                Self.steadyStateLogKey(channel: Self.autoReReviewLogChannel, prURL: $0),
            ]
        })
        steadyStateLogDedupe = steadyStateLogDedupe.filter { liveLogKeys.contains($0.key) }
        // Drop pending merge-label markers for sessions that no longer exist
        // (deleted mid-window). Keyed by session, so intersect with live
        // sessions rather than PR URLs (#838).
        if !pendingMergeLabelSessions.isEmpty {
            pendingMergeLabelSessions.formIntersection(Set(sessionsWithPRs.map { $0.id }))
        }

        if !transitions.isEmpty {
            onPRStatusTransitions?(transitions)
        }

        autoMerge.applyAutoMerge(viewerPRs: viewerPRs)
        autoRebase.applyAutoRebase(viewerPRs: viewerPRs)
        autoReReview.applyAutoReRequestReview(viewerPRs: viewerPRs)
    }

    /// Why a needs-refine evaluation did NOT dispatch, or `nil` when it did
    /// (CROW-921). Pure and `nonisolated static` so the gate is unit-testable
    /// without an `IssueTracker`; raw values are grep-stable log strings, the
    /// same convention as `AutoMergeSkipReason` / `AutoRebaseDeferReason`.
    ///
    /// Checked in the order a reader would ask the questions: is the feature
    /// on, is this session even eligible, have we seen the PR before, what
    /// state is the PR in, is the agent free, has the cooldown elapsed.
    nonisolated static func needsRefineGate(
        status: PRStatus,
        toggleOn: Bool,
        isReviewSession: Bool,
        firstObservation: Bool,
        terminalIdle: Bool,
        cooldownElapsed: Bool
    ) -> NeedsRefineGate? {
        if !toggleOn { return .toggleOff }
        if isReviewSession { return .reviewSession }
        if firstObservation { return .firstObservation }
        let state = PRStatus.changesRequestedState(status: status)
        switch state {
        case .notApplicable: return .notChangesRequested
        case .awaitingReviewer: return .awaitingReviewer
        case .awaitingReRequest: return .awaitingReRequest
        case .needsRefine: break
        }
        if !terminalIdle { return .agentBusy }
        if !cooldownElapsed { return .cooldown }
        return nil
    }

    /// Grep-stable reasons a needs-refine evaluation was suppressed.
    enum NeedsRefineGate: String, Sendable, Equatable {
        case toggleOff = "respond-to-changes-requested-off"
        case reviewSession = "review-session"
        case firstObservation = "first-observation"
        case notChangesRequested = "not-changes-requested-or-no-anchor"
        case awaitingReviewer = "awaiting-reviewer"
        case awaitingReRequest = "awaiting-re-request"
        case agentBusy = "agent-busy"
        case cooldown = "cooldown"
    }

    /// Forget the last gated line for a PR so the next suppression logs
    /// immediately rather than waiting out the heartbeat — a dispatch means
    /// the situation changed, and the next quiet poll is worth a line.
    private func lastNeedsRefineGateCleared(prURL: String) {
        steadyStateLogDedupe.removeValue(
            forKey: Self.steadyStateLogKey(channel: Self.needsRefineLogChannel, prURL: prURL))
    }

    /// Emit `message` for `(channel, prURL)` unless the identical line was
    /// already emitted for that pair within the heartbeat window. Returns
    /// whether it was emitted, so callers can assert on it in tests.
    @discardableResult
    func logSteadyState(
        channel: String, prURL: String, message: String, now: Date
    ) -> Bool {
        let key = Self.steadyStateLogKey(channel: channel, prURL: prURL)
        if let previous = steadyStateLogDedupe[key],
           previous.message == message,
           now.timeIntervalSince(previous.at) < Self.steadyStateLogHeartbeat {
            return false
        }
        steadyStateLogDedupe[key] = (message: message, at: now)
        CrowLog.automation(message)
        return true
    }

    /// Emit one gated-evaluation line per PR. See `steadyStateLogDedupe`.
    private func logNeedsRefineGate(
        prURL: String,
        prNumber: Int,
        status: PRStatus,
        gate: NeedsRefineGate,
        terminalIdle: Bool,
        cooldownElapsed: Bool,
        now: Date
    ) {
        logSteadyState(
            channel: Self.needsRefineLogChannel,
            prURL: prURL,
            message: "needs-refine: #\(prNumber) gated (reason=\(gate.rawValue), "
                + "state=\(PRStatus.changesRequestedState(status: status).rawValue), "
                + "lastCR=\(Self.iso(status.lastChangesRequestedAt)), "
                + "lastCommit=\(Self.iso(status.lastSubstantiveCommitAt)), "
                + "reviewerReRequested=\(status.changesRequestedReviewerIsPending ? "yes" : "no"), "
                + "idle=\(terminalIdle ? "yes" : "no"), "
                + "cooldown=\(cooldownElapsed ? "ok" : "waiting"))",
            now: now)
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

    /// True when the session's agent has nothing in flight — either it is
    /// idle/done, or there is no launched agent to wait for (CROW-921).
    ///
    /// Deliberately *not* `isManagedTerminalIdle`, whose "no launched
    /// terminal ⇒ false" is right for prompting (you can't type at an agent
    /// that isn't running) and wrong for re-requesting review (a closed
    /// terminal would recreate exactly the permanent dead-end #921 is about).
    ///
    /// Gating on this at all is safe in a way the needs-refine gate is not:
    /// `.awaitingReRequest` is a *stable* condition — it holds until somebody
    /// adds the request — so waiting for the agent only ever delays the
    /// re-request by a poll or two. It buys the guarantee that Crow doesn't
    /// ping a reviewer (or, in auto-review repos, spawn a review session)
    /// while the agent is still working through finding 2 of 3.
    func agentSettled(sessionID: UUID) -> Bool {
        guard let managedTerminal = appState.terminals(for: sessionID).first(where: { $0.isManaged }),
              appState.terminalReadiness[managedTerminal.id] == .agentLaunched else {
            return true
        }
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
    nonisolated static func buildPRStatus(from pr: ViewerPR) -> PRStatus {
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
            lastSubstantiveCommitAt: pr.lastSubstantiveCommitAt,
            // Reviewer-scoped, not PR-wide: an unrelated reviewer who is still
            // pending from the original request must not read as "the ball is
            // with the reviewer" (review of #930).
            changesRequestedReviewerIsPending: PRStatus.changesRequestedReviewerIsPending(
                changesRequestedReviewers: pr.changesRequestedReviewerLogins,
                pendingReviewers: pr.pendingReviewerLogins,
                anyPendingRequest: pr.hasPendingReviewRequest
            ),
            // Same case-insensitive match `shouldAttemptAutoMerge` gates on —
            // surfaced for the UI so the sidebar can show "labeled for merge"
            // separately from "auto-merge already enabled" (CROW-773).
            hasMergeLabel: pr.labels.contains {
                $0.name.caseInsensitiveCompare(Self.autoMergeLabel) == .orderedSame
            }
        )
    }



    // MARK: - Mark In Review

    /// Move a session's linked ticket to its board's **In Review** status, then
    /// flip the Crow session to `.inReview`.
    ///
    /// Throws `SessionActionError` rather than swallowing failures: the caller
    /// (the `mark-in-review` RPC, and through it `crow mark-in-review` and the
    /// web menu) has to be able to tell "moved the board" from "did nothing"
    /// (#876 — the contract #816 gave `markIssueDone` / `addMergeLabel`). This
    /// method spent the post-ADR-0010 window with no callers at all, which is
    /// how `mark-in-review` came to be documented as session-status-only.
    ///
    /// Returns a warning sentence — rather than throwing — when the session
    /// transition was the only thing that *could* have happened: the provider
    /// has no board status at all (GitLab), or the issue sits on a board with
    /// no column mapping to In Review. Those are not failures; nothing was ever
    /// going to move, and the caller asked for the session transition too.
    /// Every other provider error throws.
    @discardableResult
    public func markInReview(sessionID: UUID) async throws -> String? {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }) else {
            throw SessionActionError.sessionNotFound
        }
        // The web menu never offers this for a Manager; match that server-side.
        guard !session.isManager else {
            throw SessionActionError.managerSession("mark-in-review")
        }
        guard let ticketURL = session.ticketURL, !ticketURL.isEmpty else {
            throw SessionActionError.noTicketURL("mark-in-review")
        }
        guard let taskProvider = session.provider else {
            throw SessionActionError.noProvider("mark-in-review")
        }

        // For Jira, thread the matching workspace's per-project status-name map
        // (#523) so the transition honors a renamed workflow ("In Review" →
        // "Code Review"). For every other provider, resolve provider + host
        // straight from the URL so self-hosted GitLab/Corveil instances are
        // targeted correctly — matching `markIssueDone`. Resolving by bare
        // provider enum, as this method used to, drops the host.
        let backend: TaskBackend
        if taskProvider == .jira {
            backend = providerManager.taskBackend(for: .jira, jira: Self.jiraConfig(forTicket: ticketURL))
        } else {
            backend = providerManager.taskBackend(forURL: ticketURL)
        }

        appState.isMarkingInReview[sessionID] = true
        defer { appState.isMarkingInReview[sessionID] = false }

        // No `.projectBoardStatus` pre-check: a backend without the capability
        // reports exactly that as `.unimplemented` (GitLabTaskBackend does
        // nothing else), and so does GitHub for a board with no In Review
        // column. One rule for one fact, and no capability set to drift from
        // what the backend actually does.
        do {
            try await backend.setTaskStatus(url: ticketURL, status: .inReview)
        } catch ProviderError.unimplemented(let msg) {
            // Not a failure: this provider/board has no In Review status to
            // move to. Throwing here would make `crow mark-in-review` a hard
            // error on every GitLab session, and on every GitHub board whose
            // column is named something other than "In Review"/"Review".
            print("[IssueTracker] markInReview: \(msg)")
            return "Session moved to In Review, but the ticket did not: "
                + "no In Review status is available for \(ticketURL)."
        } catch ProviderError.insufficientScope {
            // `githubScopeWarning` is read by nothing since the app retired
            // (ADR 0010), so the thrown message has to carry the whole fix.
            reportScopeWarning("project")
            throw SessionActionError.providerFailed(
                "GitHub token missing 'project' scope — run `gh auth refresh -s project`")
        } catch let error as ProviderError {
            let detail = Self.providerFailureDetail(error)
            print("[IssueTracker] markInReview failed for \(ticketURL): \(detail)")
            throw SessionActionError.providerFailed(detail)
        } catch {
            let detail = String(error.localizedDescription.prefix(200))
            print("[IssueTracker] markInReview failed for \(ticketURL): \(detail)")
            throw SessionActionError.providerFailed(detail)
        }

        // Update local state — match by URL so it works regardless of provider.
        if let idx = appState.assignedIssues.firstIndex(where: { $0.url == ticketURL }) {
            appState.assignedIssues[idx].projectStatus = .inReview
        }

        print("[IssueTracker] Marked \(ticketURL) as In Review")

        // Flip the Crow session for in-process callers. The RPC handler applies
        // the same transition itself (this callback is nil on a no-tmux host),
        // and `updateSessionStatus` is idempotent, so the overlap is free.
        appState.onSetSessionInReview?(sessionID)
        return nil
    }

    /// `ProviderError` has no `LocalizedError` conformance, so
    /// `localizedDescription` on one is the useless "The operation couldn't be
    /// completed. (CrowProvider.ProviderError error N.)" — and every
    /// `setTaskStatus` failure is a typed `ProviderError` (see
    /// `GitHubTaskBackend.classifyGraphQLError`). Pull the payload out by hand
    /// so the sentence a CLI user reads is the real `gh`/`glab` error.
    static func providerFailureDetail(_ error: ProviderError) -> String {
        let raw: String
        switch error {
        case .invalidURL(let url): raw = "invalid ticket URL: \(url)"
        case .commandFailed(let output): raw = output
        case .unimplemented(let msg): raw = msg
        case .insufficientScope(let scope): raw = "GitHub token missing '\(scope)' scope"
        case .rateLimited(let output): raw = "rate limited: \(output)"
        case .samlRestricted(let output): raw = "SAML-restricted: \(output)"
        }
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    // MARK: - Mark Issue Done

    /// Move a session's linked issue to its done/closed state on the provider
    /// (GitHub/GitLab close the issue; Jira/Corveil transition to the mapped
    /// completed status), then flip the Crow session to `.completed`.
    ///
    /// Throws `SessionActionError` rather than swallowing failures: the caller
    /// (the `mark-issue-done` RPC, and through it `crow mark-issue-done`) has to
    /// be able to distinguish "closed the issue" from "did nothing" (CROW-816).
    public func markIssueDone(sessionID: UUID) async throws {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }) else {
            throw SessionActionError.sessionNotFound
        }
        // The web menu never offers this for a Manager; match that server-side.
        guard !session.isManager else {
            throw SessionActionError.managerSession("mark-issue-done")
        }
        guard let ticketURL = session.ticketURL, !ticketURL.isEmpty else {
            throw SessionActionError.noTicketURL("mark-issue-done")
        }
        guard let taskProvider = session.provider else {
            throw SessionActionError.noProvider("mark-issue-done")
        }

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
            throw SessionActionError.unsupportedByProvider(msg)
        } catch {
            let detail = String(error.localizedDescription.prefix(200))
            print("[IssueTracker] markIssueDone failed for \(ticketURL): \(detail)")
            throw SessionActionError.providerFailed(detail)
        }

        // Reflect locally — match by URL so it works regardless of provider.
        if let idx = appState.assignedIssues.firstIndex(where: { $0.url == ticketURL }) {
            appState.assignedIssues[idx].projectStatus = .done
        }

        // Cosmetic cleanup (#706, #790): a closed issue reads as Done
        // regardless, so drop any lingering no-project fallback status label.
        // Only the labels the issue actually carries are removed — gated on the
        // in-memory labels to avoid a gratuitous API call (and a "not found"
        // failure); best-effort.
        if let issue = appState.assignedIssues.first(where: { $0.url == ticketURL }) {
            let names = Set(issue.labels.map(\.name))
            let stale = TicketStatus.fallbackStatusLabels.filter { names.contains($0) }
            if !stale.isEmpty {
                try? await backend.setLabels(url: ticketURL, add: [], remove: stale)
            }
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
    /// failures are logged and swallowed, because both callers are fire-and-
    /// forget (`setup.sh` at session start, `resyncJira` over every session).
    /// Contrast `markInReview`, whose caller is a user-facing verb and which
    /// therefore reports failures as `SessionActionError` (#876).
    public func transitionTicket(sessionID: UUID, to status: TicketStatus) async {
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
    public func resyncJira() async -> Int {
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
    /// (GitHub only today).
    ///
    /// Throws `SessionActionError` rather than swallowing failures, so
    /// `crow add-merge-label` can't report success for a label it never added
    /// (CROW-816).
    ///
    /// Returns a warning sentence when the label landed but auto-merge
    /// provably won't follow — the watcher is off, or the watcher has already
    /// given up on this PR. That is not a failure (`ok` stays true, the label
    /// really is on the PR), but reporting a bare success for a label nothing
    /// will act on is precisely how #888 looked from the outside.
    @discardableResult
    public func addMergeLabel(sessionID: UUID) async throws -> String? {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }) else {
            throw SessionActionError.sessionNotFound
        }
        // The web menu never offers this for a Manager; match that server-side.
        guard !session.isManager else {
            throw SessionActionError.managerSession("add-merge-label")
        }
        guard let prLink = appState.links(for: sessionID).first(where: { $0.linkType == .pr }) else {
            throw SessionActionError.noPRLink("add-merge-label")
        }
        guard let backend = codeBackend(for: session) else {
            throw SessionActionError.noProvider("add-merge-label")
        }
        guard backend.capabilities.contains(.autoMergeLabel) else {
            throw SessionActionError.unsupportedByProvider("auto-merge labels")
        }

        appState.isAddingMergeLabel[sessionID] = true
        defer { appState.isAddingMergeLabel[sessionID] = false }

        let repo = Self.repoSlug(fromPRURL: prLink.url)
        guard !repo.isEmpty else {
            // Without a repo slug we can't `ensureMergeLabel`, and the bare
            // `gh pr edit --add-label` would fail if the label doesn't already
            // exist. Bail loudly rather than silently half-doing the action.
            print("[IssueTracker] addMergeLabel: could not parse repo slug from \(prLink.url)")
            throw SessionActionError.unparseableRepo(prLink.url)
        }
        do {
            try await autoMerge.ensureMergeLabelOnce(repo: repo, backend: backend)
            try await backend.addMergeLabel(prURL: prLink.url)
            CrowLog.info("[Crow] Added crow:merge to \(prLink.url)")
            // Optimistically flip the merge icon so the user sees the label
            // land immediately, rather than waiting for — and getting stuck
            // behind — the next full poll's snapshot (#838). The sticky marker
            // keeps it lit across a poll that started *before* this add (which
            // would otherwise overwrite `prStatus` with pre-label data) until a
            // fetch confirms the label; `applyPRStatuses` clears it then.
            pendingMergeLabelSessions.insert(sessionID)
            appState.prStatus[sessionID]?.hasMergeLabel = true
            // Targeted re-evaluation so the auto-merge watcher acts on this PR
            // now, with the label present, instead of on the next scheduled
            // poll — without paying for (or being silently skipped by) a full
            // multi-provider board refresh (#931, #888).
            await autoMerge.reevaluateAutoMergeAfterLabel(session: session, prURL: prLink.url)
            // Read the verdict *after* the re-evaluation: that pass is what
            // populates `autoMergeState`, so asking before it would report the
            // previous poll's answer — or nothing at all on a freshly linked
            // PR (#888).
            return autoMergeWarning(sessionID: sessionID)
        } catch {
            let detail = String(error.localizedDescription.prefix(200))
            print("[IssueTracker] addMergeLabel failed for \(prLink.url): \(detail)")
            throw SessionActionError.providerFailed(detail)
        }
    }

    /// Why the `crow:merge` label just applied to `sessionID`'s PR won't
    /// produce a merge, or `nil` when nothing is standing in the way.
    ///
    /// The watcher toggle comes first: it's the one cause that applies to every
    /// PR at once and the one with a one-line fix, so naming it beats reporting
    /// a per-PR symptom underneath it.
}
