import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

/// The board poll, extracted from `IssueTracker` (CROW-1094). Owns the
/// consolidated GitHub GraphQL query, the stale-PR follow-up fetch, the
/// GitLab / Jira assigned-issue fetches, PR-record dedup, and the auto-create
/// (`crow:auto` / `crow:explore`) dispatch. Stateless except for the auto-create in-flight /
/// log-rate-limit bookkeeping; reaches the shared warnings + rate-limit sink,
/// the auto-create callback/toggle, `appState`, `providerManager`, and the
/// shared `JSONStore` through an unowned back-reference to the tracker.
/// `refresh()` still drives every method here, in the current order.
@MainActor
final class BoardPoller {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }
    private var providerManager: ProviderManager { owner.providerManager }
    private var store: JSONStore { owner.store }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    /// Issue URLs we've already dispatched for auto-create but whose session
    /// hasn't yet landed in `appState`. Prevents repeat dispatches during the
    /// window between trigger and session registration.
    private var autoCreateInFlight: Set<String> = []

    /// Hourly clock for the "crow:auto issues with no handler" steady-state
    /// line, so a healthy steady state doesn't fill `crowd-automation.log`.
    private var lastAutoCreateUndispatchableLogAt: Date?

    init(owner: IssueTracker) { self.owner = owner }

    // MARK: - Auto-create on assign
    /// Dispatches `onAutoCreateRequest` for open assigned issues carrying the
    /// `crow:auto` or `crow:explore` label, then asynchronously strips the
    /// trigger label(s) so the claim is one-shot and visible across machines.
    /// Issues that already have an active session are treated as "work picked
    /// up elsewhere" — we still strip the stale label but don't re-dispatch.
    ///
    /// No-op when the global `autoCreateWatcherEnabled` setting is off
    /// (CROW-312). The label is intentionally left in place while disabled
    /// so a later opt-in still picks up the issue on the next poll.
    ///
    /// Also a no-op when no `onAutoCreateRequest` handler is wired: since
    /// CROW-782 the *provider* is armed even on a daemon with no tmux (and so no
    /// Manager terminal to spawn into), and dispatching into a nil callback here
    /// would strip `crow:auto` / `crow:explore` anyway — permanently burning the
    /// one-shot trigger for a workspace that was never created (review #787).
    /// Same contract as the disabled case: leave the label, pick it up once a
    /// host can act.
    func detectAutoCreateCandidates(issues: [AssignedIssue]) {
        guard Self.canRunAutoCreate(enabled: owner.autoCreateWatcherEnabledProvider(),
                                    hasHandler: owner.onAutoCreateRequest != nil) else {
            if owner.autoCreateWatcherEnabledProvider() { logAutoCreateUndispatchableIfDue(issues: issues) }
            return
        }
        // Purge in-flight URLs that now have an active session — the dispatch
        // succeeded and the set can shrink.
        if !autoCreateInFlight.isEmpty {
            let active = Set(appState.activeSessions.compactMap(\.ticketURL))
            autoCreateInFlight.subtract(active)
        }

        for issue in issues where issue.state == "open" {
            guard let kind = Self.autoCreateKind(for: issue) else { continue }
            guard !autoCreateInFlight.contains(issue.url) else { continue }

            if appState.linkedSession(for: issue) != nil {
                // Stale label — work already picked up elsewhere. Best-effort cleanup.
                Task { [weak self] in await self?.removeAutoCreateLabels(from: issue) }
                continue
            }

            autoCreateInFlight.insert(issue.url)
            owner.onAutoCreateRequest?(issue, kind)
            Task { [weak self] in await self?.removeAutoCreateLabels(from: issue) }
        }
    }

    /// Whether the auto-create sweep may run — i.e. whether stripping `crow:auto`
    /// / `crow:explore` (which the sweep always does after dispatch) is justified.
    /// Requires BOTH the config opt-in AND a wired handler: dispatching into a
    /// nil callback still burns the one-shot label without creating anything
    /// (review #787). Pure so the rule is unit-testable without an `IssueTracker`.
    nonisolated static func canRunAutoCreate(enabled: Bool, hasHandler: Bool) -> Bool {
        enabled && hasHandler
    }

    /// Which seed to dispatch for a labeled issue. `crow:auto` wins when both
    /// trigger labels are present — implementation is the stronger intent
    /// (CROW-1149). Nil when neither label is on the issue. Pure so the
    /// precedence rule is unit-testable without an `IssueTracker`.
    nonisolated static func autoCreateKind(for issue: AssignedIssue) -> IssueTracker.AutoCreateKind? {
        if hasTriggerLabel(issue, IssueTracker.autoCreateLabel) { return .work }
        if hasTriggerLabel(issue, IssueTracker.exploreCreateLabel) { return .explore }
        return nil
    }

    /// Trigger labels actually present on `issue` — both, when both were
    /// applied. Stripping the pair together prevents `crow:explore` from
    /// sitting around after `crow:auto` already claimed the ticket.
    nonisolated static func autoCreateLabelsToStrip(on issue: AssignedIssue) -> [String] {
        var labels: [String] = []
        if hasTriggerLabel(issue, IssueTracker.autoCreateLabel) {
            labels.append(IssueTracker.autoCreateLabel)
        }
        if hasTriggerLabel(issue, IssueTracker.exploreCreateLabel) {
            labels.append(IssueTracker.exploreCreateLabel)
        }
        return labels
    }

    nonisolated static func hasTriggerLabel(_ issue: AssignedIssue, _ name: String) -> Bool {
        issue.labels.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Say (hourly at most) that `crow:auto` / `crow:explore` issues are waiting
    /// but nothing can act on them — the enabled-but-undispatchable state a
    /// no-tmux daemon is in. Silent when there's nothing labeled, so a normal
    /// headless daemon with no pending auto-create work doesn't log at all.
    private func logAutoCreateUndispatchableIfDue(issues: [AssignedIssue]) {
        let waiting = issues.filter { issue in
            issue.state == "open" && Self.autoCreateKind(for: issue) != nil
        }
        guard !waiting.isEmpty else { return }
        let now = Date()
        if let last = lastAutoCreateUndispatchableLogAt, now.timeIntervalSince(last) < 3600 { return }
        lastAutoCreateUndispatchableLogAt = now
        CrowLog.automation(
            "crow:auto: \(waiting.count) labeled issue(s) waiting but no onAutoCreateRequest handler is "
            + "wired (no Manager terminal — is tmux available?); leaving the label in place")
    }

    /// Best-effort removal of the trigger label(s). Failure is logged and
    /// otherwise ignored — the in-memory `autoCreateInFlight` + active-session
    /// dedup keeps duplicate spawns at bay until the label is gone.
    private func removeAutoCreateLabels(from issue: AssignedIssue) async {
        let toRemove = Self.autoCreateLabelsToStrip(on: issue)
        guard !toRemove.isEmpty else { return }
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
            try await backend.setLabels(url: issue.url, add: [], remove: toRemove)
        } catch {
            print("[IssueTracker] failed to remove \(toRemove.joined(separator: ", ")) from \(issue.url): \(error.localizedDescription)")
        }
    }

    // MARK: - Consolidated GraphQL Query

    struct ConsolidatedGitHubResponse: Sendable {
        let openIssues: [AssignedIssue]
        let closedIssues: [AssignedIssue]
        /// True 24h closed total (search `issueCount`) — `closedIssues` holds
        /// at most the 50 fetched nodes, so the done badge counts this instead.
        let closedTotalCount: Int
        let viewerPRs: [ViewerPR]
        let reviewRequests: [ReviewRequest]
        /// PRs the viewer has reviewed that are no longer in the requested
        /// queue, from the `reviewed-by:@me` searches (CROW-982, CROW-990). Kept
        /// separate from `reviewRequests` all the way to the board: these are
        /// precisely the PRs that have *left* the requested queue, so merging
        /// them earlier would corrupt every count and notification derived from
        /// "reviews requested of me".
        let reviewedPRs: [ReviewRequest]
        /// The authenticated user's login, carried so the stale-PR follow-up in
        /// the *same* cycle can ask GitHub for the viewer's own latest verdict
        /// (CROW-945). Empty when `listMonitoredPRs` failed or degraded.
        let viewerLogin: String
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
    ///
    /// **Every field must be carried here.** `PRRecord`'s initializer defaults
    /// mean an omitted field compiles silently and reaches the watchers as
    /// "absent" — which is how #838 blinded auto-merge (dropped `labels`) and
    /// how the CROW-921 reviewer fields were dropped on their first cut
    /// (review of #930): an empty `changesRequestedReviewerLogins` reads as
    /// `.noReviewers` and the PR is never re-requested, while a lost
    /// `hasPendingReviewRequest` demotes an `.awaitingReviewer` PR back to
    /// `.needsRefine` and re-prompts the agent while the reviewer is already
    /// looking. `IssueTrackerDedupTests.dedupedByURLUnionsLabelsAndReviewerFields`
    /// is the assembly guard; extend it when `PRRecord` grows.
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
            // Same rule as `latestReviewStates` above, for the same reason:
            // the stale-PR query doesn't select reviewer identity, so an empty
            // array here means "not fetched", never "nobody" (CROW-921).
            // Dropping these blinds the auto-re-request watcher exactly the
            // way #838 blinded the auto-merge watcher by dropping `labels`.
            changesRequestedReviewerLogins: winner.changesRequestedReviewerLogins.isEmpty
                ? loser.changesRequestedReviewerLogins : winner.changesRequestedReviewerLogins,
            pendingReviewerLogins: winner.pendingReviewerLogins.isEmpty
                ? loser.pendingReviewerLogins : winner.pendingReviewerLogins,
            // OR, not pick-a-side: `false` means "not fetched" on every path
            // that doesn't select `reviewRequests` (the stale query, GitLab),
            // so a `true` from either record is the only informative value.
            hasPendingReviewRequest: winner.hasPendingReviewRequest || loser.hasPendingReviewRequest,
            // Latest wins, nil-tolerantly — same "nil means not fetched" rule
            // as the fields above (CROW-945). The viewer-PR query never selects
            // this, so picking a side would drop the stale-PR query's answer
            // (the only one there is) whenever the viewer record won the rank.
            // Dropping it re-opens CROW-945: the round would stop closing.
            viewerLastReviewedAt: [winner.viewerLastReviewedAt, loser.viewerLastReviewedAt]
                .compactMap { $0 }.max(),
            // `updatedAt` was silently dropped here until CROW-945 — the exact
            // failure this banner warns about, in the function the banner is
            // attached to. It tie-breaks reconcile when several non-OPEN PRs
            // share a branch, so losing it made that choice arbitrary.
            updatedAt: [winner.updatedAt, loser.updatedAt].compactMap { $0 }.max(),
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
    func runConsolidatedGitHubQuery() async -> ConsolidatedGitHubResponse? {
        let taskBackend = providerManager.taskBackend(for: .github)
        let codeBackend = providerManager.codeBackend(for: .github)!

        async let assignedAsync = taskBackend.listAssigned()
        async let monitoredAsync = codeBackend.listMonitoredPRs()

        let assigned: AssignedListing
        let monitored: MonitoredPRListing
        do {
            assigned = try await assignedAsync
        } catch {
            owner.handleGitHubBackendError(error, operation: "listAssigned")
            // Drain the second task so we don't leak an unawaited future.
            _ = try? await monitoredAsync
            return nil
        }
        do {
            monitored = try await monitoredAsync
        } catch {
            owner.handleGitHubBackendError(error, operation: "listMonitoredPRs")
            return nil
        }

        if let scope = assigned.missingScope {
            // listAssigned silently degrades on INSUFFICIENT_SCOPES (drops
            // projectItems) and reports the scope here so the warning UI
            // stays lit instead of getting cleared on the next poll. This
            // preserves the prior `owner.reportScopeWarning("read:project")`
            // behavior the consolidated query had inline.
            owner.reportScopeWarning(scope)
        } else {
            owner.clearScopeWarning()
        }

        // The backends recover accessible-org data on SAML enforcement and
        // flag the listing rather than throwing, so the response is still
        // assembled above. Light the one-time warning while any org stays
        // blocked; clear it once a clean poll returns.
        if assigned.samlRestricted || monitored.samlRestricted {
            owner.reportSAMLWarning()
        } else {
            owner.clearSAMLWarning()
        }
        return ConsolidatedGitHubResponse(
            openIssues: assigned.open,
            closedIssues: assigned.closed,
            closedTotalCount: assigned.closedTotalCount,
            viewerPRs: monitored.viewerPRs,
            reviewRequests: monitored.reviewRequests,
            reviewedPRs: monitored.reviewedPRs,
            viewerLogin: monitored.viewerLogin,
            rateLimit: assigned.rateLimit ?? monitored.rateLimit
        )
    }

    // MARK: - Stale PR Follow-up

    /// PR URLs linked to active/paused/inReview sessions that are NOT in
    /// `openPRURLs`. These are the PRs we need to fetch state for to surface
    /// merged/closed status on the badge and drive auto-complete.
    /// Completed sessions are skipped — their badge state is set in-memory
    /// during the cycle they auto-complete and is preserved thereafter.
    func collectStalePRURLs(excluding openPRURLs: Set<String>) -> [String] {
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
    struct StalePRFetchResult {
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
    func fetchStalePRStates(urls: [String], viewerLogin: String) async -> StalePRFetchResult {
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
                let states = try await backend.prStates(refs: githubRefs, viewerLogin: viewerLogin)
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
                owner.handleGitHubBackendError(error, operation: "prStates(github)")
                complete = false
            }
        }

        for (host, refs) in gitlabByHost {
            let backend = providerManager.codeBackend(for: .gitlab, host: host)!
            do {
                let states = try await backend.prStates(refs: refs, viewerLogin: nil)
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
            pendingReviewerLogins: pr.pendingReviewerLogins,
            hasPendingReviewRequest: pr.hasPendingReviewRequest,
            viewerLastReviewedAt: pr.viewerLastReviewedAt,
            updatedAt: pr.updatedAt,
            mergeCommitOid: pr.mergeCommitOid,
            repoAutoMergeAllowed: pr.repoAutoMergeAllowed
        )
    }

    /// Copy `pr` with `labels` replaced. Companion to ``withURL(_:url:)``, and
    /// unlike it this preserves **every** field — `repoAutoMergeAllowed` in
    /// particular decides a branch in ``evaluateAutoMerge(session:byURL:)``, so
    /// dropping it here would silently change the verdict.
    ///
    /// Used by ``reevaluateAutoMergeAfterLabel(session:prURL:)`` to union in a
    /// label we just provably added but the provider's read side may not report
    /// yet (#931).
    nonisolated static func withLabels(_ pr: ViewerPR, labels: [LabelInfo]) -> ViewerPR {
        PRRecord(
            number: pr.number,
            url: pr.url,
            state: pr.state,
            mergeable: pr.mergeable,
            mergeStateStatus: pr.mergeStateStatus,
            reviewDecision: pr.reviewDecision,
            isDraft: pr.isDraft,
            headRefName: pr.headRefName,
            headRefOid: pr.headRefOid,
            baseRefName: pr.baseRefName,
            repoNameWithOwner: pr.repoNameWithOwner,
            labels: labels,
            linkedIssueReferences: pr.linkedIssueReferences,
            checksState: pr.checksState,
            failedCheckNames: pr.failedCheckNames,
            latestReviewStates: pr.latestReviewStates,
            lastChangesRequestedAt: pr.lastChangesRequestedAt,
            lastSubstantiveCommitAt: pr.lastSubstantiveCommitAt,
            // These three were dropped here until CROW-945, contradicting the
            // "preserves **every** field" claim above. `evaluateAutoMerge` is
            // reached through this helper and reads them, and an empty
            // `changesRequestedReviewerLogins` reads as `.noReviewers` — the
            // same shape of silent blinding as #838.
            changesRequestedReviewerLogins: pr.changesRequestedReviewerLogins,
            pendingReviewerLogins: pr.pendingReviewerLogins,
            hasPendingReviewRequest: pr.hasPendingReviewRequest,
            viewerLastReviewedAt: pr.viewerLastReviewedAt,
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

    // MARK: - GitLab

    /// Fetch assigned GitLab issues for one host, including the recently-closed
    /// half (#697) so GitLab-backed workspaces feed the done-count badge.
    /// Best-effort: degrades to an empty listing on failure, mirroring the
    /// Jira / Corveil paths.
    func fetchGitLabIssues(host: String) async -> AssignedListing {
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
    func enrichGitLabMRStatus(_ issues: [AssignedIssue], host: String) async -> [AssignedIssue] {
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

    /// Fetch assigned Jira issues for one workspace config, including the
    /// recently-Done half (#536) so tickets in their mapped Done status surface
    /// in the board's Done section. Best-effort: degrades to an empty listing on
    /// failure, mirroring the GitLab / Corveil paths.
    func fetchJiraIssues(config: JiraConfig) async -> AssignedListing {
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
}

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` spelling used by refresh(), the other
// collaborators, and the tests. The shared PR-record helpers (mergePRRecords /
// dedupedByURL) live here now; everything routes through these forwarders.
extension IssueTracker {
    typealias ConsolidatedGitHubResponse = BoardPoller.ConsolidatedGitHubResponse
    typealias StalePRFetchResult = BoardPoller.StalePRFetchResult

    nonisolated static func mergePRRecords(_ lhs: ViewerPR, _ rhs: ViewerPR) -> ViewerPR {
        BoardPoller.mergePRRecords(lhs, rhs)
    }

    nonisolated static func dedupedByURL(_ prs: [ViewerPR]) -> [ViewerPR] {
        BoardPoller.dedupedByURL(prs)
    }

    nonisolated static func mergeListing(_ listing: AssignedListing) -> (issues: [AssignedIssue], doneCount: Int) {
        BoardPoller.mergeListing(listing)
    }

    nonisolated static func parseGitLabMRURL(_ url: String) -> (host: String, slug: String, number: Int)? {
        BoardPoller.parseGitLabMRURL(url)
    }

    nonisolated static func normalizeGitLabPRState(_ raw: String) -> String {
        BoardPoller.normalizeGitLabPRState(raw)
    }

    nonisolated static func parseGitLabStaleMRResponse(
        _ output: String, fallbackURL: String, fallbackSlug: String
    ) -> ViewerPR? {
        BoardPoller.parseGitLabStaleMRResponse(
            output, fallbackURL: fallbackURL, fallbackSlug: fallbackSlug)
    }

    nonisolated static func withLabels(_ pr: ViewerPR, labels: [LabelInfo]) -> ViewerPR {
        BoardPoller.withLabels(pr, labels: labels)
    }

    nonisolated static func canRunAutoCreate(enabled: Bool, hasHandler: Bool) -> Bool {
        BoardPoller.canRunAutoCreate(enabled: enabled, hasHandler: hasHandler)
    }

    nonisolated static func autoCreateKind(for issue: AssignedIssue) -> AutoCreateKind? {
        BoardPoller.autoCreateKind(for: issue)
    }

    nonisolated static func autoCreateLabelsToStrip(on issue: AssignedIssue) -> [String] {
        BoardPoller.autoCreateLabelsToStrip(on: issue)
    }
}

// MARK: - Jira config resolution (shared by ticket transitions, CROW-1094)
//
// Lives with the Jira fetch path; the tracker's transition API reaches it
// through the IssueTracker.jiraConfig forwarder below.
extension BoardPoller {
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
}

extension IssueTracker {
    static func jiraConfig(forTicket ticketURL: String) -> JiraConfig {
        BoardPoller.jiraConfig(forTicket: ticketURL)
    }
}
