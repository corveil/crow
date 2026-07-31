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
    private let appState: AppState
    private let providerManager: ProviderManager
    /// Shared store instance (injected by AppDelegate). PR attributions MUST
    /// be written through the same `JSONStore` that `SessionService` mutates
    /// — an ad-hoc `JSONStore()` write would be clobbered by the next
    /// mutation of the shared instance's older in-memory snapshot. Every
    /// attribution write is followed by `syncPRAttributionMirror()` so the
    /// read-only `appState.prAttributions` mirror (the v2 combined score's
    /// input, #699) stays current.
    private let store: JSONStore
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
    /// `onWorkOnIssue` flow and post a notification.
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
    /// Cleared on *transient* `enableAutoMerge` failure (so the next poll
    /// retries). Left set on permanent/expected outcomes (repo disallows
    /// auto-merge, missing Crow authorship) so we don't re-log every poll.
    /// Note: a transient error while *fetching* commits for the authorship
    /// check also leaves the marker set today (pre-existing); that path
    /// returns "not Crow-authored" rather than distinguishing fetch failure.
    /// Effectively frozen on success once `Session.autoMergeEnabledAt` is
    /// persisted, which the gating guard checks first.
    private var autoMergeInFlight: Set<String> = []

    /// Last time we logged "auto-merge watcher disabled" to the automation log.
    /// Rate-limits that line to hourly so a deliberately-off watcher doesn't
    /// bury the interesting entries at one line per 60s poll (CROW-782).
    private var lastAutoMergeDisabledLogAt: Date?

    /// Same hourly rate-limit for the two other steady-state "nothing happened"
    /// lines — an idle auto-rebase watcher and `crow:auto` issues with no
    /// handler to dispatch them. At one line per 60s poll they'd rotate the
    /// interesting entries out of the log (review #787).
    private var lastAutoRebaseIdleLogAt: Date?
    private var lastAutoCreateUndispatchableLogAt: Date?

    /// Why we permanently stopped trying to auto-merge a PR, keyed by PR URL.
    /// `autoMergeInFlight` is deliberately left set for permanent outcomes (repo
    /// disallows auto-merge, no Crow-Session trailer) so the failure isn't
    /// re-logged every poll — but then the per-poll summary would report a bare
    /// `in-flight` forever instead of the real reason. Recording it here keeps
    /// the summary honest (review #787).
    private var autoMergePermanentSkips: [String: String] = [:]

    /// `"<pr url>\n<reason>"` pairs we've already pushed an `autoMergeBlocked`
    /// notification for. The permanent skips latch themselves — the marker
    /// above is written exactly once and `autoMergeInFlight` short-circuits
    /// every later poll — but a block discovered in the candidate loop (a
    /// watcher that's off, a PR missing from the fetch) recurs on every 60s
    /// poll, which would be a chime a minute. Keyed *with* the reason, and a
    /// URL's entries are dropped as soon as it stops being blocked, so a
    /// fixed-then-rebroken PR announces itself again (#888).
    private var autoMergeBlockNotified: Set<String> = []

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
    /// a later poll retries; for the two deferrals, `autoRebaseDeferrals` then
    /// paces how much later. In-memory only.
    private var autoRebaseAttempted: Set<String> = []

    /// A deferred auto-rebase attempt: why it deferred, how many consecutive
    /// times this head state has deferred, and when it may be retried.
    private struct AutoRebaseDeferral {
        let reason: AutoRebaseDeferReason
        let count: Int
        let retryAt: Date
    }

    /// Deferred auto-rebase attempts per head-key. A deferral un-sets the
    /// `autoRebaseAttempted` key so the head can be re-dispatched, so without
    /// this the retry cadence is "every poll, forever" — a clean-but-stale
    /// worktree re-fetched and re-logged a bare `dispatched` line every 60s
    /// with no outcome ever recorded (#889). Cleared on any non-deferral
    /// outcome. In-memory only.
    private var autoRebaseDeferrals: [String: AutoRebaseDeferral] = [:]

    /// Why an auto-rebase attempt deferred rather than rebasing. Raw values are
    /// grep-stable — they are written verbatim to the automation log, like
    /// `AutoMergeSkipReason`.
    enum AutoRebaseDeferReason: String {
        case dirtyWorktree = "dirty-worktree"
        case outOfSyncAhead = "out-of-sync-ahead"
        case outOfSyncDiverged = "out-of-sync-diverged"
    }

    /// Consecutive `.failed` rebase attempts per head-key, so a transient git
    /// failure (fetch flake, rejected lease, unreachable base) is retried a
    /// bounded number of times rather than either stalling forever or
    /// hot-looping on a genuinely-broken config. Cleared on any non-failure
    /// outcome. In-memory only.
    private var autoRebaseFailureCounts: [String: Int] = [:]

    /// Max consecutive `.failed` auto-rebase attempts per head state before
    /// the watcher gives up until the head commit changes.
    nonisolated static let maxAutoRebaseFailureRetries = 3

    /// Backoff bounds for deferred auto-rebase attempts. The base matches one
    /// board poll so the first retry is immediate-ish; the cap keeps a
    /// permanently stuck branch to ~4 attempts an hour.
    nonisolated static let autoRebaseDeferralBaseDelay: TimeInterval = 60
    nonisolated static let autoRebaseDeferralMaxDelay: TimeInterval = 900

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

    /// PR URLs with an auto-re-request-review call in flight (CROW-921).
    /// Keyed by URL, cleared in the attempt's `defer`, so two sessions sharing
    /// a PR can't both fire and a slow `gh` call can't be re-entered by the
    /// next poll.
    /// Internal (not private) so `@testable` tests can read the dispatch
    /// decision without a live backend.
    var autoReRequestInFlight: Set<String> = []

    /// One re-request per (PR head, review round). Keyed
    /// `"<url>\n<headRefOid>\n<lastChangesRequestedAt>"`: a new push or a new
    /// reviewer submission is a genuinely new round and re-arms the watcher,
    /// while a retried poll over identical data does not.
    ///
    /// Belt-and-braces rather than the primary guard — the watcher is
    /// self-limiting, because a successful request flips
    /// `hasPendingReviewRequest` and the PR moves to `.awaitingReviewer` on
    /// the next poll. This covers the window before that snapshot arrives.
    /// Internal for the same reason as `autoReRequestInFlight`.
    var autoReRequestAttempted: Set<String> = []

    /// Hourly clock for the auto-re-request "enabled, nothing to do" line, so
    /// a healthy steady state doesn't fill `crowd-automation.log`.
    private var lastAutoReReviewIdleLogAt: Date?

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

    /// Last time the default-branch revert scan ran (#694). In-memory: a
    /// restart re-scans, which the per-target dedupe makes harmless.
    private var lastRevertScanAt: Date?

    /// PR URLs whose changed-files fetch has been attempted this process
    /// (#694). Guards against re-hitting the API every poll when the fetch
    /// fails; a restart retries, which is the desired recovery path.
    private var changedFilesFetchAttempted: Set<String> = []

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
            let merged = Self.mergeListing(await fetchGitLabIssues(host: host))
            let enriched = await enrichGitLabMRStatus(merged.issues, host: host)
            allIssues.append(contentsOf: enriched)
            doneCount += merged.doneCount
        }

        // Jira — one search per distinct config (best-effort, like GitLab).
        // Include the recently-Done half (#536): a Jira ticket in its mapped
        // Done status is a workflow status, not a closed issue, so it only lands
        // in the board's Done section once its `.done`-mapped issue reaches
        // `assignedIssues`. Mirror GitHub's open + deduped-closed merge.
        for cfg in jiraConfigs {
            let listing = await fetchJiraIssues(config: cfg)
            let merged = Self.mergeListing(listing)
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
            updatePRAttributions(viewerPRs: allKnownPRs)

            // Rework signals (#694): capture file lists for fresh merges,
            // stamp reverts, then post-merge fixes — in that order, so a
            // revert never double-counts as a fix (heuristic rule 4).
            await captureChangedFilesForNewMerges()
            await scanDefaultBranchesForReverts()
            detectPostMergeFixes()

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
    ///
    /// Also a no-op when no `onAutoCreateRequest` handler is wired: since
    /// CROW-782 the *provider* is armed even on a daemon with no tmux (and so no
    /// Manager terminal to spawn into), and dispatching into a nil callback here
    /// would strip `crow:auto` anyway — permanently burning the one-shot trigger
    /// for a workspace that was never created (review #787). Same contract as
    /// the disabled case: leave the label, pick it up once a host can act.
    private func detectAutoCreateCandidates(issues: [AssignedIssue]) {
        guard Self.canRunAutoCreate(enabled: autoCreateWatcherEnabledProvider(),
                                    hasHandler: onAutoCreateRequest != nil) else {
            if autoCreateWatcherEnabledProvider() { logAutoCreateUndispatchableIfDue(issues: issues) }
            return
        }
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

    /// Whether the auto-create sweep may run — i.e. whether stripping `crow:auto`
    /// (which the sweep always does after dispatch) is justified. Requires BOTH
    /// the config opt-in AND a wired handler: dispatching into a nil callback
    /// still burns the one-shot label without creating anything (review #787).
    /// Pure so the rule is unit-testable without an `IssueTracker`.
    nonisolated static func canRunAutoCreate(enabled: Bool, hasHandler: Bool) -> Bool {
        enabled && hasHandler
    }

    /// Say (hourly at most) that `crow:auto` issues are waiting but nothing can
    /// act on them — the enabled-but-undispatchable state a no-tmux daemon is in.
    /// Silent when there's nothing labeled, so a normal headless daemon with no
    /// pending auto-create work doesn't log at all.
    private func logAutoCreateUndispatchableIfDue(issues: [AssignedIssue]) {
        let waiting = issues.filter { issue in
            issue.state == "open"
                && issue.labels.contains { $0.name.caseInsensitiveCompare(Self.autoCreateLabel) == .orderedSame }
        }
        guard !waiting.isEmpty else { return }
        let now = Date()
        if let last = lastAutoCreateUndispatchableLogAt, now.timeIntervalSince(last) < 3600 { return }
        lastAutoCreateUndispatchableLogAt = now
        CrowLog.automation(
            "crow:auto: \(waiting.count) labeled issue(s) waiting but no onAutoCreateRequest handler is "
            + "wired (no Manager terminal — is tmux available?); leaving the label in place")
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
    /// OPEN→MERGED demotion mid-refresh still carries the reviews from the
    /// OPEN record (the stale-PR follow-up query leaves those fields empty;
    /// since #894 it does fetch checks, but the backfill still matters for a
    /// GitLab stale MR, which carries neither).
    ///
    /// Labels are **unioned** rather than picked from one side (#838): a
    /// freshly added `crow:merge` can arrive on whichever record wins the
    /// state rank, so choosing one side's array wholesale silently dropped it
    /// (e.g. a stale winner with a pre-label label set shadowing the fresh
    /// loser). Both the merge icon (`hasMergeLabel`) and the auto-merge watcher
    /// (`autoMergeSkipReason`) read this field, so a label GitHub reports on
    /// either record must survive the merge.
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
            labels: Self.unionLabels(winner.labels, loser.labels),
            linkedIssueReferences: winner.linkedIssueReferences.isEmpty ? loser.linkedIssueReferences : winner.linkedIssueReferences,
            checksState: winner.checksState.isEmpty ? loser.checksState : winner.checksState,
            failedCheckNames: winner.failedCheckNames.isEmpty ? loser.failedCheckNames : winner.failedCheckNames,
            latestReviewStates: winner.latestReviewStates.isEmpty ? loser.latestReviewStates : winner.latestReviewStates,
            lastChangesRequestedAt: winner.lastChangesRequestedAt ?? loser.lastChangesRequestedAt,
            lastSubstantiveCommitAt: winner.lastSubstantiveCommitAt ?? loser.lastSubstantiveCommitAt,
            mergeCommitOid: winner.mergeCommitOid ?? loser.mergeCommitOid,
            // Prefer whichever record actually knows the repo's auto-merge
            // policy — the stale-PR query and the viewer fetch don't always
            // both carry it, and `nil` here means "unknown", so a known value
            // from the loser is strictly better than dropping it (#888).
            repoAutoMergeAllowed: winner.repoAutoMergeAllowed ?? loser.repoAutoMergeAllowed
        )
    }

    /// Union two label arrays, preserving `primary` order and appending any
    /// `secondary` label whose name isn't already present. Dedup is
    /// case-insensitive by `name` — matching how `autoMergeLabel` is compared
    /// everywhere else — so a `crow:merge`/`Crow:Merge` clash collapses to one
    /// entry rather than duplicating.
    nonisolated static func unionLabels(_ primary: [LabelInfo], _ secondary: [LabelInfo]) -> [LabelInfo] {
        guard !secondary.isEmpty else { return primary }
        var seen = Set(primary.map { $0.name.lowercased() })
        var out = primary
        for label in secondary where seen.insert(label.name.lowercased()).inserted {
            out.append(label)
        }
        return out
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
            // `findRecentPRsForBranches` doesn't recover partial data; route
            // its SAML failures to the same one-time warning instead of
            // spamming the console each cycle. (`prStates` recovers its
            // accessible aliases since #894, so it no longer lands here.)
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
    /// Returns minimal `ViewerPR` records — `state`, `url`, repo, branch refs,
    /// `labels`, and checks are populated; reviews and commits are left empty.
    /// Labels are fetched (#838) so a session-linked PR
    /// that flows through the stale path — rather than the open-viewer query —
    /// still carries its `crow:merge` label into `dedupedByURL`/`mergePRRecords`
    /// instead of shadowing the fresh label with an empty set. Checks are
    /// fetched for the same reason (#894): a PR past
    /// `viewer.pullRequests(first: 50)`, or one in a SAML-restricted org (a
    /// permanent hole in that connection), reaches the UI only through here, so
    /// without `statusCheckRollup` it could never show CI state at all.
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
    ///
    /// Copies every field. It previously dropped `mergeCommitOid` and
    /// `repoAutoMergeAllowed` — inert, because the only caller is the GitLab
    /// path where both are nil — but a "copy with one field changed" helper
    /// that silently loses fields is a trap that gets worse every time
    /// `PRRecord` grows.
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
            changesRequestedReviewerLogins: pr.changesRequestedReviewerLogins,
            hasPendingReviewRequest: pr.hasPendingReviewRequest,
            updatedAt: pr.updatedAt,
            mergeCommitOid: pr.mergeCommitOid,
            repoAutoMergeAllowed: pr.repoAutoMergeAllowed
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
        // Route through the shared, injected `store` — never a throwaway
        // `JSONStore()`. A fresh instance reads its own (possibly stale) disk
        // snapshot and its full-store write can silently clobber a session
        // another writer just added (#728).
        store.mutate { data in
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
        let repoSlug: String       // "corveil/crow"
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
    public nonisolated static func canAddMergeLabel(session: Session, providerManager: ProviderManager) -> Bool {
        let provider = session.codeProvider ?? session.provider ?? .github
        return providerManager.codeBackend(for: provider)?.capabilities.contains(.autoMergeLabel) ?? false
    }

    /// Whether `session` may be moved to a project-board "In Review" status —
    /// i.e. its **task** backend declares `.projectBoardStatus`. Mirrors the
    /// retired native `AppState.canSetProjectStatus(for:)` (GitHub Projects v2 /
    /// Jira: yes; GitLab: no — ADR 0005), which gated the "In Review" button.
    /// Restores that gate for the web UI (CROW-749). Pure — unit-tested like
    /// `canAddMergeLabel`.
    public nonisolated static func canSetProjectStatus(session: Session, providerManager: ProviderManager) -> Bool {
        guard let provider = session.provider else { return false }
        return providerManager.taskBackend(for: provider).capabilities.contains(.projectBoardStatus)
    }

    /// Instance convenience over ``canSetProjectStatus(session:providerManager:)``
    /// using this tracker's provider manager — the daemon's `list-sessions` gate.
    public func canSetProjectStatus(for session: Session) -> Bool {
        Self.canSetProjectStatus(session: session, providerManager: providerManager)
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
        // Route through the shared, injected `store` — never a throwaway
        // `JSONStore()`. A fresh instance reads its own (possibly stale) disk
        // snapshot and its full-store write can silently clobber a session
        // another writer just added (#728).
        store.mutate { data in
            data.links.append(contentsOf: newLinks)
        }
    }

    /// Resolve the org/repo slug (e.g. "corveil/citadel") from a worktree's git remote.
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

        applyAutoMerge(viewerPRs: viewerPRs)
        applyAutoRebase(viewerPRs: viewerPRs)
        applyAutoReRequestReview(viewerPRs: viewerPRs)
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
    private func logSteadyState(
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
                + "pendingRequest=\(status.hasPendingReviewRequest ? "yes" : "no"), "
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
    private func agentSettled(sessionID: UUID) -> Bool {
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
    nonisolated static func shouldAttemptAutoMerge(pr: ViewerPR, session: Session) -> Bool {
        autoMergeSkipReason(pr: pr, session: session) == nil
    }

    /// Why `pr` is not an auto-merge candidate, or `nil` when it is one.
    ///
    /// The reason exists so a skip leaves a trace: `shouldAttemptAutoMerge`
    /// used to collapse six distinct guards into a bare `false`, which is why
    /// "why wasn't this PR merged?" was unanswerable after the fact (CROW-782).
    /// `applyAutoMerge` logs the reason per PR each poll; the boolean helper
    /// above is derived from this one so the two can never disagree.
    ///
    /// Raw values are the strings that land in the automation log — keep them
    /// stable enough to grep for. The first six are the pure eligibility
    /// guards `autoMergeSkipReason` evaluates; the rest are runtime outcomes
    /// that used to live as bare string literals scattered across
    /// `applyAutoMerge` and `attemptEnableAutoMerge`. Folding them into one
    /// type is what lets a reason carry a human sentence and a permanence flag
    /// to the UI instead of dying in the log file (#888).
    enum AutoMergeSkipReason: String, Sendable {
        case alreadyEnabled = "already-enabled"
        case notOpen = "not-open"
        case draft = "draft"
        case noMergeLabel = "no-crow-merge-label"
        case conflicting = "conflicting"
        case changesRequested = "changes-requested"
        case inFlight = "in-flight"
        case notInViewerPRs = "not-in-viewer-prs"
        case updateBranchAlreadyAttempted = "update-branch-already-attempted-for-head"
        case noCrowSessionTrailer = "no-crow-session-trailer"
        case backendLacksAutoMerge = "backend-lacks-auto-merge-capability"
        case repoDisallowsAutoMerge = "repo-disallows-auto-merge"
        /// The repo forbids the host's auto-merge queue, so `--auto` can never
        /// succeed — but the PR isn't green enough for the direct-merge
        /// fallback *yet*. Transient by design: labels are usually applied
        /// while CI is still running, and latching here would freeze the PR
        /// before it could ever qualify. New with #888.
        case repoDisallowsAutoMergePending = "repo-disallows-auto-merge-not-yet-mergeable"
        /// The PR asks for auto-merge but the watcher itself is switched off, so
        /// nothing will ever look at it. New with #888: `applyAutoMerge`'s first
        /// guard returns before any per-PR bookkeeping, so this state was
        /// previously invisible except as one hourly global log line.
        case watcherOff = "watcher-off"
        /// The repo forbids the host's auto-merge queue and Crow's direct-merge
        /// fallback also failed. New with #888.
        case directMergeFailed = "direct-merge-failed"

        /// Whether retrying could change the outcome. Drives whether the UI
        /// warns loudly and whether a notification fires at all.
        var isPermanent: Bool {
            switch self {
            case .noCrowSessionTrailer, .backendLacksAutoMerge,
                 .repoDisallowsAutoMerge, .directMergeFailed:
                true
            case .alreadyEnabled, .notOpen, .draft, .noMergeLabel, .conflicting,
                 .changesRequested, .inFlight, .notInViewerPRs,
                 .updateBranchAlreadyAttempted, .watcherOff, .repoDisallowsAutoMergePending:
                false
            }
        }

        /// The verdict to publish for the UI, or `nil` to stay quiet.
        ///
        /// Deliberately silent for everything the PR pill *already* renders —
        /// a conflicting PR draws the conflict chip, a CHANGES_REQUESTED one
        /// draws a red review chip, an unlabeled one simply has no 🏷. Adding
        /// a second chip saying the same thing would be the exact "two surfaces
        /// disagreeing" failure CROW-773 consolidated the vocabulary to avoid.
        /// What's published is only what nothing else on screen can tell you.
        func state(repo: String) -> AutoMergeState? {
            switch self {
            case .notOpen, .draft, .noMergeLabel, .conflicting, .changesRequested:
                return nil
            case .alreadyEnabled:
                return AutoMergeState(
                    phase: .enabled, reason: rawValue,
                    message: "Auto-merge is enabled. GitHub will merge this PR once required "
                        + "reviews and checks pass.",
                    permanent: false)
            case .watcherOff:
                return AutoMergeState(
                    phase: .off, reason: rawValue,
                    message: "This PR is labeled crow:merge, but the auto-merge watcher is off, "
                        + "so nothing will merge it. Turn it on in Settings → Automation.",
                    permanent: false)
            case .inFlight:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "Crow is working on this PR's auto-merge right now.",
                    permanent: false)
            case .notInViewerPRs:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "This PR didn't appear in the last provider fetch, so Crow can't "
                        + "evaluate it. Usually a scope or rate-limit problem, not the PR itself.",
                    permanent: false)
            case .updateBranchAlreadyAttempted:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "Crow already tried to update this branch from its base at the "
                        + "current commit. It will re-evaluate once the branch moves.",
                    permanent: false)
            case .noCrowSessionTrailer:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "No commit on this PR carries a Crow-Session trailer matching a "
                        + "known session, so Crow won't merge it.",
                    permanent: true)
            case .backendLacksAutoMerge:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "This session's provider backend can't enable auto-merge.",
                    permanent: true)
            case .repoDisallowsAutoMergePending:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "\(repo.isEmpty ? "This repository" : repo) has GitHub's "
                        + "\"Allow auto-merge\" setting turned off, so Crow will merge this PR "
                        + "itself once checks pass and it's approved.",
                    permanent: false)
            case .repoDisallowsAutoMerge:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "\(repo.isEmpty ? "This repository" : repo) has GitHub's "
                        + "\"Allow auto-merge\" setting turned off, and the PR isn't in a state "
                        + "Crow can safely merge directly. Enable it in the repo's "
                        + "Settings → General, or merge by hand.",
                    permanent: true)
            case .directMergeFailed:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "\(repo.isEmpty ? "This repository" : repo) forbids GitHub "
                        + "auto-merge and Crow's direct merge failed. Check the PR on GitHub — "
                        + "Crow will not retry.",
                    permanent: true)
            }
        }
    }

    nonisolated static func autoMergeSkipReason(pr: ViewerPR, session: Session) -> AutoMergeSkipReason? {
        guard session.autoMergeEnabledAt == nil else { return .alreadyEnabled }
        guard pr.state == "OPEN" else { return .notOpen }
        guard !pr.isDraft else { return .draft }
        guard pr.labels.contains(where: { $0.name.caseInsensitiveCompare(autoMergeLabel) == .orderedSame }) else { return .noMergeLabel }
        guard pr.mergeable != "CONFLICTING" else { return .conflicting }
        guard pr.reviewDecision != "CHANGES_REQUESTED" else { return .changesRequested }
        return nil
    }

    /// Whether `pr` carries the `crow:merge` label. Split out of
    /// `autoMergeSkipReason` so the watcher-off path can tell "the user asked
    /// for auto-merge and nothing is listening" apart from "this PR was never
    /// labeled", without re-running the whole guard chain (#888).
    nonisolated static func hasAutoMergeLabel(pr: ViewerPR) -> Bool {
        pr.labels.contains { $0.name.caseInsensitiveCompare(autoMergeLabel) == .orderedSame }
    }

    /// True when `gh pr merge --auto` failed for a permanent repo/policy
    /// reason that will not clear on retry — specifically when the repo has
    /// GitHub "Allow auto-merge" disabled. Keyed on the policy phrase only:
    /// `gh` embeds the GraphQL mutation name `enablePullRequestAutoMerge` in
    /// *every* error from that mutation (including transient ones like
    /// "Pull request is in clean status"), so matching the bare field name
    /// would freeze retryable cases for the process lifetime (CROW-621).
    nonisolated static func isPermanentAutoMergeFailure(_ error: Error) -> Bool {
        let message: String
        if case ShellRunnerError.nonZeroExit(_, let output) = error {
            message = output
        } else {
            message = error.localizedDescription
        }
        return message.localizedCaseInsensitiveContains("Auto merge is not allowed for this repository")
    }

    /// The green-state gates a PR must clear before Crow will merge it *itself*.
    ///
    /// `shouldAttemptAutoMerge` is a much weaker bar on purpose: that path hands
    /// GitHub a queued request and lets GitHub enforce required checks and
    /// reviews before anything lands. A direct merge has no such backstop — it
    /// merges now — so every gate GitHub would have applied has to be re-checked
    /// here (#888).
    ///
    /// `mergeStateStatus == "CLEAN"` is GitHub's own "the merge button is
    /// green", which already excludes `BLOCKED`, `UNSTABLE`, `BEHIND`,
    /// `HAS_HOOKS` and `DIRTY`. The other three gates are deliberate belt and
    /// braces: this predicate is the only thing standing between a labeled PR
    /// and an irreversible merge, so it re-states rather than infers.
    ///
    /// Known narrowing: a repo with no required reviewers reports
    /// `reviewDecision == ""`, so the fallback stays out of its way entirely.
    /// Refusing to merge something a human never approved is the right side to
    /// err on.
    nonisolated static func directMergeGatesPass(pr: ViewerPR, session: Session) -> Bool {
        guard shouldAttemptAutoMerge(pr: pr, session: session) else { return false }
        guard pr.mergeStateStatus == "CLEAN" else { return false }
        guard pr.mergeable == "MERGEABLE" else { return false }
        guard pr.checksState == "SUCCESS" else { return false }
        guard pr.reviewDecision == "APPROVED" else { return false }
        return true
    }

    /// Whether Crow should merge `pr` directly instead of enabling auto-merge,
    /// because the repo has GitHub's "Allow auto-merge" setting off.
    ///
    /// Gated on an *explicit* `false`: `repoAutoMergeAllowed` is `nil` whenever
    /// the field wasn't fetched (GitLab, a partial SAML recovery, a cached
    /// record from before #888), and treating unknown as "forbidden" would turn
    /// every such PR into a direct merge — precisely the blast radius this
    /// feature must not have.
    nonisolated static func shouldDirectMerge(pr: ViewerPR, session: Session) -> Bool {
        guard pr.repoAutoMergeAllowed == false else { return false }
        return directMergeGatesPass(pr: pr, session: session)
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

    /// Merge freshly parsed trailer UUIDs into the PR's attribution record
    /// (#693). Returns the record to persist, or nil when no write is
    /// needed: no trailers and no existing record, or nothing material
    /// changed since the last capture. `sessionIDs` is a monotonic ordered
    /// union — IDs observed once are never dropped, even if a rebase removes
    /// the commit that carried them. All parsed UUIDs are kept, known
    /// session or not; the auto-merge gate's known-session filter is a
    /// separate concern (`crowAuthored`). Pure so unit tests can exercise
    /// the merge without spinning up an `IssueTracker`.
    ///
    /// #694 additions: `parsedCommitSHAs` (branch commit SHAs from the same
    /// fetch that produced the trailers) union into `commitSHAs` — same
    /// monotonic semantics as `sessionIDs`, capped at `maxStoredCommitSHAs`;
    /// `mergeCommitSHA` and `closedAt` are stamped once, at the first
    /// MERGED/CLOSED observation, mirroring `mergedAt`.
    nonisolated static func capturedAttribution(
        existing: PRSessionAttribution?,
        pr: ViewerPR,
        parsedSessionIDs: [UUID],
        parsedCommitSHAs: [String] = [],
        now: Date
    ) -> PRSessionAttribution? {
        guard var attribution = existing else {
            guard !parsedSessionIDs.isEmpty else { return nil }
            var deduped: [UUID] = []
            for id in parsedSessionIDs where !deduped.contains(id) { deduped.append(id) }
            var dedupedSHAs: [String] = []
            for sha in parsedCommitSHAs where !sha.isEmpty && !dedupedSHAs.contains(sha) {
                guard dedupedSHAs.count < maxStoredCommitSHAs else { break }
                dedupedSHAs.append(sha)
            }
            return PRSessionAttribution(
                prURL: pr.url,
                repoNameWithOwner: pr.repoNameWithOwner,
                prNumber: pr.number,
                sessionIDs: deduped,
                state: pr.state,
                mergedAt: pr.state == "MERGED" ? now : nil,
                firstSeenAt: now,
                updatedAt: now,
                commitSHAs: dedupedSHAs.isEmpty ? nil : dedupedSHAs,
                mergeCommitSHA: pr.state == "MERGED" ? pr.mergeCommitOid : nil,
                closedAt: pr.state == "CLOSED" ? now : nil
            )
        }
        for id in parsedSessionIDs where !attribution.sessionIDs.contains(id) {
            attribution.sessionIDs.append(id)
        }
        var shas = attribution.commitSHAs ?? []
        for sha in parsedCommitSHAs where !sha.isEmpty && !shas.contains(sha) {
            guard shas.count < maxStoredCommitSHAs else { break }
            shas.append(sha)
        }
        attribution.commitSHAs = shas.isEmpty ? nil : shas
        attribution.state = pr.state
        if pr.state == "MERGED" && attribution.mergedAt == nil {
            attribution.mergedAt = now
        }
        if pr.state == "MERGED" && attribution.mergeCommitSHA == nil {
            attribution.mergeCommitSHA = pr.mergeCommitOid
        }
        if pr.state == "CLOSED" && attribution.closedAt == nil {
            attribution.closedAt = now
        }
        guard attribution.sessionIDs != existing?.sessionIDs
            || attribution.state != existing?.state
            || attribution.mergedAt != existing?.mergedAt
            || attribution.commitSHAs != existing?.commitSHAs
            || attribution.mergeCommitSHA != existing?.mergeCommitSHA
            || attribution.closedAt != existing?.closedAt else { return nil }
        attribution.updatedAt = now
        return attribution
    }

    /// Refresh the state of already-attributed PRs from a polled PR list
    /// (#693). Returns only the entries that changed; `mergedAt` is stamped
    /// once, at the first MERGED observation, and never moved. Never creates
    /// entries — attribution requires a trailer parse, which happens in
    /// `recordPRAttribution`. Pure for testability.
    nonisolated static func attributionStateUpdates(
        existing: [String: PRSessionAttribution],
        prs: [ViewerPR],
        now: Date
    ) -> [String: PRSessionAttribution] {
        var updates: [String: PRSessionAttribution] = [:]
        for pr in prs {
            guard let updated = capturedAttribution(
                existing: existing[pr.url], pr: pr, parsedSessionIDs: [], now: now
            ) else { continue }
            updates[pr.url] = updated
        }
        return updates
    }

    /// Resync the read-only AppState mirror after a `prAttributions`
    /// mutation, so the scorecard's v2 combined score (#699) sees the write.
    private func syncPRAttributionMirror() {
        appState.prAttributions = store.data.prAttributions ?? [:]
    }

    /// Persist the PR→session mapping parsed from the PR's commits (#693).
    /// Called from `prHasCrowAuthoredCommit` so attribution rides along with
    /// the existing trailer parse; the gate's boolean result is unaffected.
    /// #694: also unions the commit SHAs into the record (revert-detection
    /// targets) and scans the same commit messages for reverts of *other*
    /// attributed PRs in the same repo — a revert PR entering the auto-merge
    /// flow is the cheapest place to observe one.
    func recordPRAttribution(pr: ViewerPR, commits: [CommitInfo], now: Date = Date()) {
        let parsed = commits.flatMap { Self.extractCrowSessionUUIDs(from: $0.message) }
        let existingAll = store.data.prAttributions ?? [:]
        let attribution = Self.capturedAttribution(
            existing: existingAll[pr.url],
            pr: pr,
            parsedSessionIDs: parsed,
            parsedCommitSHAs: commits.map(\.sha),
            now: now
        )
        let revertUpdates = Self.revertDetections(
            commits: commits,
            attributions: existingAll,
            repo: pr.repoNameWithOwner,
            excludingPRURL: pr.url,
            sourcePRURL: pr.url,
            now: now
        )
        guard attribution != nil || !revertUpdates.isEmpty else { return }
        store.mutate { data in
            var attributions = data.prAttributions ?? [:]
            if let attribution { attributions[pr.url] = attribution }
            for (url, records) in revertUpdates {
                guard var target = attributions[url] else { continue }
                target.reverts = (target.reverts ?? []) + records
                target.updatedAt = now
                attributions[url] = target
            }
            data.prAttributions = attributions
        }
        syncPRAttributionMirror()
    }

    /// Update stored attribution state from a refresh cycle's PR list
    /// (#693). Once merged, a PR leaves the auto-merge/rebase flow (the
    /// only place commits are fetched), so state transitions — and the
    /// observed merge timestamp — are recorded here instead.
    func updatePRAttributions(viewerPRs: [ViewerPR], now: Date = Date()) {
        let existing = store.data.prAttributions ?? [:]
        guard !existing.isEmpty else { return }
        let updates = Self.attributionStateUpdates(existing: existing, prs: viewerPRs, now: now)
        guard !updates.isEmpty else { return }
        store.mutate { data in
            var attributions = data.prAttributions ?? [:]
            for (url, attribution) in updates { attributions[url] = attribution }
            data.prAttributions = attributions
        }
        syncPRAttributionMirror()
    }

    // MARK: - Rework / merge-rate metrics (#694, ADR 0008 follow-up 6)

    /// Max age of a fix PR's merge relative to the fixed PR's merge for the
    /// fix to count as post-merge rework. 48h: long enough to catch the
    /// "shipped Friday, hotfixed Monday" pattern the signal exists for,
    /// short enough that routine follow-on work in a hot file doesn't read
    /// as rework. Tunable prior per the ADR's calibration rule.
    nonisolated static let postMergeFixWindow: TimeInterval = 48 * 3600

    /// Minimum gap between default-branch revert scans. The scan is one
    /// REST call per repo with recent attributed merges; 30 min keeps that
    /// negligible next to the 60s poll while still surfacing reverts the
    /// same half-hour they land.
    nonisolated static let revertScanInterval: TimeInterval = 30 * 60

    /// How far back a merged attribution keeps its repo in the revert scan,
    /// and the `since` horizon of each scan. Reverts of two-week-old merges
    /// are vanishingly rare, and the scan is single-page — a longer horizon
    /// would silently truncate on busy repos rather than see more.
    nonisolated static let revertScanLookback: TimeInterval = 14 * 24 * 3600

    /// Cap on stored branch commit SHAs per attribution (`commitSHAs`).
    nonisolated static let maxStoredCommitSHAs = 100

    /// Cap on stored changed-file paths per attribution (`changedFiles`).
    nonisolated static let maxStoredChangedFiles = 200

    /// Shortest SHA prefix accepted by `shaMatches` — git's abbreviated-SHA
    /// convention. Anything shorter is too collision-prone to stamp rework on.
    nonisolated static let revertSHAMinPrefixLength = 7

    /// Pattern matching git's conventional revert body line. Anchored to
    /// line start (multiline) like the Crow-Session trailer pattern; the
    /// captured group is the reverted commit's (possibly abbreviated) SHA.
    /// GitHub's Revert button and `git revert` both emit this line; the
    /// trailing `\b` tolerates GitHub's closing period.
    nonisolated private static let revertLinePattern = #"^This reverts commit ([0-9A-Fa-f]{7,40})\b"#

    /// Extract every reverted-commit SHA from a commit message. Returns an
    /// empty array when no revert lines match. Pure for testability;
    /// compiles per call for the same Sendable reason as
    /// `extractCrowSessionUUIDs`.
    nonisolated static func extractRevertedCommitSHAs(from message: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: revertLinePattern,
            options: [.anchorsMatchLines]
        ) else { return [] }
        let range = NSRange(message.startIndex..., in: message)
        var result: [String] = []
        regex.enumerateMatches(in: message, range: range) { match, _, _ in
            guard let m = match,
                  let shaRange = Range(m.range(at: 1), in: message) else { return }
            result.append(String(message[shaRange]))
        }
        return result
    }

    /// Case-insensitive abbreviated-SHA comparison: true when either value
    /// is a prefix of the other and the shorter is at least
    /// `revertSHAMinPrefixLength` chars. Revert messages may carry either
    /// the full or an abbreviated SHA depending on how they were authored.
    nonisolated static func shaMatches(_ a: String, _ b: String) -> Bool {
        guard min(a.count, b.count) >= revertSHAMinPrefixLength else { return false }
        let la = a.lowercased(), lb = b.lowercased()
        return la.hasPrefix(lb) || lb.hasPrefix(la)
    }

    /// All SHAs a revert of `attribution` could name: the merge/squash
    /// commit (Crow's own merges are squashes, so this is the primary
    /// target) plus the branch commits (merge-commit/rebase strategies).
    nonisolated private static func revertTargets(of attribution: PRSessionAttribution) -> [String] {
        var targets = attribution.commitSHAs ?? []
        if let mergeSHA = attribution.mergeCommitSHA { targets.append(mergeSHA) }
        return targets
    }

    /// Scan `commits` for conventional revert lines naming a stored SHA of
    /// a same-repo attribution, and return the new `PRRevertRecord`s to
    /// append, keyed by the reverted attribution's PR URL. Pure; callers
    /// persist. Dedupe: a target attribution gains at most one record per
    /// `revertedCommitSHA` (prefix-tolerant), across both its existing
    /// records and this batch — so a revert observed first via its PR's
    /// commit fetch and again via the default-branch scan stamps once.
    /// Skips:
    /// - `excludingPRURL` (a PR's own commit fetch never reverts itself);
    /// - self-reverts: the reverting commit is one of the target's own SHAs
    ///   (an in-PR revert of an in-PR commit is internal churn, not rework).
    nonisolated static func revertDetections(
        commits: [CommitInfo],
        attributions: [String: PRSessionAttribution],
        repo: String,
        excludingPRURL: String?,
        sourcePRURL: String?,
        now: Date
    ) -> [String: [PRRevertRecord]] {
        var updates: [String: [PRRevertRecord]] = [:]
        for commit in commits {
            let targets = extractRevertedCommitSHAs(from: commit.message)
            guard !targets.isEmpty else { continue }
            for (url, attribution) in attributions {
                guard attribution.repoNameWithOwner == repo, url != excludingPRURL else { continue }
                let ownSHAs = revertTargets(of: attribution)
                // Self-revert guard: the reverting commit belongs to the
                // attribution it would be stamped on.
                guard !commit.sha.isEmpty,
                      !ownSHAs.contains(where: { shaMatches($0, commit.sha) }) else { continue }
                for target in targets {
                    guard ownSHAs.contains(where: { shaMatches($0, target) }) else { continue }
                    let already = (attribution.reverts ?? []) + (updates[url] ?? [])
                    guard !already.contains(where: { shaMatches($0.revertedCommitSHA, target) }) else { continue }
                    updates[url, default: []].append(PRRevertRecord(
                        revertedCommitSHA: target,
                        revertCommitSHA: commit.sha,
                        sourcePRURL: sourcePRURL,
                        detectedAt: now
                    ))
                }
            }
        }
        return updates
    }

    /// Detect post-merge fixes across the attribution store and return the
    /// new `PostMergeFixRecord`s to append, keyed by the *fixed* PR's URL.
    /// Pure; callers persist. The heuristic is documented on
    /// `PostMergeFixRecord`; in short — fix PR B stamps merged PR A when B
    /// is same-repo, first seen after A merged, itself merged within
    /// `postMergeFixWindow`, shares a changed file with A, and is not A's
    /// revert. Records dedupe by `fixPRURL`.
    nonisolated static func postMergeFixDetections(
        attributions: [String: PRSessionAttribution],
        now: Date
    ) -> [String: [PostMergeFixRecord]] {
        var updates: [String: [PostMergeFixRecord]] = [:]
        for (urlA, a) in attributions {
            guard a.state == "MERGED", let aMergedAt = a.mergedAt,
                  let aFiles = a.changedFiles, !aFiles.isEmpty else { continue }
            let aFileSet = Set(aFiles)
            let aRevertSHAs = (a.reverts ?? []).map(\.revertCommitSHA)
            for (urlB, b) in attributions {
                guard urlB != urlA, b.repoNameWithOwner == a.repoNameWithOwner else { continue }
                guard b.firstSeenAt > aMergedAt else { continue }
                guard let bMergedAt = b.mergedAt,
                      bMergedAt.timeIntervalSince(aMergedAt) <= postMergeFixWindow else { continue }
                guard let bFiles = b.changedFiles else { continue }
                let overlap = aFileSet.intersection(bFiles).count
                guard overlap > 0 else { continue }
                // A revert counts exactly once, as a revert — never also as
                // a post-merge fix. Revert stamping runs before this pass.
                let isRevertOfA = (a.reverts ?? []).contains { $0.sourcePRURL == urlB }
                    || revertTargets(of: b).contains { bSHA in
                        aRevertSHAs.contains { shaMatches($0, bSHA) }
                    }
                guard !isRevertOfA else { continue }
                guard !(a.postMergeFixes ?? []).contains(where: { $0.fixPRURL == urlB }) else { continue }
                updates[urlA, default: []].append(PostMergeFixRecord(
                    fixPRURL: urlB,
                    overlappingFileCount: overlap,
                    detectedAt: now
                ))
            }
        }
        return updates
    }

    /// Fetch and store changed-file paths for attributed PRs newly observed
    /// as MERGED (#694). One REST call per PR, once per process (the
    /// `changedFilesFetchAttempted` guard) — a merge is a rare event, and a
    /// failed fetch retries on the next launch rather than every poll.
    /// GitHub-hosted PRs only; other providers' backends return `[]` and
    /// aren't worth the call. Merges older than `revertScanLookback` are
    /// skipped: backfilling files for ancient merges would let the fix
    /// detector stamp long-settled PR pairs with a fresh `detectedAt`,
    /// polluting the current window.
    func captureChangedFilesForNewMerges(now: Date = Date()) async {
        let attributions = store.data.prAttributions ?? [:]
        let cutoff = now.addingTimeInterval(-Self.revertScanLookback)
        let pending = attributions.values.filter { attribution in
            attribution.state == "MERGED"
                && attribution.changedFiles == nil
                && (attribution.mergedAt ?? .distantPast) >= cutoff
                && !changedFilesFetchAttempted.contains(attribution.prURL)
                && URL(string: attribution.prURL)?.host == "github.com"
        }
        guard !pending.isEmpty,
              let backend = providerManager.codeBackend(for: .github) else { return }
        for attribution in pending {
            changedFilesFetchAttempted.insert(attribution.prURL)
            let files: [String]
            do {
                files = try await backend.fetchPRChangedFiles(
                    repoSlug: attribution.repoNameWithOwner,
                    prNumber: attribution.prNumber
                )
            } catch {
                CrowLog.info("[Crow] fetchPRChangedFiles failed for \(attribution.prURL): \(error.localizedDescription)")
                continue
            }
            guard !files.isEmpty else { continue }
            let capped = Array(files.prefix(Self.maxStoredChangedFiles))
            let now = Date()
            store.mutate { data in
                var attributions = data.prAttributions ?? [:]
                guard var target = attributions[attribution.prURL],
                      target.changedFiles == nil else { return }
                target.changedFiles = capped
                target.updatedAt = now
                attributions[attribution.prURL] = target
                data.prAttributions = attributions
            }
            syncPRAttributionMirror()
        }
    }

    /// Scan the default branch of every repo with a recently merged
    /// attribution for revert commits (#694). Catches reverts that never
    /// pass through Crow's PR flow — direct pushes and reverts merged by
    /// others. Throttled to `revertScanInterval`; single page of recent
    /// commits per repo, idempotent via the detections dedupe.
    func scanDefaultBranchesForReverts(now: Date = Date()) async {
        if let last = lastRevertScanAt, now.timeIntervalSince(last) < Self.revertScanInterval { return }
        lastRevertScanAt = now
        let attributions = store.data.prAttributions ?? [:]
        let since = now.addingTimeInterval(-Self.revertScanLookback)
        let repos = Set(attributions.values
            .filter { attribution in
                guard let mergedAt = attribution.mergedAt, mergedAt >= since else { return false }
                return URL(string: attribution.prURL)?.host == "github.com"
            }
            .map(\.repoNameWithOwner))
        guard !repos.isEmpty,
              let backend = providerManager.codeBackend(for: .github) else { return }
        for repo in repos.sorted() {
            let commits: [CommitInfo]
            do {
                commits = try await backend.fetchRecentDefaultBranchCommits(repoSlug: repo, since: since)
            } catch {
                CrowLog.info("[Crow] fetchRecentDefaultBranchCommits failed for \(repo): \(error.localizedDescription)")
                continue
            }
            // Re-read inside the loop so a prior repo's writes are visible.
            let current = store.data.prAttributions ?? [:]
            let updates = Self.revertDetections(
                commits: commits,
                attributions: current,
                repo: repo,
                excludingPRURL: nil,
                sourcePRURL: nil,
                now: now
            )
            guard !updates.isEmpty else { continue }
            store.mutate { data in
                var attributions = data.prAttributions ?? [:]
                for (url, records) in updates {
                    guard var target = attributions[url] else { continue }
                    target.reverts = (target.reverts ?? []) + records
                    target.updatedAt = now
                    attributions[url] = target
                }
                data.prAttributions = attributions
            }
            syncPRAttributionMirror()
        }
    }

    /// Run post-merge-fix detection over the attribution store and persist
    /// new records (#694). Pure store pass — no API calls; runs after
    /// revert stamping each refresh so rule 4 (a revert is never also a
    /// fix) sees the freshest revert records.
    func detectPostMergeFixes(now: Date = Date()) {
        let attributions = store.data.prAttributions ?? [:]
        guard !attributions.isEmpty else { return }
        let updates = Self.postMergeFixDetections(attributions: attributions, now: now)
        guard !updates.isEmpty else { return }
        store.mutate { data in
            var attributions = data.prAttributions ?? [:]
            for (url, records) in updates {
                guard var target = attributions[url] else { continue }
                target.postMergeFixes = (target.postMergeFixes ?? []) + records
                target.updatedAt = now
                attributions[url] = target
            }
            data.prAttributions = attributions
        }
        syncPRAttributionMirror()
    }

    /// Per-refresh entry point. Picks candidate (session, PR) pairs and
    /// kicks off the async enable flow once each. Publishes a per-session
    /// verdict to `appState.autoMergeState` on the way through, so the reason a
    /// PR didn't merge reaches the UI and not just the automation log (#888).
    /// No-op (beyond publishing an `off` verdict) when the global
    /// `autoMergeWatcherEnabled` setting is off.
    private func applyAutoMerge(viewerPRs: [ViewerPR]) {
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        guard autoMergeWatcherEnabledProvider() else {
            // Durable, not silent: this exact early return is how the tmux-gated
            // wiring regression went dark for weeks (CROW-782). Rate-limited to
            // once per hour so an intentionally-disabled watcher doesn't spam.
            logAutoMergeDisabledIfDue()
            // The log line is global; the verdict is per-PR. Someone who just
            // applied `crow:merge` needs to see *on that session* that nothing
            // is listening — that specific confusion is the whole of #888.
            for session in appState.sessions where !session.isManager {
                guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }),
                      let pr = byURL[prLink.url],
                      Self.hasAutoMergeLabel(pr: pr) else {
                    appState.autoMergeState.removeValue(forKey: session.id)
                    continue
                }
                publishAutoMergeVerdict(.watcherOff, session: session, pr: pr)
            }
            return
        }
        guard !viewerPRs.isEmpty else {
            CrowLog.automation("auto-merge: no viewer PRs in this poll's fetch — nothing to evaluate")
            return
        }

        var enabledCount = 0
        var updateBranchCount = 0
        var directMergeCount = 0
        var skips: [String] = []

        for session in appState.sessions where !session.isManager {
            guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else {
                appState.autoMergeState.removeValue(forKey: session.id)
                continue
            }
            guard !autoMergeInFlight.contains(prLink.url) else {
                // A permanent outcome keeps its marker set on purpose — report
                // the reason it stopped, not the bare marker (review #787).
                let latched = autoMergePermanentSkips[prLink.url]
                    .flatMap(AutoMergeSkipReason.init(rawValue:)) ?? .inFlight
                skips.append("\(prLink.url):\(latched.rawValue)")
                // The async attempt publishes its own verdict; don't overwrite a
                // richer one with the bare in-flight marker.
                if appState.autoMergeState[session.id] == nil {
                    publishAutoMergeVerdict(latched, session: session, pr: byURL[prLink.url])
                }
                continue
            }
            guard let pr = byURL[prLink.url] else {
                // The PR is linked to a live session but absent from the
                // viewer-PR fetch — a fetch/scope problem, not an eligibility
                // one, and invisible before CROW-782. The log line is
                // unconditional (it's fetch health, not an auto-merge verdict);
                // the *chip* is not.
                skips.append("\(prLink.url):\(AutoMergeSkipReason.notInViewerPRs.rawValue)")
                // Only speak auto-merge vocabulary about a PR that actually
                // asked for auto-merge. `pr` is nil here, so the label can't be
                // read off the record — fall back to what we already know:
                // the last fetch that *did* see it, or the fact that Crow has
                // already armed it. Without that, an ordinary feature PR aging
                // out of the 50-most-recently-updated window would grow an
                // "Auto-merge waiting" chip it never earned — the exact class
                // of misleading signal #888 exists to remove (review #899).
                let everArmed = appState.prStatus[session.id]?.hasMergeLabel == true
                    || session.autoMergeEnabledAt != nil
                if everArmed {
                    publishAutoMergeVerdict(.notInViewerPRs, session: session, pr: nil)
                } else {
                    appState.autoMergeState.removeValue(forKey: session.id)
                }
                continue
            }
            if let reason = Self.autoMergeSkipReason(pr: pr, session: session) {
                skips.append("#\(pr.number):\(reason.rawValue)")
                publishAutoMergeVerdict(reason, session: session, pr: pr)
                continue
            }

            let capturedSession = session
            if Self.shouldDirectMerge(pr: pr, session: session) {
                // The repo forbids GitHub's auto-merge queue, so `--auto` can
                // never succeed here — but the PR is green and approved, which
                // is exactly the case that used to sit labeled forever (#888).
                autoMergeInFlight.insert(prLink.url)
                directMergeCount += 1
                Task { await self.attemptDirectMerge(session: capturedSession, pr: pr) }
            } else if Self.shouldUpdateBranchBeforeMerge(pr: pr, session: session) {
                // Behind base: bring the branch up to date this turn instead
                // of merging. One attempt per head commit (loop safety); the
                // next poll re-evaluates once GitHub recomputes mergeability.
                let key = "\(prLink.url)\n\(pr.headRefOid)"
                guard !autoUpdateBranchAttempted.contains(key) else {
                    skips.append("#\(pr.number):\(AutoMergeSkipReason.updateBranchAlreadyAttempted.rawValue)")
                    publishAutoMergeVerdict(.updateBranchAlreadyAttempted, session: session, pr: pr)
                    continue
                }
                autoUpdateBranchAttempted.insert(key)
                autoMergeInFlight.insert(prLink.url)
                updateBranchCount += 1
                Task { await self.attemptUpdateBranch(session: capturedSession, pr: pr) }
            } else if pr.repoAutoMergeAllowed == false {
                // Repo forbids auto-merge, so `enableAutoMerge` can never
                // succeed — but the PR isn't green enough for a direct merge
                // *yet*. Deliberately NOT latched: labels are usually applied
                // while CI is still running, so latching here would freeze the
                // PR before it ever had a chance to qualify for the fallback,
                // which is the case #888 exists to fix. Re-evaluated every poll.
                skips.append("#\(pr.number):\(AutoMergeSkipReason.repoDisallowsAutoMergePending.rawValue)")
                publishAutoMergeVerdict(.repoDisallowsAutoMergePending, session: session, pr: pr)
            } else {
                autoMergeInFlight.insert(prLink.url)
                enabledCount += 1
                Task { await self.attemptEnableAutoMerge(session: capturedSession, pr: pr) }
            }
        }

        // One line per poll, always — an empty candidate set is itself the
        // answer to "why didn't my PR merge?" (CROW-782).
        let skipDetail = skips.isEmpty ? "" : " [\(skips.joined(separator: ", "))]"
        CrowLog.automation(
            "auto-merge: dispatched=\(enabledCount) updateBranch=\(updateBranchCount) "
            + "directMerge=\(directMergeCount) skipped=\(skips.count)\(skipDetail)")
    }

    /// Record a verdict for the session's PR pill, and push a notification the
    /// first time a permanent one appears.
    ///
    /// `nil` from `state(repo:)` means "something else on screen already says
    /// this" — a conflicting PR draws the conflict chip, an unlabeled one has
    /// no 🏷 — so we clear rather than add a redundant second signal.
    private func publishAutoMergeVerdict(
        _ reason: AutoMergeSkipReason, session: Session, pr: ViewerPR?
    ) {
        let repo = pr?.repoNameWithOwner ?? ""
        guard let state = reason.state(repo: repo) else {
            appState.autoMergeState.removeValue(forKey: session.id)
            clearAutoMergeBlockNotifications(prURL: pr?.url)
            return
        }
        appState.autoMergeState[session.id] = state
        guard state.phase == .blocked, let pr else {
            // Only a permanent block is worth interrupting someone for. A
            // stalled verdict resolves itself; `off` is a setting they chose.
            if state.phase != .blocked { clearAutoMergeBlockNotifications(prURL: pr?.url) }
            return
        }
        let key = "\(pr.url)\n\(state.reason)"
        guard autoMergeBlockNotified.insert(key).inserted else { return }
        onAutoMergeBlocked?(session.id, pr.url, pr.number, state)
    }

    /// Drop a PR's notification latches so a block that gets fixed and then
    /// recurs is announced again rather than swallowed for the process
    /// lifetime.
    private func clearAutoMergeBlockNotifications(prURL: String?) {
        guard let prURL else { return }
        autoMergeBlockNotified = autoMergeBlockNotified.filter { !$0.hasPrefix("\(prURL)\n") }
    }

    /// Emit the "watcher disabled" line at most once an hour. `nil` until the
    /// first emission, so a daemon that starts with the watcher off says so
    /// immediately.
    private func logAutoMergeDisabledIfDue() {
        let now = Date()
        if let last = lastAutoMergeDisabledLogAt, now.timeIntervalSince(last) < 3600 { return }
        lastAutoMergeDisabledLogAt = now
        CrowLog.automation(
            "auto-merge: skipped entirely — autoMergeWatcherEnabledProvider() is false "
            + "(config `autoMergeWatcherEnabled` off, or the provider was never wired)")
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
    /// `Session.autoMergeEnabledAt`. Transient failure clears the in-flight
    /// marker so the next poll retries; permanent/expected failure (repo
    /// disallows auto-merge) leaves it set and logs once (CROW-621).
    private func attemptEnableAutoMerge(session: Session, pr: ViewerPR) async {
        guard let backend = codeBackend(for: session) else {
            autoMergeInFlight.remove(pr.url)
            return
        }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            // Leaves `autoMergeInFlight` set (one log line, not one per poll);
            // record why so the summary doesn't just say "in-flight" forever.
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.noCrowSessionTrailer.rawValue
            CrowLog.automation("auto-merge: #\(pr.number) ignored — no Crow-Session trailer matching a known session")
            publishAutoMergeVerdict(.noCrowSessionTrailer, session: session, pr: pr)
            return
        }

        await ensureMergeLabel(repo: pr.repoNameWithOwner, backend: backend)

        guard backend.capabilities.contains(.autoMerge) else {
            // Capability gate: don't even try if the backend can't enable
            // auto-merge. A backend's capability set is static, so this is
            // permanent — keep the in-flight marker (with its reason) rather
            // than clearing it and re-running the authorship commit fetch, and
            // re-logging, on every 60s poll (review #787).
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.backendLacksAutoMerge.rawValue
            CrowLog.automation("auto-merge: #\(pr.number) skipped — backend lacks the autoMerge capability")
            publishAutoMergeVerdict(.backendLacksAutoMerge, session: session, pr: pr)
            return
        }
        do {
            try await backend.enableAutoMerge(prURL: pr.url)
            recordAutoMergeSuccess(session: session, pr: pr, phase: .enabled, detail: "squash")
        } catch {
            if Self.isPermanentAutoMergeFailure(error) {
                // The repo forbids auto-merge and GraphQL didn't tell us in
                // time (an older cached record, or a fetch that omitted
                // `autoMergeAllowed`). We've now *proven* it, so the
                // direct-merge fallback's repo precondition is satisfied —
                // check only the green-state gates (#888).
                if Self.directMergeGatesPass(pr: pr, session: session) {
                    CrowLog.automation(
                        "auto-merge: #\(pr.number) repo disallows auto-merge — falling back to a direct squash merge")
                    await performDirectMerge(session: session, pr: pr, backend: backend)
                    return
                }
                // Leave `autoMergeInFlight` set so subsequent polls skip this
                // PR instead of re-logging a permanent repo policy failure.
                autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.repoDisallowsAutoMerge.rawValue
                CrowLog.automation(
                    "auto-merge: #\(pr.number) permanently skipped (auto-merge not allowed on repo): "
                    + error.localizedDescription)
                publishAutoMergeVerdict(.repoDisallowsAutoMerge, session: session, pr: pr)
            } else {
                autoMergeInFlight.remove(pr.url)
                autoMergePermanentSkips[pr.url] = nil
                CrowLog.automation(
                    "auto-merge: #\(pr.number) enableAutoMerge failed (will retry next poll): "
                    + error.localizedDescription)
            }
        }
    }

    /// Merge the PR outright, because its repo has GitHub's "Allow auto-merge"
    /// setting off and `enableAutoMerge` could therefore never succeed (#888).
    ///
    /// Eligibility was decided by `shouldDirectMerge` before dispatch; this
    /// re-verifies Crow authorship, exactly like the auto-merge path, so a PR
    /// nobody's Crow session wrote is never merged by Crow.
    private func attemptDirectMerge(session: Session, pr: ViewerPR) async {
        guard let backend = codeBackend(for: session) else {
            autoMergeInFlight.remove(pr.url)
            return
        }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.noCrowSessionTrailer.rawValue
            CrowLog.automation(
                "auto-merge: #\(pr.number) direct merge skipped — no Crow-Session trailer matching a known session")
            publishAutoMergeVerdict(.noCrowSessionTrailer, session: session, pr: pr)
            return
        }
        CrowLog.automation(
            "auto-merge: #\(pr.number) \(pr.repoNameWithOwner) disallows auto-merge — "
            + "falling back to a direct squash merge")
        await performDirectMerge(session: session, pr: pr, backend: backend)
    }

    /// The direct merge itself. Split from `attemptDirectMerge` so the
    /// `enableAutoMerge` catch path — which has just *proven* the repo forbids
    /// auto-merge, and has already checked authorship — can reuse it without
    /// re-fetching the PR's commits.
    ///
    /// **Every** failure is latched as permanent, deliberately — including a
    /// transient one. This conflates "the host refused the merge" with "we
    /// couldn't reach the host" (review #899), and the two are not the same
    /// thing: a rate-limit or network blip parks the PR until a daemon restart.
    /// It is still the right default *here* specifically because this path has
    /// no host-side backstop. `enableAutoMerge` can retry freely — GitHub holds
    /// the queued request and re-checks eligibility itself, so a wasted attempt
    /// costs nothing. A direct merge acts immediately on a snapshot, so an
    /// automatic retry loop is the one failure mode that could merge on stale
    /// state. Distinguishing the two would mean pattern-matching `gh` stderr,
    /// which is the brittleness `repoAutoMergeAllowed` was added to escape.
    /// Stop and let a human look. If the false-permanent rate proves annoying
    /// in practice, the fix is bounded retries keyed on `headRefOid` (as
    /// `autoUpdateBranchAttempted` does), not a looser catch.
    private func performDirectMerge(session: Session, pr: ViewerPR, backend: CodeBackend) async {
        guard backend.capabilities.contains(.directMerge) else {
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.backendLacksAutoMerge.rawValue
            CrowLog.automation("auto-merge: #\(pr.number) skipped — backend lacks the directMerge capability")
            publishAutoMergeVerdict(.backendLacksAutoMerge, session: session, pr: pr)
            return
        }
        do {
            try await backend.mergeNow(prURL: pr.url)
            recordAutoMergeSuccess(
                session: session, pr: pr, phase: .merged, detail: "squash, direct — repo disallows auto-merge")
        } catch {
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.directMergeFailed.rawValue
            CrowLog.automation(
                "auto-merge: #\(pr.number) direct merge failed (will NOT retry): "
                + error.localizedDescription)
            publishAutoMergeVerdict(.directMergeFailed, session: session, pr: pr)
        }
    }

    /// Persist the one-shot merge guard and publish the success verdict, shared
    /// by the auto-merge and direct-merge paths so they can't drift on which
    /// state they write.
    private func recordAutoMergeSuccess(
        session: Session, pr: ViewerPR, phase: AutoMergeState.Phase, detail: String
    ) {
        let now = Date()
        if let idx = appState.sessions.firstIndex(where: { $0.id == session.id }) {
            appState.sessions[idx].autoMergeEnabledAt = now
            appState.sessions[idx].updatedAt = now
        }
        // Shared `store`, not a throwaway `JSONStore()`: this writes
        // `data.sessions` from a snapshot, so a stale fresh instance here
        // is the most direct session-clobber vector (#728).
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == session.id }) {
                data.sessions[idx].autoMergeEnabledAt = now
                data.sessions[idx].updatedAt = now
            }
        }
        let verb = phase == .merged ? "MERGED" : "ENABLED"
        CrowLog.automation(
            "auto-merge: \(verb) on \(pr.url) (session \(session.id.uuidString), \(detail))")
        appState.autoMergeState[session.id] = AutoMergeState(
            phase: phase,
            reason: phase == .merged ? "direct-merge" : AutoMergeSkipReason.alreadyEnabled.rawValue,
            message: phase == .merged
                ? "Crow merged this PR directly (squash), because the repository has GitHub's "
                    + "\"Allow auto-merge\" setting turned off."
                : "Auto-merge is enabled. GitHub will merge this PR once required reviews and "
                    + "checks pass.",
            permanent: false)
        clearAutoMergeBlockNotifications(prURL: pr.url)
        onAutoMergeEnabled?(session.id, pr.url, pr.number)
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
            CrowLog.automation(
                "auto-merge: #\(pr.number) update-branch skipped — no Crow-Session trailer matching a known session")
            return
        }

        defer { autoMergeInFlight.remove(pr.url) }
        guard backend.capabilities.contains(.updateBranch) else {
            CrowLog.automation("auto-merge: #\(pr.number) update-branch skipped — backend lacks the updateBranch capability")
            return
        }
        do {
            try await backend.updateBranch(prURL: pr.url)
            CrowLog.automation(
                "auto-merge: #\(pr.number) branch updated from base (session \(session.id.uuidString), was BEHIND)")
        } catch {
            CrowLog.automation("auto-merge: #\(pr.number) updateBranch failed: \(error.localizedDescription)")
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
            CrowLog.info("[Crow] fetchCrowAuthoredCommits failed for \(pr.url): \(error.localizedDescription)")
            return false
        }
        recordPRAttribution(pr: pr, commits: commits)
        let knownIDs = Set(appState.sessions.map(\.id))
        return Self.crowAuthored(commitMessages: commits.map(\.message), knownSessionIDs: knownIDs)
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
    /// there is **no label requirement**, and review state and draft-ness are
    /// irrelevant — a rebase doesn't need approval, and the operation is a
    /// rebase-onto-base + `--force-with-lease` on the session's own branch,
    /// never a merge (drafts stay excluded from auto-merge by
    /// `shouldAttemptAutoMerge`'s own guard). Returns true when the PR is OPEN
    /// and either BEHIND its base or CONFLICTING. Crow-authorship and per-head
    /// loop-safety are enforced by the caller.
    nonisolated static func shouldAttemptAutoRebase(pr: ViewerPR) -> Bool {
        guard pr.state == "OPEN" else { return false }
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

        // Drop per-head bookkeeping for heads no longer in the poll, so these
        // maps don't grow for the lifetime of the daemon. Guarded by the
        // non-empty check above so a failed/empty poll can't wipe live state;
        // a PR that briefly drops out and returns just gets re-dispatched once.
        let liveHeadKeys = Set(viewerPRs.map { "\($0.url)\n\($0.headRefOid)" })
        autoRebaseAttempted.formIntersection(liveHeadKeys)
        autoRebaseFailureCounts = autoRebaseFailureCounts.filter { liveHeadKeys.contains($0.key) }
        autoRebaseDeferrals = autoRebaseDeferrals.filter { liveHeadKeys.contains($0.key) }

        let now = Date()
        var dispatched = 0
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
            // A deferral re-arms `autoRebaseAttempted`, so the backoff window is
            // what actually paces retries for a head that keeps deferring.
            if let deferral = autoRebaseDeferrals[key], now < deferral.retryAt { continue }
            guard !autoRebaseAttempted.contains(key) else { continue }
            autoRebaseAttempted.insert(key)
            autoRebaseInFlight.insert(prLink.url)
            dispatched += 1
            CrowLog.automation("auto-rebase: dispatched #\(pr.number) (\(pr.mergeStateStatus), mergeable=\(pr.mergeable))")
            let capturedSession = session
            Task { await self.attemptRebase(session: capturedSession, pr: pr) }
        }
        if dispatched == 0 {
            // Hourly, not per-poll: an idle-but-enabled watcher is the steady
            // state, and one line per 60s would rotate the interesting entries
            // out of the log (review #787).
            if lastAutoRebaseIdleLogAt.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
                lastAutoRebaseIdleLogAt = now
                CrowLog.automation("auto-rebase: enabled, no candidates this poll")
            }
        } else {
            // A live dispatch means the next idle stretch is worth reporting.
            lastAutoRebaseIdleLogAt = nil
        }
    }

    /// Whether a `.failed` rebase should be retried on the next poll given how
    /// many consecutive failures this head state has already seen. Pure so the
    /// retry policy is unit-testable without an `IssueTracker`.
    nonisolated static func shouldRetryFailedRebase(failureCount: Int) -> Bool {
        failureCount < maxAutoRebaseFailureRetries
    }

    /// How long to wait before re-attempting a deferred auto-rebase, given how
    /// many consecutive times this head state has already deferred. Doubles
    /// from one poll interval up to a 15-minute cap.
    ///
    /// A deferral re-arms the per-head key, so without a delay a permanently
    /// stuck branch (unpushed commits, a long-running agent edit) re-dispatched
    /// a `git fetch` and a bare `dispatched` log line every single poll (#889).
    /// The first retry still lands on the very next poll, so the common
    /// transient case — an agent mid-edit — recovers as promptly as before.
    /// Pure so the policy is unit-testable without an `IssueTracker`.
    nonisolated static func autoRebaseDeferralBackoff(deferralCount: Int) -> TimeInterval {
        let doublings = max(0, min(deferralCount - 1, 16))
        return min(autoRebaseDeferralBaseDelay * pow(2, Double(doublings)), autoRebaseDeferralMaxDelay)
    }

    /// Locate the session's primary worktree, verify Crow authorship, then
    /// rebase it onto base and force-push. On conflicts, fire
    /// `onAutoRebaseConflicts` so the caller hands resolution to Claude.
    /// Transient outcomes (dirty tree, out-of-sync branch, bounded failures)
    /// un-set the per-head key so a later poll retries; deferrals additionally
    /// stamp a backoff deadline. Every outcome — including the early skips —
    /// writes exactly one line to the automation log, so a `dispatched` line is
    /// always paired with the reason it did or didn't rebase (#889).
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
            CrowLog.automation(
                "auto-rebase: #\(pr.number) skipped:no-usable-worktree "
                + "(no worktree, main-repo checkout, or branch != \(pr.headRefName))")
            return
        }

        guard let backend = codeBackend(for: session) else {
            CrowLog.automation("auto-rebase: #\(pr.number) skipped:no-backend")
            return
        }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            CrowLog.automation("auto-rebase: #\(pr.number) skipped:no-crow-session-trailer")
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
            autoRebaseDeferrals[headKey] = nil
            let priorState = pr.mergeable == "CONFLICTING" ? "CONFLICTING" : "BEHIND"
            CrowLog.automation(
                "auto-rebase: #\(pr.number) rebased & force-pushed (was \(priorState), session \(session.id))")
            onAutoRebasePushed?(session.id, pr.url, pr.number)
        case .conflicts:
            autoRebaseFailureCounts[headKey] = nil
            autoRebaseDeferrals[headKey] = nil
            CrowLog.automation(
                "auto-rebase: #\(pr.number) conflicts — delegating to agent (session \(session.id))")
            onAutoRebaseConflicts?(session.id, pr.url, pr.number)
        case .dirtyWorktree:
            // Transient (a Claude session is mid-edit). Re-arm so a later poll
            // retries once the tree is clean.
            deferRebase(headKey: headKey, reason: .dirtyWorktree, prNumber: pr.number)
        case .outOfSyncWithRemote(let divergence):
            // Transient: local has unpushed commits, or local and origin have
            // both moved. Either way a force-push would destroy work, so wait
            // for a human to reconcile and retry on a later poll. (A branch
            // that is merely behind is fast-forwarded by `rebaseOntoBase` and
            // never lands here — that was the #889 hot loop.)
            deferRebase(
                headKey: headKey,
                reason: divergence == .ahead ? .outOfSyncAhead : .outOfSyncDiverged,
                prNumber: pr.number)
        case .failed(let msg):
            // Transient git failures (fetch flake, rejected lease, unreachable
            // base) shouldn't silently stall the watcher until the head commit
            // changes. Retry a bounded number of times, then give up for this
            // head state to avoid hot-looping on a broken config.
            autoRebaseDeferrals[headKey] = nil
            let failures = (autoRebaseFailureCounts[headKey] ?? 0) + 1
            autoRebaseFailureCounts[headKey] = failures
            let willRetry = Self.shouldRetryFailedRebase(failureCount: failures)
            if willRetry { autoRebaseAttempted.remove(headKey) }
            CrowLog.automation(
                "auto-rebase: #\(pr.number) failed (attempt \(failures)/"
                + "\(Self.maxAutoRebaseFailureRetries), "
                + "\(willRetry ? "will retry" : "giving up until head changes")): \(msg)")
        }
    }

    /// Record a deferred auto-rebase attempt: re-arm the per-head key so it can
    /// be dispatched again, but stamp a backoff deadline so a head that keeps
    /// deferring doesn't re-fetch every poll forever (#889). A *different*
    /// reason than last time restarts the backoff — the branch moved to a new
    /// situation, which deserves a prompt retry rather than the previous
    /// reason's accumulated delay.
    private func deferRebase(headKey: String, reason: AutoRebaseDeferReason, prNumber: Int) {
        autoRebaseFailureCounts[headKey] = nil
        autoRebaseAttempted.remove(headKey)
        let count = autoRebaseDeferrals[headKey].map { $0.reason == reason ? $0.count + 1 : 1 } ?? 1
        let delay = Self.autoRebaseDeferralBackoff(deferralCount: count)
        autoRebaseDeferrals[headKey] = AutoRebaseDeferral(
            reason: reason, count: count, retryAt: Date().addingTimeInterval(delay))
        CrowLog.automation(
            "auto-rebase: #\(prNumber) deferred:\(reason.rawValue) "
            + "(deferral \(count), retry in \(Int(delay))s)")
    }

    // MARK: - Auto Re-Request Review Watcher (CROW-921)

    /// Why a PR was not re-requested this poll. `nil` from
    /// `autoReReviewSkipReason` means "go". Raw values are grep-stable log
    /// strings — people search `crowd-automation.log` for these.
    enum AutoReReviewSkipReason: String, Sendable, Equatable {
        case reviewSession = "review-session"
        case draft = "draft"
        case notAwaitingReRequest = "not-awaiting-re-request"
        case noReviewers = "no-changes-requested-reviewers"
        case agentBusy = "agent-busy"
    }

    /// Pure eligibility check for the auto-re-request watcher.
    /// `nonisolated static` so it is unit-testable without an `IssueTracker`,
    /// matching `shouldAttemptAutoRebase` / `autoMergeSkipReason`.
    ///
    /// `.awaitingReRequest` is the whole decision — it already encodes "open",
    /// "changes requested", "the fix landed after the review", and "nobody has
    /// been asked to look again". Everything else here is about whether *this
    /// session* should be the one to act.
    nonisolated static func autoReReviewSkipReason(
        pr: ViewerPR,
        status: PRStatus,
        isReviewSession: Bool,
        agentSettled: Bool
    ) -> AutoReReviewSkipReason? {
        if isReviewSession { return .reviewSession }
        if pr.isDraft { return .draft }
        guard PRStatus.changesRequestedState(status: status) == .awaitingReRequest else {
            return .notAwaitingReRequest
        }
        if pr.changesRequestedReviewerLogins.isEmpty { return .noReviewers }
        if !agentSettled { return .agentBusy }
        return nil
    }

    /// Sessions eligible to have their PR re-requested. Same exclusions as
    /// auto-rebase: the Manager owns no PR, and a review session's linked PR
    /// belongs to somebody else.
    nonisolated static func sessionEligibleForAutoReReview(_ session: Session) -> Bool {
        session.id != AppState.managerSessionID && session.kind != .review
    }

    /// Re-request review on PRs whose CHANGES_REQUESTED findings have been
    /// addressed but which nobody has been asked to look at again (CROW-921).
    ///
    /// This is the missing third leg of the auto-respond loop. Before it, the
    /// only thing that re-requested review was a sentence inside the
    /// `addressChanges` prompt — reachable only while the agent still owed a
    /// fix, and therefore never reachable once the fix landed. A PR fixed by
    /// any other path (the agent's own in-flight work, an auto-rebase conflict
    /// delegation, a human nudge) parked in CHANGES_REQUESTED forever,
    /// invisible to the reviewer's queue and to `review-requested:@me` alike.
    ///
    /// Deterministic rather than prompt-driven, like `applyAutoMerge`: a
    /// one-line API call routed through an agent turn costs a full turn's
    /// tokens, can't be verified, and would re-inherit the very gate that
    /// caused the bug. The prompt hint stays as belt-and-braces — adding a
    /// reviewer who is already requested is a host-side no-op.
    private func applyAutoReRequestReview(viewerPRs: [ViewerPR]) {
        guard autoReRequestReviewProvider() else { return }
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        // Prune the per-round guard against what this poll actually saw, so a
        // new push or a new reviewer submission re-arms the watcher. Guarded
        // by the non-empty check above: a failed fetch must not wipe live
        // state and let a second request fire.
        let liveRoundKeys = Set(viewerPRs.map {
            Self.autoReReviewRoundKey(url: $0.url, headRefOid: $0.headRefOid, lastChangesRequestedAt: $0.lastChangesRequestedAt)
        })
        autoReRequestAttempted.formIntersection(liveRoundKeys)

        let now = Date()
        var dispatched = 0
        for session in appState.sessions where Self.sessionEligibleForAutoReReview(session) {
            guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else { continue }
            guard !autoReRequestInFlight.contains(prLink.url) else { continue }
            guard let pr = byURL[prLink.url] else { continue }

            let status = Self.buildPRStatus(from: pr)
            let skip = Self.autoReReviewSkipReason(
                pr: pr,
                status: status,
                isReviewSession: session.kind == .review,
                agentSettled: agentSettled(sessionID: session.id)
            )
            if let skip {
                // Only the states a reader would wonder about get a line —
                // `.notAwaitingReRequest` is the overwhelming majority of
                // healthy PRs and is already covered by the needs-refine
                // gated log. The rest go through the shared rate limiter: a
                // PR parked on `.agentBusy` or `.noReviewers` would otherwise
                // emit a line every 60s poll for as long as it stayed there.
                if skip != .notAwaitingReRequest {
                    logSteadyState(
                        channel: Self.autoReReviewLogChannel,
                        prURL: prLink.url,
                        message: "auto-re-request: #\(pr.number) skipped:\(skip.rawValue)",
                        now: now)
                }
                continue
            }

            let roundKey = Self.autoReReviewRoundKey(
                url: prLink.url, headRefOid: pr.headRefOid, lastChangesRequestedAt: pr.lastChangesRequestedAt)
            guard !autoReRequestAttempted.contains(roundKey) else { continue }
            autoReRequestAttempted.insert(roundKey)
            autoReRequestInFlight.insert(prLink.url)
            dispatched += 1
            let logins = pr.changesRequestedReviewerLogins
            CrowLog.automation(
                "auto-re-request: dispatched #\(pr.number) → \(logins.joined(separator: ", ")) "
                + "(lastCR=\(Self.iso(pr.lastChangesRequestedAt)), lastCommit=\(Self.iso(pr.lastSubstantiveCommitAt)))")
            let capturedSession = session
            Task { await self.attemptReRequestReview(session: capturedSession, pr: pr, roundKey: roundKey) }
        }
        if dispatched == 0 {
            if lastAutoReReviewIdleLogAt.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
                lastAutoReReviewIdleLogAt = now
                CrowLog.automation("auto-re-request: enabled, no candidates this poll")
            }
        } else {
            lastAutoReReviewIdleLogAt = nil
        }
    }

    /// One re-request per (PR, head, review round). A new push changes the
    /// head; a new reviewer submission changes the CR timestamp. Either is a
    /// genuinely new round.
    nonisolated static func autoReReviewRoundKey(
        url: String, headRefOid: String, lastChangesRequestedAt: Date?
    ) -> String {
        "\(url)\n\(headRefOid)\n\(iso(lastChangesRequestedAt))"
    }

    /// Perform the re-request. Capability-gated like every other PR write, so
    /// a provider without `.requestReviewers` degrades to a logged skip.
    private func attemptReRequestReview(session: Session, pr: ViewerPR, roundKey: String) async {
        defer { autoReRequestInFlight.remove(pr.url) }
        guard let backend = codeBackend(for: session) else {
            CrowLog.automation("auto-re-request: #\(pr.number) failed:no-code-backend")
            autoReRequestAttempted.remove(roundKey)
            return
        }
        guard backend.capabilities.contains(.requestReviewers) else {
            // Not a retryable condition — leave the round key latched so this
            // doesn't re-log every poll for the life of the PR.
            CrowLog.automation(
                "auto-re-request: #\(pr.number) skipped:provider-unsupported (\(backend.provider.rawValue))")
            return
        }
        let logins = pr.changesRequestedReviewerLogins
        do {
            try await backend.requestReviewers(prURL: pr.url, logins: logins)
            CrowLog.automation(
                "auto-re-request: #\(pr.number) re-requested \(logins.joined(separator: ", ")) "
                + "— session=\(session.id.uuidString)")
        } catch {
            // Clear the round key so the next poll retries. The PR is still
            // in `.awaitingReRequest` (nothing changed host-side), so this is
            // a genuine retry rather than a duplicate request — and if the
            // call actually landed despite the error, re-adding a pending
            // reviewer is a no-op.
            autoReRequestAttempted.remove(roundKey)
            CrowLog.automation(
                "auto-re-request: #\(pr.number) failed:\(error.localizedDescription.prefix(200))")
        }
    }

    /// Pure projection of a provider PR record onto the UI-facing `PRStatus`.
    /// `nonisolated static` (like `shouldAttemptAutoMerge`) because it touches
    /// no tracker state — which also makes it directly unit-testable.
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
            hasPendingReviewRequest: pr.hasPendingReviewRequest,
            // Same case-insensitive match `shouldAttemptAutoMerge` gates on —
            // surfaced for the UI so the sidebar can show "labeled for merge"
            // separately from "auto-merge already enabled" (CROW-773).
            hasMergeLabel: pr.labels.contains {
                $0.name.caseInsensitiveCompare(Self.autoMergeLabel) == .orderedSame
            }
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

    /// The reviewer-side auto-kickoff decision for a single review request,
    /// mirroring the legacy `AppDelegate.onReviewRequestsRefreshed` guard
    /// (retired in the headless-engine migration, ADR 0008). Pure so the
    /// daemon's imperative shell (repo-pattern filter, SHA fingerprint dedup,
    /// clone serializer) stays thin and this branch is unit-testable.
    ///
    /// - `.create`: no session exists for this PR yet — spawn a review session.
    /// - `.reReview`: a linked session exists but the PR head advanced past the
    ///   SHA it last reviewed (author pushed / force-pushed after a first pass).
    ///   The stale session is completed and a fresh one spun up against the new
    ///   head (CROW-290 keys each head as its own round; CROW-406's
    ///   `existingByPR` guards the clone window). Carries the stale session ID
    ///   so the caller tears it down before enqueuing.
    /// - `.skip`: a session already covers this PR at the current head.
    public enum ReviewKickoffAction: Equatable {
        case skip
        case create
        case reReview(staleSessionID: UUID)
    }

    /// - Parameters:
    ///   - reviewSessionID: the `ReviewRequest`'s cross-referenced session, or
    ///     nil until `IssueTracker` repopulates it (lags the actual session by
    ///     up to one refresh).
    ///   - headRefOid: the PR's current head SHA (nil when unfetched — never
    ///     re-reviews on a missing head).
    ///   - linkedSession: the session resolved from `reviewSessionID`.
    ///   - existingByPRSessionID: `AppState.existingReviewSession(forPRURL:)` —
    ///     the authoritative link-based lookup that catches an in-flight kickoff
    ///     before `reviewSessionID` is written back.
    nonisolated public static func reviewKickoffAction(
        reviewSessionID: UUID?,
        headRefOid: String?,
        linkedSession: Session?,
        existingByPRSessionID: UUID?
    ) -> ReviewKickoffAction {
        // B-fallback: linked session exists but its last-reviewed head is
        // stale relative to the PR's current head → re-review the new head.
        let shaAdvanced = linkedSession != nil
            && headRefOid != nil
            && linkedSession?.lastReviewedHeadSha != headRefOid
        if shaAdvanced, let staleID = reviewSessionID {
            return .reReview(staleSessionID: staleID)
        }
        // Create only when nothing already covers this PR (belt-and-suspenders:
        // the lagging `reviewSessionID` cross-ref plus the authoritative
        // link-based lookup, so the ~10s clone window can't double-kick).
        if reviewSessionID == nil && existingByPRSessionID == nil {
            return .create
        }
        return .skip
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
        AppState.scorecardSessionID,
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
            guard !session.locked else { return nil }
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

    /// Fetch assigned GitLab issues for one host, including the recently-closed
    /// half (#697) so GitLab-backed workspaces feed the done-count badge.
    /// Best-effort: degrades to an empty listing on failure, mirroring the
    /// Jira / Corveil paths.
    private func fetchGitLabIssues(host: String) async -> AssignedListing {
        let backend = providerManager.taskBackend(for: .gitlab, host: host)
        do {
            return try await backend.listAssigned(includeClosed: true)
        } catch {
            print("[IssueTracker] fetchGitLabIssues(host: \(host)) failed: \(error)")
            return AssignedListing(open: [], closed: [])
        }
    }

    /// Hard cap on how many GitLab issues get the (up to 2 REST calls each)
    /// related-MR lookup per host per poll, so one large assigned-issue queue
    /// can't stall the ~60s cycle or burn API quota (#751 review).
    private static let maxGitLabMREnrich = 25

    /// Attach linked-MR state + CI checks to open GitLab issues for the board's
    /// inline PR badges (#751). GitLab has no consolidated issue↔MR query like
    /// GitHub's `closingIssuesReferences`, so this is a best-effort per-issue
    /// lookup (up to two REST calls each). Fan-out is bounded two ways: issues
    /// GitLab reports have zero MRs (`merge_requests_count == 0`) skip the round
    /// trip entirely, and the rest are capped at `maxGitLabMREnrich`. Any
    /// failure leaves the fields nil and the card degrades gracefully.
    private func enrichGitLabMRStatus(_ issues: [AssignedIssue], host: String) async -> [AssignedIssue] {
        guard let backend = providerManager.codeBackend(for: .gitlab, host: host) as? GitLabCodeBackend else {
            return issues
        }
        var result = issues
        var budget = Self.maxGitLabMREnrich
        var skippedForBudget = 0
        for idx in result.indices where result[idx].state == "open" {
            // GitLab already told us there are no MRs → no point looking one up.
            if result[idx].mergeRequestsCount == 0 { continue }
            if budget <= 0 { skippedForBudget += 1; continue }
            budget -= 1
            guard let rec = try? await backend.linkedMRStatus(
                repoSlug: result[idx].repo, issueNumber: result[idx].number
            ) else { continue }
            result[idx].prNumber = rec.number
            result[idx].prURL = rec.url
            result[idx].prState = rec.isDraft ? "draft" : rec.state.lowercased()
            result[idx].checksState = rec.checksState.isEmpty ? nil : rec.checksState
        }
        if skippedForBudget > 0 {
            print("[IssueTracker] enrichGitLabMRStatus(host: \(host)): capped MR enrichment at \(Self.maxGitLabMREnrich); \(skippedForBudget) issue(s) left un-enriched this cycle")
        }
        return result
    }

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

    /// Merge an `AssignedListing` (Jira #536, GitLab #697) into the board's
    /// flat issue list: open issues plus the closed (Done) issues deduped by
    /// `id` against the open set, mirroring the GitHub closed-issue merge.
    /// `doneCount` is the backend-reported window total (`closedTotalCount`),
    /// not the length of the capped closed page, so the badge doesn't saturate
    /// at the 50-item page cap (#572, mirroring GitHub's #562 fix) — and it
    /// counts the window, not just the post-dedup remainder, matching GitHub's
    /// semantics.
    nonisolated static func mergeListing(_ listing: AssignedListing) -> (issues: [AssignedIssue], doneCount: Int) {
        let openIDs = Set(listing.open.map(\.id))
        let uniqueDone = listing.closed.filter { !openIDs.contains($0.id) }
        return (listing.open + uniqueDone, listing.closedTotalCount)
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

    public func markInReview(sessionID: UUID) async {
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
    /// failures are logged and swallowed, mirroring `markInReview`.
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
            try await backend.ensureMergeLabel(repo: repo)
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
            // Targeted re-fetch so the auto-merge watcher re-evaluates promptly
            // with the label present instead of on the next scheduled poll.
            await refresh()
            // Read the verdict *after* the refresh: that pass is what populates
            // `autoMergeState`, so asking before it would report the previous
            // poll's answer — or nothing at all on a freshly linked PR (#888).
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
    func autoMergeWarning(sessionID: UUID) -> String? {
        guard autoMergeWatcherEnabledProvider() else {
            return "The label was added, but Crow's auto-merge watcher is off, so nothing will "
                + "merge this PR. Turn it on in Settings → Automation, or run "
                + "`crow automation set --auto-merge-watcher-enabled true`."
        }
        guard let state = appState.autoMergeState[sessionID], state.phase == .blocked else {
            return nil
        }
        return "The label was added, but auto-merge won't run: \(state.message)"
    }
}
