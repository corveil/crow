import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

/// The auto-merge watcher (CROW-299), extracted from `IssueTracker`
/// (CROW-1094). Ensures the `crow:merge` label, enables GitHub native
/// auto-merge (or direct-merges / updates-branch as a fallback) for
/// Crow-authored PRs, and publishes the per-session verdict. Owns all its
/// merge bookkeeping. Reaches `appState`, `providerManager`, the shared
/// `JSONStore`, the board poll's stale-PR fetch, PR attribution, and the
/// auto-merge callbacks/toggle through an unowned back-reference. The shared
/// `codeBackend` / `prHasCrowAuthoredCommit` helpers belong to this type and
/// are re-exposed on the tracker for the rebase / re-review watchers.
///
/// Split across sibling files by CROW-1286 so a policy or label change reviews
/// apart from the irreversible merge paths. This file keeps the watcher —
/// in-memory state plus the poll (`applyAutoMerge`) and targeted
/// (`evaluateAutoMerge` / `reevaluateAutoMergeAfterLabel`) decisions and their
/// verdicts. The eligibility policy lives in `AutoMergePolicy`, the enable /
/// direct-merge / update-branch attempt paths in `AutoMergeController+Attempts`,
/// the `crow:merge` label memo in `AutoMergeController+Label`, and the
/// `IssueTracker` facade in `AutoMergeController+IssueTracker`.
@MainActor
final class AutoMergeController {
    // Internal (not private) so the sibling extension files
    // (`AutoMergeController+Attempts`, `+Label`, `AutoMergePolicy`) can reach
    // the owner back-reference and the shared `appState` / `providerManager` /
    // `store` accessors. A `private` here is only file-scoped, and an extension
    // in another file cannot see it (CROW-1286).
    unowned let owner: IssueTracker
    var appState: AppState { owner.appState }
    var providerManager: ProviderManager { owner.providerManager }
    var store: JSONStore { owner.store }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    init(owner: IssueTracker) { self.owner = owner }

    // MARK: - State
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
    ///
    /// `attemptUpdateBranch` is the exception: it clears the marker on *every*
    /// path (#944), because `autoUpdateBranchAttempted` already suppresses
    /// re-checks per head and leaving it set instead made the UI claim, for the
    /// process lifetime, that Crow was mid-attempt on a PR it had abandoned.
    /// Internal (not private) so `@testable` tests can assert that.
    var autoMergeInFlight: Set<String> = []

    /// Last time we logged "auto-merge watcher disabled" to the automation log.
    /// Rate-limits that line to hourly so a deliberately-off watcher doesn't
    /// bury the interesting entries at one line per 60s poll (CROW-782).
    private var lastAutoMergeDisabledLogAt: Date?


    /// Why we permanently stopped trying to auto-merge a PR, keyed by PR URL.
    /// `autoMergeInFlight` is deliberately left set for permanent outcomes (repo
    /// disallows auto-merge, no Crow-Session trailer) so the failure isn't
    /// re-logged every poll — but then the per-poll summary would report a bare
    /// `in-flight` forever instead of the real reason. Recording it here keeps
    /// the summary honest (review #787). Internal (not private) so the attempt
    /// paths in `AutoMergeController+Attempts` can latch the reason.
    var autoMergePermanentSkips: [String: String] = [:]

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
    /// Internal (not private) so `@testable` tests can read the dispatch
    /// decision without a live backend, matching ``autoReRequestAttempted``.
    var autoUpdateBranchAttempted: Set<String> = []

    /// Consecutive failed `updateBranch` calls per `autoUpdateBranchAttempted`
    /// key. The per-head guard alone deadlocks on failure — it says "retry once
    /// the head commit changes", and a failed update is exactly what did not
    /// change the head commit, so one rate limit or 502 parked a `BEHIND` merge
    /// candidate until a human pushed something (#944). Mirrors
    /// ``autoRebaseFailureCounts``. Cleared on success; pruned alongside
    /// `autoUpdateBranchAttempted`. In-memory only.
    var autoUpdateBranchFailureCounts: [String: Int] = [:]

