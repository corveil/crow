import Foundation
import CrowCore
import CrowPersistence
import CrowProvider

/// Polls GitHub/GitLab for issues assigned to the current user.
///
/// GitHub polling is consolidated into a single aliased GraphQL query per refresh
/// (see `Self.consolidatedQuery`). Per-session PR detection, PR status, and
/// auto-complete all piggyback on that one response — no per-session `gh` calls.
/// The `rateLimit` block on each response feeds `AppState.githubRateLimit`, and
/// a soft threshold + 403 detection suspend polling when quotas are low.
@MainActor
final class IssueTracker {
    private let appState: AppState
    private var timer: Timer?
    private let pollInterval: TimeInterval = 60 // 1 minute
    private var isRefreshing = false

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

    /// Fires after Crow has successfully enabled GitHub native auto-merge
    /// on a PR. Wired in AppDelegate to post the user-facing notification.
    /// (The durable audit-log line is `NSLog`'d at the call site so it
    /// lands in Console regardless of notification settings.)
    var onAutoMergeEnabled: ((UUID, String, Int) -> Void)?

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

    /// Last observed `PRStatus` per session, used to compute transitions.
    /// Populated lazily on first observation; that first poll never fires
    /// transitions (matches the `previousReviewRequestIDs` first-fetch
    /// behavior so existing PR state isn't replayed at startup).
    private var previousPRStatus: [UUID: PRStatus] = [:]

    /// Stable keys of transitions we've already emitted, used to suppress
    /// duplicates across the in-process lifetime. See `PRStatusTransition.dedupeKey`.
    /// Cleared per-session when we observe the rule "re-arm" (e.g. checks
    /// move back to passing/pending) so subsequent transitions still fire.
    private var emittedTransitionKeys: Set<String> = []

    /// Guards the GitHub-scope console warning so it fires once per session.
    private var didLogGitHubScopeWarning = false

    /// When non-nil and in the future, all polls are skipped.
    private var suspendedUntil: Date?

    /// Below this many remaining GraphQL points we proactively skip a cycle.
    private let rateLimitThreshold = 50

    /// gh invocations made during the current `refresh()`. Incremented by the
    /// shell helpers, reset at the start of each refresh.
    private var currentRefreshGhCalls = 0

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Initial fetch
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