    /// Repos whose `crow:merge` label we have already created — or confirmed
    /// present — this process lifetime. Keyed `"<provider>\n<owner/repo>"`,
    /// provider-qualified because an `owner/repo` slug is not unique across
    /// hosts.
    ///
    /// `ensureMergeLabel` is a `gh label create` shell-out that succeeds by
    /// swallowing "already exists", so after the first call it is pure latency:
    /// the watcher pays it once per dispatched PR per poll and `addMergeLabel`
    /// pays it on every click (#931). `GitHubCodeBackend` is a `struct` rebuilt
    /// by every `ProviderManager.codeBackend(for:)` call, so the memo cannot
    /// live there without static mutable state; `IssueTracker` is the one
    /// long-lived `@MainActor` object both callers already route through.
    ///
    /// Populated ONLY on success — a throw leaves the key absent so the next
    /// call retries. Latching a repo the token couldn't reach would be exactly
    /// the "reported success for work it never did" failure CROW-816 removed.
    /// Never invalidated: a label deleted out from under a running daemon is
    /// re-created after the next restart, and in between `addMergeLabel` still
    /// *throws* on the real `gh pr edit --add-label` failure. Internal (not
    /// private) so the label memo in `AutoMergeController+Label` owns it.
    var ensuredMergeLabelRepos: Set<String> = []

    /// In-flight `ensureMergeLabel` calls, same key as
    /// ``ensuredMergeLabelRepos``. Without this, the first poll that dispatches
    /// N PRs in one repo fires N concurrent identical shell-outs before any of
    /// them can populate the memo — which would only take effect from the
    /// *second* poll onward. Internal (not private) so the label memo in
    /// `AutoMergeController+Label` owns it.
    var ensureMergeLabelTasks: [String: Task<Void, Error>] = [:]

    // MARK: - Poll & targeted evaluation

    /// Per-refresh entry point. Picks candidate (session, PR) pairs and
    /// kicks off the async enable flow once each. Publishes a per-session
    /// verdict to `appState.autoMergeState` on the way through, so the reason a
    /// PR didn't merge reaches the UI and not just the automation log (#888).
    /// No-op (beyond publishing an `off` verdict) when the global
    /// `autoMergeWatcherEnabled` setting is off.
    ///
    /// A thin aggregator over ``evaluateAutoMerge(session:byURL:)`` since #931:
    /// `addMergeLabel` re-evaluates a single session through the same function
    /// rather than paying for a whole board poll.
    func applyAutoMerge(viewerPRs: [ViewerPR]) {
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: IssueTracker.mergePRRecords)

        guard owner.autoMergeWatcherEnabledProvider() else {
            // Durable, not silent: this exact early return is how the tmux-gated
            // wiring regression went dark for weeks (CROW-782). Rate-limited to
            // once per hour so an intentionally-disabled watcher doesn't spam.
            logAutoMergeDisabledIfDue()
            // The log line is global; the verdict is per-PR. Someone who just
            // applied `crow:merge` needs to see *on that session* that nothing
            // is listening — that specific confusion is the whole of #888.
            for session in appState.sessions where !session.isManager {
                publishWatcherOffVerdict(session: session, byURL: byURL)
            }
            return
        }
        guard !viewerPRs.isEmpty else {
            CrowLog.automation("auto-merge: no viewer PRs in this poll's fetch — nothing to evaluate")
            return
        }

        // Drop per-head bookkeeping for heads no longer in the poll, so these
        // maps don't grow for the daemon's lifetime (#944 — `autoUpdateBranch-
        // Attempted` was never pruned at all). Guarded by the non-empty check
        // above so a failed poll can't wipe live state, and done *here* rather
        // than in `evaluateAutoMerge`: that is also called from
        // `reevaluateAutoMergeAfterLabel` with a single-entry map, where this
        // would wipe every other PR's key.
        let liveHeadKeys = Set(viewerPRs.map { "\($0.url)\n\($0.headRefOid)" })
        autoUpdateBranchAttempted.formIntersection(liveHeadKeys)
        autoUpdateBranchFailureCounts = autoUpdateBranchFailureCounts.filter {
            liveHeadKeys.contains($0.key)
        }

        var enabledCount = 0
        var updateBranchCount = 0
        var directMergeCount = 0
        var skips: [String] = []

        for session in appState.sessions where !session.isManager {
            let outcome = evaluateAutoMerge(session: session, byURL: byURL)
            if let skip = outcome.skip { skips.append(skip) }
            switch outcome.dispatch {
            case .enable: enabledCount += 1
            case .updateBranch: updateBranchCount += 1
            case .directMerge: directMergeCount += 1
            case .none: break
            }
        }

        // One line per poll, always — an empty candidate set is itself the
        // answer to "why didn't my PR merge?" (CROW-782).
        let skipDetail = skips.isEmpty ? "" : " [\(skips.joined(separator: ", "))]"
        CrowLog.automation(
            "auto-merge: dispatched=\(enabledCount) updateBranch=\(updateBranchCount) "
            + "directMerge=\(directMergeCount) skipped=\(skips.count)\(skipDetail)")
    }

    /// The watcher-off verdict for one session. Split out of ``applyAutoMerge``'s
    /// early return so ``reevaluateAutoMergeAfterLabel(session:prURL:)`` publishes
    /// the *same* verdict from the same code rather than a second hand-rolled
    /// copy that drifts — the class of bug #888 was.
    ///
    /// Only speaks about a PR that actually asked for auto-merge: an unlabeled
    /// PR has no 🏷 and must not grow auto-merge vocabulary it never earned.
    ///
    /// Internal (not private) so `@testable` tests can drive one session's
    /// verdict without standing up a fake provider backend, matching
    /// ``pendingMergeLabelSessions``.
    func publishWatcherOffVerdict(session: Session, byURL: [String: ViewerPR]) {
        guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }),
              let pr = byURL[prLink.url],
              Self.hasAutoMergeLabel(pr: pr) else {
            appState.autoMergeState.removeValue(forKey: session.id)
            return
        }
        publishAutoMergeVerdict(.watcherOff, session: session, pr: pr)
    }

    /// Evaluate one session against a PR snapshot: publish its verdict and, if
    /// it is a candidate, dispatch exactly one of the three attempts.
    ///
    /// This is the *whole* of ``applyAutoMerge``'s per-session decision, lifted
    /// so the poll path and the post-`add-merge-label` targeted path share one
    /// implementation (#931). Callers must have already checked the watcher
    /// toggle (see ``publishWatcherOffVerdict(session:byURL:)``) — that toggle is
    /// global and its verdict a different shape, so folding it in here would
    /// mean every caller paying for a guard it already made.
    ///
    /// `byURL` is the caller's snapshot keyed by PR URL. The poll path passes
    /// every PR in the fetch; the targeted path passes a single-entry map. The
    /// `.notInViewerPRs` branch reads "this PR wasn't in the snapshot", which is
    /// the honest answer for both.
    ///
    /// Internal (not private) so `@testable` tests can assert that the targeted
    /// path publishes the same verdict as the poll path without standing up a
    /// fake provider backend, matching ``pendingMergeLabelSessions``.
    @discardableResult
    func evaluateAutoMerge(session: Session, byURL: [String: ViewerPR]) -> AutoMergeOutcome {
        guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else {
            appState.autoMergeState.removeValue(forKey: session.id)
            return AutoMergeOutcome()
        }
        guard !autoMergeInFlight.contains(prLink.url) else {
            // A permanent outcome keeps its marker set on purpose — report
            // the reason it stopped, not the bare marker (review #787).
            let latched = autoMergePermanentSkips[prLink.url]
                .flatMap(AutoMergeSkipReason.init(rawValue:)) ?? .inFlight
            // The async attempt publishes its own verdict; don't overwrite a
            // richer one with the bare in-flight marker.
            if appState.autoMergeState[session.id] == nil {
                publishAutoMergeVerdict(latched, session: session, pr: byURL[prLink.url])
            }
            return AutoMergeOutcome(skip: "\(prLink.url):\(latched.rawValue)")
        }
        guard let pr = byURL[prLink.url] else {
            // The PR is linked to a live session but absent from the
            // viewer-PR fetch — a fetch/scope problem, not an eligibility
            // one, and invisible before CROW-782. The log line is
            // unconditional (it's fetch health, not an auto-merge verdict);
            // the *chip* is not.
            //
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
            return AutoMergeOutcome(skip: "\(prLink.url):\(AutoMergeSkipReason.notInViewerPRs.rawValue)")
        }
        if let reason = Self.autoMergeSkipReason(pr: pr, session: session) {
            publishAutoMergeVerdict(reason, session: session, pr: pr)
            return AutoMergeOutcome(skip: "#\(pr.number):\(reason.rawValue)")
        }

        if Self.shouldDirectMerge(pr: pr, session: session) {
            // The repo forbids GitHub's auto-merge queue, so `--auto` can
            // never succeed here — but the PR is green and approved, which
            // is exactly the case that used to sit labeled forever (#888).
            autoMergeInFlight.insert(prLink.url)
            Task { [weak self] in await self?.attemptDirectMerge(session: session, pr: pr) }
            return AutoMergeOutcome(dispatch: .directMerge)
        }
        if Self.shouldUpdateBranchBeforeMerge(pr: pr, session: session) {
            // Behind base: bring the branch up to date this turn instead
            // of merging. One attempt per head commit (loop safety); the
            // next poll re-evaluates once GitHub recomputes mergeability.
            let key = "\(prLink.url)\n\(pr.headRefOid)"
            guard !autoUpdateBranchAttempted.contains(key) else {
                // Prefer a recorded permanent reason over the vaguer
                // "already attempted for this head" (#944) — same idiom as the
                // in-flight guard above.
                let latched = autoMergePermanentSkips[prLink.url]
                    .flatMap(AutoMergeSkipReason.init(rawValue:)) ?? .updateBranchAlreadyAttempted
                publishAutoMergeVerdict(latched, session: session, pr: pr)
                return AutoMergeOutcome(skip: "#\(pr.number):\(latched.rawValue)")
            }
            autoUpdateBranchAttempted.insert(key)
            autoMergeInFlight.insert(prLink.url)
            Task { [weak self] in await self?.attemptUpdateBranch(session: session, pr: pr, headKey: key) }
            return AutoMergeOutcome(dispatch: .updateBranch)
        }
        if pr.repoAutoMergeAllowed == false {
            // Repo forbids auto-merge, so `enableAutoMerge` can never
            // succeed — but the PR isn't green enough for a direct merge
            // *yet*. Deliberately NOT latched: labels are usually applied
            // while CI is still running, so latching here would freeze the
            // PR before it ever had a chance to qualify for the fallback,
            // which is the case #888 exists to fix. Re-evaluated every poll.
            publishAutoMergeVerdict(.repoDisallowsAutoMergePending, session: session, pr: pr)
            return AutoMergeOutcome(
                skip: "#\(pr.number):\(AutoMergeSkipReason.repoDisallowsAutoMergePending.rawValue)")
        }
        autoMergeInFlight.insert(prLink.url)
        Task { [weak self] in await self?.attemptEnableAutoMerge(session: session, pr: pr) }
        return AutoMergeOutcome(dispatch: .enable)
    }

    /// Re-evaluate auto-merge for exactly one session, right after its
    /// `crow:merge` label landed, using a targeted per-PR fetch instead of a
    /// full board poll.
    ///
    /// Replaces `await refresh()` in ``addMergeLabel(sessionID:)`` (#931). Two
    /// problems with that call, one of them a live correctness bug:
    ///
    /// - **Cost.** `refresh()` re-queries every configured GitHub / GitLab /
    ///   Jira / Corveil surface — 4-5s measured — to learn one PR's label state,
    ///   and the RPC (so the CLI, and the web client's whole `/rpc` socket)
    ///   blocked on all of it.
    /// - **Correctness.** `refresh()` opens with `guard !isRefreshing else
    ///   { return }` and `guard shouldPoll()`. A scheduled poll already in
    ///   flight, or a rate-limit suspension, makes it a silent no-op — and the
    ///   `autoMergeWarning` read below it then reports the *previous* poll's
    ///   verdict, or nothing at all on a freshly linked PR, while claiming to
    ///   have re-read. This path has no such guard: it always fetches.
    ///
    /// Deliberately does NOT touch `appState.prStatus` beyond the optimistic
    /// write the caller already made. `fetchStalePRStates` returns partial
    /// records (no reviews, no commits), so running them through
    /// `applyPRStatuses` would overwrite `previousPRStatus` with a snapshot
    /// missing the very fields the checks-failing and needs-refine edges are
    /// computed from — turning a targeted read into a source of phantom
    /// transitions. `pendingMergeLabelSessions` stays set for the same reason:
    /// it exists to survive an in-flight poll that started *before* the add
    /// (#838), and clearing it here would hand that clobber back its opening.
    func reevaluateAutoMergeAfterLabel(session: Session, prURL: String) async {
        // Empty `viewerLogin` (i.e. "don't select it") — this re-reads the
        // viewer's *own* PR to decide auto-merge, and nobody reviews their own
        // PR, so asking for `viewerLastReviewedAt` here would spend query
        // budget on a field that is structurally always nil. Only the
        // review-session path needs it.
        let providerManager = owner.providerManager
        let result = await Task.detached {
            await BoardPoller.fetchStalePRStates(
                urls: [prURL],
                viewerLogin: "",
                providerManager: providerManager
            )
        }.value
        for event in result.events {
            owner.applyGitHubBackendEvent(event)
        }
        var byURL = Dictionary(result.prs.map { ($0.url, $0) }, uniquingKeysWith: IssueTracker.mergePRRecords)

        // Read-your-write: `backend.addMergeLabel` threw on failure, so the
        // label provably IS on the PR — but the provider's read side can lag a
        // fetch issued milliseconds later. Without this union the evaluation
        // below reads "no merge label", publishes nothing, dispatches nothing,
        // and the user gets a bare success for a label the watcher won't look
        // at until the next poll: #888's exact shape. This is the watcher-side
        // analogue of the `pendingMergeLabelSessions` marker on the icon side
        // (#838).
        if let fetched = byURL[prURL], !Self.hasAutoMergeLabel(pr: fetched) {
            byURL[prURL] = IssueTracker.withLabels(
                fetched, labels: fetched.labels + [LabelInfo(name: Self.autoMergeLabel)])
        }

        guard owner.autoMergeWatcherEnabledProvider() else {
            logAutoMergeDisabledIfDue()
            publishWatcherOffVerdict(session: session, byURL: byURL)
            return
        }
        let outcome = evaluateAutoMerge(session: session, byURL: byURL)
        // Same grep-stable vocabulary as the per-poll summary, tagged so the
        // automation log distinguishes a click-driven pass from a timed one.
        CrowLog.automation(
            "auto-merge: targeted re-evaluation after add-merge-label — "
            + "pr=\(prURL) fetched=\(result.prs.count) complete=\(result.complete) "
            + "dispatch=\(outcome.dispatch.rawValue) skip=\(outcome.skip ?? "-")")
    }

    /// Record a verdict for the session's PR pill, and push a notification the
    /// first time a permanent one appears.
    ///
    /// `nil` from `state(repo:)` means "something else on screen already says
    /// this" — a conflicting PR draws the conflict chip, an unlabeled one has
    /// no 🏷 — so we clear rather than add a redundant second signal.
    /// Internal (not private) so the attempt paths in
    /// `AutoMergeController+Attempts` publish through the same code.
    func publishAutoMergeVerdict(
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
        owner.onAutoMergeBlocked?(session.id, pr.url, pr.number, state)
    }

    /// Drop a PR's notification latches so a block that gets fixed and then
    /// recurs is announced again rather than swallowed for the process
    /// lifetime. Internal (not private) so `recordAutoMergeSuccess` in
    /// `AutoMergeController+Attempts` can clear them after a merge.
    func clearAutoMergeBlockNotifications(prURL: String?) {
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
            "auto-merge: skipped entirely — owner.autoMergeWatcherEnabledProvider() is false "
            + "(config `autoMergeWatcherEnabled` off, or the provider was never wired)")
    }

    /// Why the `crow:merge` label just applied to `sessionID`'s PR won't
    /// produce a merge, or `nil` when nothing is standing in the way.
    ///
    /// The watcher toggle comes first: it's the one cause that applies to every
    /// PR at once and the one with a one-line fix, so naming it beats reporting
    /// a per-PR symptom underneath it.
    func autoMergeWarning(sessionID: UUID) -> String? {
        guard owner.autoMergeWatcherEnabledProvider() else {
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