        currentRefreshGhCalls = 0
        let startedAt = Date()

        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return }

        let hasGitHub = config.workspaces.contains(where: { $0.provider == "github" })
        var gitLabHosts: [String] = []
        for ws in config.workspaces where ws.provider == "gitlab" {
            if let host = ws.host, !gitLabHosts.contains(host) {
                gitLabHosts.append(host)
            }
        }

        var allIssues: [AssignedIssue] = []

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
            appState.doneIssuesLast24h = ghResult.closedIssues.count
        }

        // GitLab — unchanged fan-out (one call per host)
        for host in gitLabHosts {
            let issues = await fetchGitLabIssues(host: host)
            allIssues.append(contentsOf: issues)
        }

        appState.assignedIssues = allIssues

        let ticketExcludePatterns = config.defaults.excludeTicketRepos
        let autoCreateCandidates = ticketExcludePatterns.isEmpty
            ? allIssues
            : allIssues.filter { !repoMatchesExcludePatterns($0.repo, patterns: ticketExcludePatterns) }
        detectAutoCreateCandidates(issues: autoCreateCandidates, config: config)

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
            let reviewExcludePatterns = config.defaults.excludeReviewRepos
            if !reviewExcludePatterns.isEmpty {
                reviews = reviews.filter { !repoMatchesExcludePatterns($0.repo, patterns: reviewExcludePatterns) }
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
    private func detectAutoCreateCandidates(issues: [AssignedIssue], config: AppConfig) {
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

            if appState.activeSession(for: issue) != nil {
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
        let result: ShellResult
        switch issue.provider {
        case .github:
            result = await shellWithStatus(
                "gh", "issue", "edit", issue.url,
                "--remove-label", Self.autoCreateLabel
            )
        case .gitlab:
            // issue.id format: "gitlab:host:org/repo#number"
            let parts = issue.id.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else {
                print("[IssueTracker] cannot strip label, malformed gitlab id: \(issue.id)")
                return
            }
            let host = parts[1]
            let repo = issue.repo
            result = await shellWithStatus(
                env: ["GITLAB_HOST": host],
                args: [
                    "glab", "issue", "update", String(issue.number),
                    "--repo", repo,
                    "--unlabel", Self.autoCreateLabel
                ]
            )
        }
        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[IssueTracker] failed to remove \(Self.autoCreateLabel) from \(issue.url): \(stderr)")
        }
    }

    private func logRefreshSummary(elapsed: TimeInterval) {
        let elapsedStr = String(format: "%.2fs", elapsed)
        if let rl = appState.githubRateLimit {
            let mins = Int(max(0, rl.resetAt.timeIntervalSinceNow / 60))
            print("[IssueTracker] refresh: \(currentRefreshGhCalls) gh calls in \(elapsedStr), GraphQL \(rl.remaining)/\(rl.limit) remaining, resets in \(mins)m")
        } else {
            print("[IssueTracker] refresh: \(currentRefreshGhCalls) gh calls in \(elapsedStr)")
        }
    }

    // MARK: - Consolidated GraphQL Query

    private struct ConsolidatedGitHubResponse {
        let openIssues: [AssignedIssue]
        let closedIssues: [AssignedIssue]
        let viewerPRs: [ViewerPR]
        let reviewRequests: [ReviewRequest]
        let rateLimit: GitHubRateLimit?
    }

    struct ViewerPR: Sendable {
        let number: Int
        let url: String
        let state: String          // OPEN / MERGED / CLOSED
        let mergeable: String      // MERGEABLE / CONFLICTING / UNKNOWN
        let mergeStateStatus: String // BEHIND / BLOCKED / CLEAN / DIRTY / DRAFT / HAS_HOOKS / UNKNOWN / UNSTABLE
        let reviewDecision: String // APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / ""
        let isDraft: Bool
        let headRefName: String
        let headRefOid: String     // Head commit SHA (empty if unavailable)
        let baseRefName: String
        let repoNameWithOwner: String
        let labels: [LabelInfo]
        let linkedIssueReferences: [LinkedIssue]
        let checksState: String    // SUCCESS / FAILURE / PENDING / EXPECTED / ERROR / ""
        let failedCheckNames: [String]
        let latestReviewStates: [String]

        struct LinkedIssue: Sendable {
            let number: Int
            let repo: String
        }
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
            latestReviewStates: winner.latestReviewStates.isEmpty ? loser.latestReviewStates : winner.latestReviewStates
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

    private static let consolidatedQuery = """
    query($openQuery: String!, $closedQuery: String!, $reviewQuery: String!) {
      openIssues: search(type: ISSUE, query: $openQuery, first: 100) {
        nodes {
          ... on Issue {
            number title url state updatedAt
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            projectItems(first: 10) {
              nodes {
                fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
          }
        }
      }
      viewerPRs: viewer {
        pullRequests(first: 50, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number url state mergeable mergeStateStatus reviewDecision isDraft headRefName headRefOid baseRefName
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } } }
            statusCheckRollup {
              state
              contexts(first: 25) {
                nodes {
                  __typename
                  ... on CheckRun { name conclusion status }
                  ... on StatusContext { context state }
                }
              }
            }
            latestReviews(first: 5) { nodes { state } }
          }
        }
      }
      closedIssues: search(type: ISSUE, query: $closedQuery, first: 50) {
        nodes {
          ... on Issue {
            number title url state updatedAt
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
          }
        }
      }
      reviewPRs: search(type: ISSUE, query: $reviewQuery, first: 50) {
        nodes {
          ... on PullRequest {
            number title url isDraft updatedAt headRefName headRefOid baseRefName state
            author { login }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            reviews(last: 20) { nodes { author { login } submittedAt state } }
          }
        }
      }
      viewer { login }
      rateLimit { remaining limit resetAt cost }
    }
    """

    /// GraphQL search only accepts date-only for `closed:>=` — full ISO8601 gets
    /// rejected, so format YYYY-MM-DD based on 24h ago.
    private func closedSinceString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date().addingTimeInterval(-86400))
    }

    private func runConsolidatedGitHubQuery() async -> ConsolidatedGitHubResponse? {
        let openQuery = "assignee:@me state:open type:issue"
        let closedQuery = "assignee:@me state:closed closed:>=\(closedSinceString()) type:issue"
        let reviewQuery = "review-requested:@me state:open type:pr"

        let args: [String] = [
            "gh", "api", "graphql",
            "-f", "query=\(Self.consolidatedQuery)",
            "-F", "openQuery=\(openQuery)",
            "-F", "closedQuery=\(closedQuery)",
            "-F", "reviewQuery=\(reviewQuery)"
        ]
        let result = await shellWithStatus(args: args)

        if result.exitCode != 0 {
            if handleGraphQLRateLimit(stderr: result.stderr) { return nil }
            if result.stderr.contains("INSUFFICIENT_SCOPES") || result.stderr.contains("read:project") {
                reportScopeWarning("read:project")
                // Retry without projectItems so the rest of the data still renders.
                return await retryWithoutProjectItems(
                    openQuery: openQuery,
                    closedQuery: closedQuery,
                    reviewQuery: reviewQuery
                )
            }
            print("[IssueTracker] Consolidated GraphQL query failed (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            return nil
        }

        clearScopeWarning()
        return parseConsolidatedResponse(result.stdout)
    }

    private func retryWithoutProjectItems(openQuery: String, closedQuery: String, reviewQuery: String) async -> ConsolidatedGitHubResponse? {
        // Stripped query: same as consolidatedQuery but with the projectItems block removed.
        let stripped = Self.consolidatedQuery.replacingOccurrences(
            of: """
                projectItems(first: 10) {
                  nodes {
                    fieldValueByName(name: "Status") {
                      ... on ProjectV2ItemFieldSingleSelectValue { name }
                    }
                  }
                }
        """,
            with: ""
        )
        let args: [String] = [
            "gh", "api", "graphql",
            "-f", "query=\(stripped)",
            "-F", "openQuery=\(openQuery)",
            "-F", "closedQuery=\(closedQuery)",
            "-F", "reviewQuery=\(reviewQuery)"
        ]
        let result = await shellWithStatus(args: args)
        guard result.exitCode == 0 else {
            if handleGraphQLRateLimit(stderr: result.stderr) { return nil }
            print("[IssueTracker] GraphQL retry (no projectItems) failed (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            return nil
        }
        return parseConsolidatedResponse(result.stdout)
    }

    // MARK: - Stale PR Follow-up

    /// PR URLs linked to active/paused/inReview sessions that are NOT in
    /// `openPRURLs`. These are the PRs we need to fetch state for to surface
    /// merged/closed status on the badge and drive auto-complete.
    /// Completed sessions are skipped — their badge state is set in-memory
    /// during the cycle they auto-complete and is preserved thereafter.
    private func collectStalePRURLs(excluding openPRURLs: Set<String>) -> [String] {
        var urls: Set<String> = []
        for session in appState.sessions where session.id != AppState.managerSessionID {
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
    /// `gh api graphql` call, GitLab MRs go through one `glab api` call per
    /// MR (with `GITLAB_HOST` set per host). A failure on either side marks
    /// the result incomplete but doesn't suppress the other side's PRs.
    /// Returns minimal `ViewerPR` records — only `state`, `url`, repo, and
    /// branch refs are populated; checks/reviews are left empty since
    /// they're moot for closed PRs.
    private func fetchStalePRStates(urls: [String]) async -> StalePRFetchResult {
        // Parse each URL into (owner, repo, number); skip any we can't parse.
        var githubParsed: [(url: String, owner: String, repo: String, number: Int)] = []
        var gitlabParsedByHost: [String: [(url: String, slug: String, number: Int)]] = [:]
        for url in urls {
            if let g = Self.parseGitLabMRURL(url) {
                gitlabParsedByHost[g.host, default: []].append((url, g.slug, g.number))
                continue
            }
            guard let p = ProviderManager.parseTicketURLComponents(url) else { continue }
            // Anything not parsed as GitLab is treated as GitHub. The
            // ProviderManager parser covers github.com URLs; self-hosted
            // GitLab URLs are caught above by `parseGitLabMRURL`.
            if let host = URL(string: url)?.host, host != "github.com" {
                // Unrecognized host that didn't match the GitLab MR shape —
                // skip rather than blindly route to gh.
                continue
            }
            githubParsed.append((url, p.org, p.repo, p.number))
        }
        guard !githubParsed.isEmpty || !gitlabParsedByHost.isEmpty else {
            return StalePRFetchResult(prs: [], complete: true)
        }

        var prs: [ViewerPR] = []
        var complete = true

        if !githubParsed.isEmpty {
            if let ghPRs = await fetchStalePRStatesGitHub(parsed: githubParsed) {
                prs.append(contentsOf: ghPRs)
            } else {
                complete = false
            }
        }

        for (host, parsed) in gitlabParsedByHost {
            let (mrPRs, ok) = await fetchStaleMRStatesGitLab(parsed: parsed, host: host)
            prs.append(contentsOf: mrPRs)
            if !ok { complete = false }
        }

        return StalePRFetchResult(prs: prs, complete: complete)
    }

    /// GitHub stale-PR fetch: one aliased GraphQL query covering every
    /// (owner, repo, number) tuple. Returns `nil` on shell error or rate
    /// limit so the caller can mark the cycle incomplete.
    private func fetchStalePRStatesGitHub(
        parsed: [(url: String, owner: String, repo: String, number: Int)]
    ) async -> [ViewerPR]? {
        guard !parsed.isEmpty else { return [] }

        // Build aliased query: pr0, pr1, ... each fetching one pullRequest.
        var queryParts: [String] = []
        var args: [String] = ["gh", "api", "graphql"]
        for (i, p) in parsed.enumerated() {
            queryParts.append("""
              pr\(i): repository(owner: $owner\(i), name: $repo\(i)) {
                pullRequest(number: $num\(i)) {
                  number url state mergeable mergeStateStatus reviewDecision isDraft
                  headRefName headRefOid baseRefName
                  repository { nameWithOwner }
                }
              }
            """)
            args.append(contentsOf: ["-F", "owner\(i)=\(p.owner)"])
            args.append(contentsOf: ["-F", "repo\(i)=\(p.repo)"])
            args.append(contentsOf: ["-F", "num\(i)=\(p.number)"])
        }
        var varDecls: [String] = []
        for i in 0..<parsed.count {
            varDecls.append("$owner\(i): String!, $repo\(i): String!, $num\(i): Int!")
        }
        let query = """
        query(\(varDecls.joined(separator: ", "))) {
        \(queryParts.joined(separator: "\n"))
          rateLimit { remaining limit resetAt cost }
        }
        """
        args.insert(contentsOf: ["-f", "query=\(query)"], at: 3)

        let result = await shellWithStatus(args: args)
        if result.exitCode != 0 {
            if handleGraphQLRateLimit(stderr: result.stderr) { return nil }
            print("[IssueTracker] Stale-PR follow-up failed (exit \(result.exitCode)): \(result.stderr.prefix(200))")
            return nil
        }
        return parseStalePRResponse(result.stdout, count: parsed.count)
    }

    /// GitLab stale-MR fetch: one `glab api projects/{slug}/merge_requests/{iid}`
    /// per MR for a given host. GitLab's REST API doesn't support batching by
    /// IDs the way GitHub's GraphQL does, but the per-cycle stale set is
    /// usually tiny (sessions with merged/closed PRs that haven't been
    /// auto-completed yet). Returns `(prs, ok)` where `ok` is false if any
    /// call for this host failed.
    private func fetchStaleMRStatesGitLab(
        parsed: [(url: String, slug: String, number: Int)],
        host: String
    ) async -> ([ViewerPR], Bool) {
        var prs: [ViewerPR] = []
        var ok = true
        for entry in parsed {
            let encodedSlug = entry.slug.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) ?? entry.slug
            let endpoint = "projects/\(encodedSlug)/merge_requests/\(entry.number)"

            let output: String
            do {
                output = try await shell(env: ["GITLAB_HOST": host], cwd: NSHomeDirectory(), "glab", "api", endpoint)
            } catch {
                print("[IssueTracker] Stale-PR follow-up failed for \(entry.slug)!\(entry.number) on \(host): \(error.localizedDescription.prefix(200))")
                ok = false
                continue
            }
            if let pr = Self.parseGitLabStaleMRResponse(output, fallbackURL: entry.url, fallbackSlug: entry.slug) {
                prs.append(pr)
            } else {
                ok = false
            }
        }
        return (prs, ok)
    }

    /// Parse a GitLab `projects/{slug}/merge_requests/{iid}` REST response
    /// into a minimal `ViewerPR`. State is normalized to GitHub's
    /// `OPEN|MERGED|CLOSED` so downstream code stays provider-agnostic.
    /// Returns nil if the JSON shape doesn't match.
    nonisolated static func parseGitLabStaleMRResponse(
        _ output: String,
        fallbackURL: String,
        fallbackSlug: String
    ) -> ViewerPR? {
        guard let data = output.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let number = item["iid"] as? Int else { return nil }
        let url = (item["web_url"] as? String) ?? fallbackURL
        let rawState = (item["state"] as? String) ?? ""
        let state = normalizeGitLabPRState(rawState)
        let headRefName = (item["source_branch"] as? String) ?? ""
        let baseRefName = (item["target_branch"] as? String) ?? ""
        let headRefOid = (item["sha"] as? String) ?? ""
        let isDraft = (item["draft"] as? Bool) ?? (item["work_in_progress"] as? Bool) ?? false

        return ViewerPR(
            number: number,
            url: url,
            state: state,
            mergeable: "UNKNOWN",
            mergeStateStatus: "UNKNOWN",
            reviewDecision: "",
            isDraft: isDraft,
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: baseRefName,
            repoNameWithOwner: fallbackSlug,
            labels: [],
            linkedIssueReferences: [],
            checksState: "",
            failedCheckNames: [],
            latestReviewStates: []
        )
    }

    /// Normalize GitLab MR state strings to the GitHub `state` vocabulary
    /// the rest of the codebase reads (`OPEN`/`MERGED`/`CLOSED`). Falls back
    /// to upper-casing the raw value for unrecognized states (matches
    /// `fetchGitLabMRsForReconcile`).
    nonisolated static func normalizeGitLabPRState(_ raw: String) -> String {
        switch raw {
        case "opened": return "OPEN"
        case "merged": return "MERGED"
        case "closed": return "CLOSED"
        default:       return raw.uppercased()
        }
    }

    /// Parse a GitLab MR URL into (host, slug, number). Robust to nested
    /// groups (slug is everything between the host and `/-/merge_requests/`).
    /// Returns nil for non-GitLab-MR URLs.
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

        // `trailing` is everything after `/-/merge_requests/` — usually just
        // the MR number, occasionally `<n>/diffs` or similar from a deep
        // link. Take the first segment as the number.
        let trailParts = trailing.split(separator: "/").map(String.init)
        guard let first = trailParts.first, let number = Int(first) else { return nil }
        return (host, slug, number)
    }

    private func parseStalePRResponse(_ output: String, count: Int) -> [ViewerPR]? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return nil }

        if let rl = parseRateLimit(dataObj["rateLimit"] as? [String: Any]) {
            appState.githubRateLimit = rl
        }

        var prs: [ViewerPR] = []
        for i in 0..<count {
            guard let repoObj = dataObj["pr\(i)"] as? [String: Any],
                  let prObj = repoObj["pullRequest"] as? [String: Any],
                  let number = prObj["number"] as? Int,
                  let url = prObj["url"] as? String,
                  let state = prObj["state"] as? String else { continue }

            let mergeable = prObj["mergeable"] as? String ?? "UNKNOWN"
            let mergeStateStatus = prObj["mergeStateStatus"] as? String ?? "UNKNOWN"
            let reviewDecision = prObj["reviewDecision"] as? String ?? ""
            let isDraft = prObj["isDraft"] as? Bool ?? false
            let headRefName = prObj["headRefName"] as? String ?? ""
            let headRefOid = prObj["headRefOid"] as? String ?? ""
            let baseRefName = prObj["baseRefName"] as? String ?? ""
            let repoName = (prObj["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""

            prs.append(ViewerPR(
                number: number,
                url: url,
                state: state,
                mergeable: mergeable,
                mergeStateStatus: mergeStateStatus,
                reviewDecision: reviewDecision,
                isDraft: isDraft,
                headRefName: headRefName,
                headRefOid: headRefOid,
                baseRefName: baseRefName,
                repoNameWithOwner: repoName,
                labels: [],
                linkedIssueReferences: [],
                checksState: "",
                failedCheckNames: [],
                latestReviewStates: []
            ))
        }
        return prs
    }

    private func parseConsolidatedResponse(_ output: String) -> ConsolidatedGitHubResponse? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            print("[IssueTracker] Failed to parse consolidated GraphQL response")
            return nil
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let openIssues = parseIssueNodes(
            dataObj["openIssues"] as? [String: Any],
            defaultState: "open",
            dateFormatter: dateFormatter
        )
        let closedIssues = parseIssueNodes(
            dataObj["closedIssues"] as? [String: Any],
            defaultState: "closed",
            dateFormatter: dateFormatter,
            projectStatusOverride: .done
        )
        let viewerPRs = parseViewerPRs(dataObj["viewerPRs"] as? [String: Any])
        let viewerLogin = (dataObj["viewer"] as? [String: Any])?["login"] as? String
        let reviewRequests = parseReviewRequests(
            dataObj["reviewPRs"] as? [String: Any],
            dateFormatter: dateFormatter,
            viewerLogin: viewerLogin
        )
        let rateLimit = parseRateLimit(dataObj["rateLimit"] as? [String: Any])

        return ConsolidatedGitHubResponse(
            openIssues: openIssues,
            closedIssues: closedIssues,
            viewerPRs: viewerPRs,
            reviewRequests: reviewRequests,
            rateLimit: rateLimit
        )
    }

    private func parseIssueNodes(
        _ searchObj: [String: Any]?,
        defaultState: String,
        dateFormatter: ISO8601DateFormatter,
        projectStatusOverride: TicketStatus? = nil
    ) -> [AssignedIssue] {
        guard let nodes = searchObj?["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node -> AssignedIssue? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else { return nil }

            let state = (node["state"] as? String ?? defaultState).lowercased()
            let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    let color = labelNode["color"] as? String
                    return LabelInfo(name: name, color: color)
                } ?? []

            var updatedAt: Date?
            if let dateStr = node["updatedAt"] as? String {
                updatedAt = dateFormatter.date(from: dateStr)
            }

            var projectStatus: TicketStatus = projectStatusOverride ?? .unknown
            if projectStatusOverride == nil,
               let projectItems = node["projectItems"] as? [String: Any],
               let itemNodes = projectItems["nodes"] as? [[String: Any]] {
                for item in itemNodes {
                    if let fv = item["fieldValueByName"] as? [String: Any],
                       let statusName = fv["name"] as? String {
                        projectStatus = TicketStatus(projectBoardName: statusName)
                        break
                    }
                }
            }

            return AssignedIssue(
                id: "github:\(repoName)#\(number)",
                number: number,
                title: title,
                state: state,
                url: url,
                repo: repoName,
                labels: labels,
                provider: .github,
                updatedAt: updatedAt,
                projectStatus: projectStatus
            )
        }
    }

    private func parseViewerPRs(_ viewerObj: [String: Any]?) -> [ViewerPR] {
        guard let pullRequests = viewerObj?["pullRequests"] as? [String: Any],
              let nodes = pullRequests["nodes"] as? [[String: Any]] else { return [] }

        return nodes.compactMap { node -> ViewerPR? in
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String else { return nil }

            let mergeable = node["mergeable"] as? String ?? "UNKNOWN"
            let mergeStateStatus = node["mergeStateStatus"] as? String ?? "UNKNOWN"
            let reviewDecision = node["reviewDecision"] as? String ?? ""
            let isDraft = node["isDraft"] as? Bool ?? false
            let headRefName = node["headRefName"] as? String ?? ""
            let headRefOid = node["headRefOid"] as? String ?? ""
            let baseRefName = node["baseRefName"] as? String ?? ""
            let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""

            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    let color = labelNode["color"] as? String
                    return LabelInfo(name: name, color: color)
                } ?? []

            let linkedNodes = (node["closingIssuesReferences"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            let linkedRefs: [ViewerPR.LinkedIssue] = linkedNodes.compactMap { ref in
                guard let n = ref["number"] as? Int else { return nil }
                let r = (ref["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
                return ViewerPR.LinkedIssue(number: n, repo: r)
            }

            let rollup = node["statusCheckRollup"] as? [String: Any]
            let checksState = rollup?["state"] as? String ?? ""
            let contextNodes = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let failedCheckNames: [String] = contextNodes.compactMap { ctx in
                // CheckRun: conclusion == "FAILURE"; StatusContext: state == "FAILURE"/"ERROR"
                if let conclusion = ctx["conclusion"] as? String, conclusion == "FAILURE" {
                    return ctx["name"] as? String
                }
                if let st = ctx["state"] as? String, st == "FAILURE" || st == "ERROR" {
                    return ctx["context"] as? String
                }
                return nil
            }

            let latestReviewNodes = (node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            let reviewStates = latestReviewNodes.compactMap { $0["state"] as? String }

            return ViewerPR(
                number: number,
                url: url,
                state: state,
                mergeable: mergeable,
                mergeStateStatus: mergeStateStatus,
                reviewDecision: reviewDecision,
                isDraft: isDraft,
                headRefName: headRefName,
                headRefOid: headRefOid,
                baseRefName: baseRefName,
                repoNameWithOwner: repoName,
                labels: labels,
                linkedIssueReferences: linkedRefs,
                checksState: checksState,
                failedCheckNames: failedCheckNames,
                latestReviewStates: reviewStates
            )
        }
    }

    private func parseReviewRequests(
        _ searchObj: [String: Any]?,
        dateFormatter: ISO8601DateFormatter,
        viewerLogin: String?
    ) -> [ReviewRequest] {
        guard let nodes = searchObj?["nodes"] as? [[String: Any]] else { return [] }

        // Only formal verdicts satisfy a review request. COMMENTED/PENDING
        // do not — gating on those would mis-complete a session before the
        // viewer has actually approved or requested changes.
        let satisfyingStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]

        var requests: [ReviewRequest] = []
        for node in nodes {
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else { continue }

            let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            let authorLogin = (node["author"] as? [String: Any])?["login"] as? String ?? ""
            let isDraft = node["isDraft"] as? Bool ?? false
            let headBranch = node["headRefName"] as? String ?? ""
            let headRefOid = node["headRefOid"] as? String
            let baseBranch = node["baseRefName"] as? String ?? ""
            let updatedAt = (node["updatedAt"] as? String).flatMap { dateFormatter.date(from: $0) }
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    let color = labelNode["color"] as? String
                    return LabelInfo(name: name, color: color)
                } ?? []

            // Latest viewer-authored review timestamp (APPROVED / CHANGES_REQUESTED
            // / DISMISSED only). Used by `decideReviewCompletions` to detect when
            // the reviewer has actually submitted a verdict so the session can be
            // auto-completed before the PR is merged.
            var viewerLastReviewedAt: Date?
            if let viewerLogin,
               let reviewNodes = ((node["reviews"] as? [String: Any])?["nodes"]) as? [[String: Any]] {
                for review in reviewNodes {
                    guard let author = (review["author"] as? [String: Any])?["login"] as? String,
                          author == viewerLogin,
                          let state = review["state"] as? String,
                          satisfyingStates.contains(state),
                          let submittedAtStr = review["submittedAt"] as? String,
                          let submittedAt = dateFormatter.date(from: submittedAtStr) else { continue }
                    if viewerLastReviewedAt == nil || submittedAt > viewerLastReviewedAt! {
                        viewerLastReviewedAt = submittedAt
                    }
                }
            }

            requests.append(ReviewRequest(
                id: "github:\(repoName)#\(number)",
                prNumber: number,
                title: title,
                url: url,
                repo: repoName,
                author: authorLogin,
                headBranch: headBranch,
                baseBranch: baseBranch,
                isDraft: isDraft,
                requestedAt: updatedAt,
                labels: labels,
                provider: .github,
                headRefOid: headRefOid,
                viewerLastReviewedAt: viewerLastReviewedAt
            ))
        }
        // Newest first so stale review requests sink to the bottom
        return requests.sorted { ($0.requestedAt ?? .distantPast) > ($1.requestedAt ?? .distantPast) }
    }

    private func parseRateLimit(_ obj: [String: Any]?) -> GitHubRateLimit? {
        guard let obj,
              let remaining = obj["remaining"] as? Int,
              let limit = obj["limit"] as? Int,
              let cost = obj["cost"] as? Int,
              let resetAtStr = obj["resetAt"] as? String else { return nil }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resetAt = fmt.date(from: resetAtStr)
            ?? ISO8601DateFormatter().date(from: resetAtStr)
            ?? Date().addingTimeInterval(60 * 60)

        return GitHubRateLimit(
            remaining: remaining,
            limit: limit,
            resetAt: resetAt,
            cost: cost,
            observedAt: Date()
        )
    }

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

        let store = JSONStore()

        for session in appState.sessions {
            guard session.id != AppState.managerSessionID else { continue }
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
            store.mutate { data in
                data.links.append(link)
            }
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

    /// For each non-archived, non-review session missing a `.pr` link with a
    /// resolvable (repoSlug, branch), query the provider directly and upsert
    /// a link when a PR exists on that branch. Runs once per refresh cycle
    /// after the reactive `applySessionPRLinks` pass.
    private func reconcileMissingPRLinks() async {
        let candidates = buildReconcileCandidates()
        guard !candidates.isEmpty else { return }

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

        applyReconciledPRLinks(Self.decideReconcileLinks(matches: matches))
    }

    /// Walk appState and build the set of sessions needing a reconcile pass.
    /// Runs on MainActor; safe to read appState directly.
    private func buildReconcileCandidates() -> [ReconcileCandidate] {
        var out: [ReconcileCandidate] = []
        for session in appState.sessions {
            guard session.id != AppState.managerSessionID else { continue }
            guard session.status != .archived else { continue }
            guard session.kind == .work else { continue }  // review sessions get PR links at creation
            let links = appState.links(for: session.id)
            guard !links.contains(where: { $0.linkType == .pr }) else { continue }

            let wts = appState.worktrees(for: session.id)
            guard let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first else { continue }
            guard !primaryWt.branch.isEmpty else { continue }

            let info = resolveRepoInfo(worktree: primaryWt)
            guard !info.slug.isEmpty else { continue }

            // Provider: prefer the session's recorded provider; fall back to
            // host sniffing when the session was created before the field
            // existed or when the host ≠ github.com.
            let provider: Provider
            let gitlabHost: String?
            if let p = session.provider {
                provider = p
                gitlabHost = (p == .gitlab) ? (info.host.isEmpty ? nil : info.host) : nil
            } else if info.host == "github.com" || info.host.isEmpty {
                provider = .github
                gitlabHost = nil
            } else {
                provider = .gitlab
                gitlabHost = info.host
            }

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

    /// One aliased `gh api graphql` call: for each candidate, fetch up to 5 PRs
    /// on that `headRefName`, most-recently-updated first. Returns `nil` on
    /// shell / rate-limit / parse failure so the reconcile pass can skip the
    /// cycle without treating a degraded response as "no PRs found".
    private func fetchPRsForReconcile(candidates: [ReconcileCandidate]) async -> [ReconcileBranchMatch]? {
        // Split each slug into (owner, repo). Skip any we can't parse.
        var parsed: [(idx: Int, cand: ReconcileCandidate, owner: String, repo: String)] = []
        for (i, c) in candidates.enumerated() {
            let parts = c.repoSlug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            parsed.append((i, c, String(parts[0]), String(parts[1])))
        }
        guard !parsed.isEmpty else { return [] }

        var queryParts: [String] = []
        var args: [String] = ["gh", "api", "graphql"]
        for p in parsed {
            queryParts.append("""
              pr\(p.idx): repository(owner: $owner\(p.idx), name: $repo\(p.idx)) {
                pullRequests(headRefName: $branch\(p.idx), first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) {
                  nodes { number url state updatedAt headRefName }
                }
              }
            """)
            args.append(contentsOf: ["-F", "owner\(p.idx)=\(p.owner)"])
            args.append(contentsOf: ["-F", "repo\(p.idx)=\(p.repo)"])
            args.append(contentsOf: ["-F", "branch\(p.idx)=\(p.cand.branch)"])
        }
        var varDecls: [String] = []
        for p in parsed {
            varDecls.append("$owner\(p.idx): String!, $repo\(p.idx): String!, $branch\(p.idx): String!")
        }
        let query = """
        query(\(varDecls.joined(separator: ", "))) {
        \(queryParts.joined(separator: "\n"))
          rateLimit { remaining limit resetAt cost }
        }
        """
        args.insert(contentsOf: ["-f", "query=\(query)"], at: 3)

        let result = await shellWithStatus(args: args)
        if result.exitCode != 0 {
            if handleGraphQLRateLimit(stderr: result.stderr) { return nil }
            print("[IssueTracker] Reconcile PR fetch failed (exit \(result.exitCode)): \(result.stderr.prefix(200))")
            return nil
        }
        return parseReconcilePRResponse(result.stdout, parsed: parsed)
    }

    private func parseReconcilePRResponse(
        _ output: String,
        parsed: [(idx: Int, cand: ReconcileCandidate, owner: String, repo: String)]
    ) -> [ReconcileBranchMatch]? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return nil }

        if let rl = parseRateLimit(dataObj["rateLimit"] as? [String: Any]) {
            appState.githubRateLimit = rl
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var matches: [ReconcileBranchMatch] = []
        for p in parsed {
            guard let repoObj = dataObj["pr\(p.idx)"] as? [String: Any],
                  let prs = repoObj["pullRequests"] as? [String: Any],
                  let nodes = prs["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                guard let number = node["number"] as? Int,
                      let url = node["url"] as? String,
                      let state = node["state"] as? String else { continue }
                let updatedAt = (node["updatedAt"] as? String).flatMap { dateFormatter.date(from: $0) }
                matches.append(ReconcileBranchMatch(
                    sessionID: p.cand.sessionID,
                    number: number,
                    url: url,
                    state: state,
                    updatedAt: updatedAt
                ))
            }
        }
        return matches
    }

    /// One `glab api` call per (host, candidate). Uses the REST endpoint
    /// because `glab mr list` at v1.82 lacks `--state` and `--output-format`
    /// (see repo CLAUDE.md). `glab api` with `GITLAB_HOST` set returns raw
    /// JSON reliably and supports `source_branch` + `state=all`.
    private func fetchGitLabMRsForReconcile(
        candidates: [ReconcileCandidate],
        host: String
    ) async -> [ReconcileBranchMatch] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var matches: [ReconcileBranchMatch] = []
        for candidate in candidates {
            let encodedSlug = candidate.repoSlug.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) ?? candidate.repoSlug
            let encodedBranch = candidate.branch.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) ?? candidate.branch
            let endpoint = "projects/\(encodedSlug)/merge_requests?source_branch=\(encodedBranch)&state=all&per_page=5&order_by=updated_at"

            let output: String
            do {
                output = try await shell(env: ["GITLAB_HOST": host], cwd: NSHomeDirectory(), "glab", "api", endpoint)
            } catch {
                print("[IssueTracker] Reconcile glab api failed for \(candidate.repoSlug)#\(candidate.branch) on \(host): \(error.localizedDescription.prefix(200))")
                continue
            }
            guard let data = output.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            for item in items {
                guard let number = item["iid"] as? Int,
                      let url = item["web_url"] as? String else { continue }
                let rawState = (item["state"] as? String) ?? ""
                let normalized = Self.normalizeGitLabPRState(rawState)
                let updatedAt = (item["updated_at"] as? String).flatMap { dateFormatter.date(from: $0) }
                matches.append(ReconcileBranchMatch(
                    sessionID: candidate.sessionID,
                    number: number,
                    url: url,
                    state: normalized,
                    updatedAt: updatedAt
                ))
            }
        }
        return matches
    }

    /// Persist the reconciliation decisions. Re-checks `appState.links` at
    /// write time so a concurrent `applySessionPRLinks` or hand-added PR link
    /// (identified by URL match) wins without leaving a duplicate row.
    private func applyReconciledPRLinks(_ picks: [ReconcileBranchMatch]) {
        guard !picks.isEmpty else { return }
        let store = JSONStore()
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
            store.mutate { data in
                data.links.append(link)
            }
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
    /// in the viewer-PR payload. No extra gh calls.
    private func applyPRStatuses(viewerPRs: [ViewerPR]) {
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: Self.mergePRRecords)

        var transitions: [PRStatusTransition] = []
        let sessionsWithPRs = appState.sessions.filter { $0.id != AppState.managerSessionID }
        for session in sessionsWithPRs {
            let links = appState.links(for: session.id)
            guard let prLink = links.first(where: { $0.linkType == .pr }) else { continue }
            guard let pr = byURL[prLink.url] else { continue }

            let newStatus = buildPRStatus(from: pr)
            let oldStatus = previousPRStatus[session.id]

            // Re-arm rules whose triggering condition has cleared, so a future
            // re-entry (approved → changesRequested again, passing → failing on
            // a new commit) can fire even if we previously emitted.
            if let old = oldStatus {
                if old.reviewStatus == .changesRequested && newStatus.reviewStatus != .changesRequested {
                    emittedTransitionKeys.remove("\(session.id.uuidString)|changesRequested")
                }
                if old.checksPass == .failing && newStatus.checksPass != .failing {
                    if let sha = old.headSha {
                        emittedTransitionKeys.remove("\(session.id.uuidString)|checksFailing|\(sha)")
                    }
                }
            }

            let candidates = PRStatus.transitions(
                from: oldStatus,
                to: newStatus,
                sessionID: session.id,
                prURL: prLink.url,
                prNumber: pr.number
            )
            for t in candidates where !emittedTransitionKeys.contains(t.dedupeKey) {
                emittedTransitionKeys.insert(t.dedupeKey)
                transitions.append(t)
            }

            previousPRStatus[session.id] = newStatus
            appState.prStatus[session.id] = newStatus
        }

        if !transitions.isEmpty {
            onPRStatusTransitions?(transitions)
        }

        applyAutoMerge(viewerPRs: viewerPRs)
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

        for session in appState.sessions where session.id != AppState.managerSessionID {
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

    /// Verify Crow authorship, lazily ensure the label exists, then enable
    /// auto-merge with squash + delete branch. Idempotent: success persists
    /// `Session.autoMergeEnabledAt`; failure clears the in-flight marker so
    /// the next poll retries.
    private func attemptEnableAutoMerge(session: Session, pr: ViewerPR) async {
        guard await prHasCrowAuthoredCommit(pr: pr) else {
            NSLog("[Crow] crow:merge ignored on %@ — no Crow-Session trailer matching a known session",
                  pr.url as NSString)
            // Leave the URL in autoMergeInFlight so we don't re-fetch
            // commits every minute for a permanently-ineligible PR. The
            // set is in-memory only — restart will re-check, which is
            // fine for what's a fairly rare label-misuse case.
            return
        }

        await ensureMergeLabel(repo: pr.repoNameWithOwner)

        let cmd = #"cd "$TMPDIR" && gh pr merge \#(pr.url) --auto --squash --delete-branch"#
        let result = await shellWithStatus(args: ["sh", "-c", cmd])
        if result.exitCode == 0 {
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
        } else {
            autoMergeInFlight.remove(pr.url)
            NSLog("[Crow] gh pr merge --auto failed for %@ (exit %d): %@",
                  pr.url as NSString, result.exitCode, String(result.stderr.prefix(300)) as NSString)
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
        guard await prHasCrowAuthoredCommit(pr: pr) else {
            NSLog("[Crow] crow:merge update-branch skipped on %@ — no Crow-Session trailer matching a known session",
                  pr.url as NSString)
            // Mirror attemptEnableAutoMerge: leave the URL in autoMergeInFlight
            // so we don't re-fetch commits every minute for an ineligible PR.
            return
        }

        let cmd = #"cd "$TMPDIR" && gh pr update-branch \#(pr.url)"#
        let result = await shellWithStatus(args: ["sh", "-c", cmd])
        // Always clear the in-flight marker so the next poll can merge (or
        // re-update once a new head appears). The per-head attempted key still
        // prevents re-updating the same head state.
        autoMergeInFlight.remove(pr.url)
        if result.exitCode == 0 {
            NSLog("[Crow] Updated branch for %@ (session %@, was BEHIND base)",
                  pr.url as NSString, session.id.uuidString as NSString)
        } else {
            NSLog("[Crow] gh pr update-branch failed for %@ (exit %d): %@",
                  pr.url as NSString, result.exitCode, String(result.stderr.prefix(300)) as NSString)
        }
    }

    /// Fetch the PR's commits and return true iff at least one carries a
    /// `Crow-Session: <uuid>` trailer matching a known session. Uses the
    /// REST `/repos/.../pulls/{N}/commits` endpoint (page-limited; the
    /// default 30-commit window is plenty for any Crow PR).
    private func prHasCrowAuthoredCommit(pr: ViewerPR) async -> Bool {
        let endpoint = "/repos/\(pr.repoNameWithOwner)/pulls/\(pr.number)/commits"
        let result = await shellWithStatus(args: ["gh", "api", endpoint])
        guard result.exitCode == 0 else {
            NSLog("[Crow] gh api %@ failed (exit %d): %@",
                  endpoint as NSString, result.exitCode,
                  String(result.stderr.prefix(300)) as NSString)
            return false
        }
        guard let data = result.stdout.data(using: .utf8),
              let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        let messages: [String] = nodes.compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }
        let knownIDs = Set(appState.sessions.map(\.id))
        return Self.crowAuthored(commitMessages: messages, knownSessionIDs: knownIDs)
    }

    /// Best-effort: ensure the `crow:merge` label exists in the repo so
    /// repo owners don't need to pre-create it. `gh label create` fails
    /// loudly when the label already exists; the failure is harmless and
    /// not surfaced.
    private func ensureMergeLabel(repo: String) async {
        guard !repo.isEmpty else { return }
        _ = await shellWithStatus(args: [
            "gh", "label", "create", Self.autoMergeLabel,
            "--repo", repo,
            "--color", "0E8A16",
            "--description", "Crow: enable auto-merge once mergeable"
        ])
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
            headSha: pr.headRefOid.isEmpty ? nil : pr.headRefOid
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
            $0.id != AppState.managerSessionID &&
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
        AppState.globalTerminalSessionID,
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
        let output: String
        do {
            // Use `glab api` rather than `glab issue list`: the latter shells
            // out to `git` even when no repo is involved and aborts with
            // "fatal: not a git repository" when cwd isn't a git working tree.
            output = try await shell(
                env: ["GITLAB_HOST": host],
                cwd: NSHomeDirectory(),
                "glab", "api", "issues?scope=assigned_to_me&state=opened&per_page=100"
            )
        } catch {
            print("[IssueTracker] fetchGitLabIssues(host: \(host)) failed: \(error)")
            return []
        }

        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return items.compactMap { item -> AssignedIssue? in
            guard let number = item["iid"] as? Int,
                  let title = item["title"] as? String,
                  let url = item["web_url"] as? String else { return nil }

            let state = item["state"] as? String ?? "opened"
            let labels = (item["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            let refs = item["references"] as? [String: Any]
            let fullRef = refs?["full"] as? String ?? ""

            return AssignedIssue(
                id: "gitlab:\(host):\(fullRef)",
                number: number, title: title, state: state == "opened" ? "open" : state,
                url: url, repo: fullRef, labels: labels, provider: .gitlab
            )
        }
    }

    // MARK: - Mark In Review

    func markInReview(sessionID: UUID) async {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let ticketURL = session.ticketURL,
              session.provider == .github else { return }

        guard let parsed = ProviderManager.parseTicketURLComponents(ticketURL) else {
            print("[IssueTracker] Could not parse ticket URL: \(ticketURL)")
            return
        }
        let owner = parsed.org
        let repoName = parsed.repo
        let number = parsed.number

        appState.isMarkingInReview[sessionID] = true
        defer { appState.isMarkingInReview[sessionID] = false }

        // Step 1: Query the project item ID, project ID, Status field ID, and available options
        // so we can find the "In Review" option to set.
        let query = """
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            issue(number: $number) {
              projectItems(first: 10) {
                nodes {
                  id
                  project { id }
                  fieldValueByName(name: "Status") {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      name
                      field {
                        ... on ProjectV2SingleSelectField {
                          id
                          options { id name }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

        let queryResult = await shellWithStatus(
            "gh", "api", "graphql",
            "-f", "query=\(query)",
            "-F", "owner=\(owner)",
            "-F", "repo=\(repoName)",
            "-F", "number=\(number)"
        )

        if queryResult.exitCode != 0 {
            if queryResult.stderr.contains("INSUFFICIENT_SCOPES") || queryResult.stderr.contains("read:project") || queryResult.stderr.contains("project") {
                reportScopeWarning("project")
            } else {
                print("[IssueTracker] GraphQL query failed: \(queryResult.stderr.prefix(200))")
            }
            return
        }

        // Parse the query response
        guard let data = queryResult.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let issueObj = repository["issue"] as? [String: Any],
              let projectItems = issueObj["projectItems"] as? [String: Any],
              let nodes = projectItems["nodes"] as? [[String: Any]],
              !nodes.isEmpty else {
            print("[IssueTracker] Issue \(owner)/\(repoName)#\(number) is not in any GitHub Project")
            return
        }

        // Find a project item that has a Status field with an "In Review" option
        var itemID: String?
        var projectID: String?
        var fieldID: String?
        var optionID: String?

        for node in nodes {
            guard let nodeID = node["id"] as? String,
                  let project = node["project"] as? [String: Any],
                  let projID = project["id"] as? String,
                  let fieldValue = node["fieldValueByName"] as? [String: Any],
                  let field = fieldValue["field"] as? [String: Any],
                  let fID = field["id"] as? String,
                  let options = field["options"] as? [[String: Any]] else { continue }

            // Find the "In Review" option (case-insensitive)
            for option in options {
                guard let optName = option["name"] as? String,
                      let optID = option["id"] as? String else { continue }
                let normalized = optName.lowercased().trimmingCharacters(in: .whitespaces)
                if normalized == "in review" || normalized == "review" {
                    itemID = nodeID
                    projectID = projID
                    fieldID = fID
                    optionID = optID
                    break
                }
            }
            if optionID != nil { break }
        }

        guard let itemID, let projectID, let fieldID, let optionID else {
            print("[IssueTracker] No 'In Review' status option found in project for \(owner)/\(repoName)#\(number)")
            return
        }

        // Step 2: Mutation to update the Status field to the "In Review" option
        let mutation = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
            value: { singleSelectOptionId: $optionId }
          }) { projectV2Item { id } }
        }
        """

        let mutationResult = await shellWithStatus(
            "gh", "api", "graphql",
            "-f", "query=\(mutation)",
            "-F", "projectId=\(projectID)",
            "-F", "itemId=\(itemID)",
            "-F", "fieldId=\(fieldID)",
            "-F", "optionId=\(optionID)"
        )

        if mutationResult.exitCode != 0 {
            if mutationResult.stderr.contains("INSUFFICIENT_SCOPES") {
                reportScopeWarning("project")
            } else {
                print("[IssueTracker] Failed to update project status: \(mutationResult.stderr.prefix(200))")
            }
            return
        }

        // Update local state
        if let idx = appState.assignedIssues.firstIndex(where: {
            $0.repo == "\(owner)/\(repoName)" && $0.number == number
        }) {
            appState.assignedIssues[idx].projectStatus = .inReview
        }

        print("[IssueTracker] Marked \(owner)/\(repoName)#\(number) as In Review")

        // Update local session status to .inReview
        appState.onSetSessionInReview?(sessionID)
    }

    // MARK: - Shell

    private func shell(env: [String: String] = [:], cwd: String? = nil, _ args: String...) async throws -> String {
        return try await shell(env: env, cwd: cwd, args: args)
    }

    private func shell(env: [String: String] = [:], cwd: String? = nil, args: [String]) async throws -> String {
        currentRefreshGhCalls += 1
        let args = args
        let env = env
        let cwd = cwd
        return try await Task.detached {
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.environment = env.isEmpty
                ? ShellEnvironment.shared.env
                : ShellEnvironment.shared.merging(env)
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            // Read pipes BEFORE waitUntilExit to avoid deadlock when
            // output exceeds the 64 KB pipe buffer (consolidated GraphQL
            // responses routinely reach ~86 KB).
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
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
        }.value
    }

    private struct ShellResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func shellWithStatus(_ args: String...) async -> ShellResult {
        return await shellWithStatus(args: args)
    }

    private func shellWithStatus(args: [String]) async -> ShellResult {
        return await shellWithStatus(env: [:], args: args)
    }

    private func shellWithStatus(env: [String: String], args: [String]) async -> ShellResult {
        currentRefreshGhCalls += 1
        let args = args
        let env = env
        return await Task.detached {
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.environment = env.isEmpty
                ? ShellEnvironment.shared.env
                : ShellEnvironment.shared.merging(env)
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run() } catch { return ShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1) }
            // Read pipes BEFORE waitUntilExit to avoid pipe-buffer deadlock.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ShellResult(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        }.value
    }
}
