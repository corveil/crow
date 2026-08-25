import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

/// The auto-rebase watcher (CROW-318), extracted from `IssueTracker`
/// (CROW-1094). Rebases behind-but-clean PR branches onto their base, defers
/// when the worktree is dirty or diverged, and escalates a wedged branch to a
/// human. Owns all its per-head bookkeeping (in-flight / attempted / deferrals
/// / failure counts / up-to-date heads / stuck-notified). It reads the
/// auto-merge branch-ownership state (owner.autoMergeInFlight / owner.autoUpdateBranchAttempted
/// / shouldUpdateBranchBeforeMerge) and the shared codeBackend /
/// prHasCrowAuthoredCommit / owner.gitManager through an unowned back-reference to the
/// tracker; `applyPRStatuses` drives it each poll.
@MainActor
final class AutoRebaseController {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }
    private var providerManager: ProviderManager { owner.providerManager }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    /// Hourly rate-limit for the idle auto-rebase watcher's steady-state
    /// "nothing happened" line (review #787).
    private var lastAutoRebaseIdleLogAt: Date?

    init(owner: IssueTracker) { self.owner = owner }

    /// PR URLs with an auto-rebase attempt currently in flight. Cleared when
    /// the attempt finishes so the next poll can re-evaluate.
    /// Internal (not private) for `@testable` tests, matching
    /// ``autoReRequestInFlight``.
    var autoRebaseInFlight: Set<String> = []

    /// Per-head-commit guard for auto-rebase, keyed `"<url>\n<headRefOid>"`.
    /// One rebase attempt per head state — a successful rebase rewrites the
    /// head (new key), and a delegated conflict resolution that pushes a new
    /// head also re-arms. Transient outcomes (`.dirtyWorktree`,
    /// `.outOfSyncWithRemote`, and bounded `.failed` retries) un-set the key so
    /// a later poll retries; for the two deferrals, `autoRebaseDeferrals` then
    /// paces how much later. In-memory only.
    /// Internal (not private) so `@testable` tests can read the dispatch
    /// decision without a live backend, matching ``autoReRequestAttempted``.
    var autoRebaseAttempted: Set<String> = []

    /// Heads the git pre-check found already on base (#944).
    ///
    /// Exists because widening the candidate filter made the per-head latch
    /// dangerous: a PR probed while merely `BLOCKED`-and-not-yet-behind would
    /// burn its one attempt, and the base moving afterwards is *invisible* in
    /// `headRefOid` — so the watcher would never look again, which is worse
    /// than the bug #944 set out to fix. `applyAutoRebase` re-arms the latch
    /// from this record; see ``shouldRecheckUpToDateHead`` for when.
    /// In-memory only.
    var autoRebaseUpToDateHeads: [String: AutoRebaseUpToDateHead] = [:]

    /// A head the git pre-check cleared: what GitHub said about it at the time,
    /// and when it is due for another look.
    struct AutoRebaseUpToDateHead {
        let mergeStateStatus: String
        let recheckAt: Date
    }

    /// How long a head that the git pre-check found already on base stays
    /// latched before it is probed again.
    ///
    /// A time-based re-check is not belt-and-braces for the status-change one —
    /// it is the load-bearing half. `mergeStateStatus` is single-valued, so
    /// `BLOCKED` (a required review pending) *outranks* `BEHIND` and simply
    /// stays `BLOCKED` when the base drifts underneath. That is the whole
    /// premise of #944, which means a status-change re-arm can only fire when
    /// BLOCKED finally clears — i.e. once the PR is approved, which is exactly
    /// the serialization this ticket exists to remove. Only the clock notices
    /// pure base drift.
    ///
    /// 900s matches `autoRebaseDeferralMaxDelay` and bounds the steady-state
    /// cost to four `git fetch`es an hour per open PR with a worktree — the
    /// same local probe the pre-check already runs, and well under how long CI
    /// takes, so the detection lag never becomes the critical path.
    nonisolated static let autoRebaseUpToDateRecheckInterval: TimeInterval = 900

    /// Whether a latched up-to-date head is due for another git probe: either
    /// GitHub's view of it changed, or the re-check interval has elapsed. Pure
    /// so the policy is unit-testable without an `IssueTracker` or a clock.
    nonisolated static func shouldRecheckUpToDateHead(
        _ seen: AutoRebaseUpToDateHead, currentStatus: String, now: Date
    ) -> Bool {
        seen.mergeStateStatus != currentStatus || now >= seen.recheckAt
    }

    /// A deferred auto-rebase attempt: why it deferred, how many consecutive
    /// times this head state has deferred, and when it may be retried.
    /// Internal (not private) so `@testable` tests can assert the escalation
    /// count and the reason-change reset.
    struct AutoRebaseDeferral {
        let reason: AutoRebaseDeferReason
        let count: Int
        let retryAt: Date
    }

    /// Deferred auto-rebase attempts per head-key. A deferral un-sets the
    /// `autoRebaseAttempted` key so the head can be re-dispatched, so without
    /// this the retry cadence is "every poll, forever" — a clean-but-stale
    /// worktree re-fetched and re-logged a bare `dispatched` line every 60s
    /// with no outcome ever recorded (#889). Cleared on any non-deferral
    /// outcome. In-memory only. Internal for `@testable` tests.
    var autoRebaseDeferrals: [String: AutoRebaseDeferral] = [:]

    /// Why an auto-rebase attempt deferred rather than rebasing. Raw values are
    /// grep-stable — they are written verbatim to the automation log, like
    /// `AutoMergeSkipReason`.
    enum AutoRebaseDeferReason: String {
        case dirtyWorktree = "dirty-worktree"
        case outOfSyncAhead = "out-of-sync-ahead"
        case outOfSyncDiverged = "out-of-sync-diverged"
    }

    /// One publishable auto-rebase outcome (#944). Carries the payload a
    /// message needs — deferral count, attempt count, git's own error — which
    /// is why this is an enum with associated values rather than
    /// `AutoMergeSkipReason`'s plain `String` raw values. Reason tokens are
    /// shared with `AutoRebaseDeferReason` so the chip and the log agree.
    enum AutoRebaseVerdict {
        case deferred(AutoRebaseDeferReason, count: Int)
        case gaveUp(attempts: Int, error: String)

        /// Token identical to the one in `crowd-automation.log`. Only
        /// `.gaveUp` needs a new one.
        var reason: String {
            switch self {
            case .deferred(let reason, _): reason.rawValue
            case .gaveUp: "rebase-failed"
            }
        }

        var state: AutoRebaseState {
            switch self {
            case .deferred(let reason, let count):
                let stuck = IssueTracker.shouldEscalateDeferral(deferralCount: count)
                return AutoRebaseState(
                    phase: stuck ? .blocked : .stalled,
                    reason: reason.rawValue,
                    message: Self.message(for: reason, count: count, stuck: stuck),
                    permanent: stuck)
            case .gaveUp(let attempts, let error):
                // Git's stderr reaches the DOM only via `chip.title` and
                // `textContent`, so there's no injection vector — but an
                // unbounded one blows out both the tooltip and the
                // notification body.
                let detail = error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
                return AutoRebaseState(
                    phase: .blocked, reason: reason,
                    message: "Crow's rebase failed \(attempts) times in a row and has stopped "
                        + "trying until the branch moves. Last error: \(detail)",
                    permanent: true)
            }
        }

        private static func message(
            for reason: AutoRebaseDeferReason, count: Int, stuck: Bool
        ) -> String {
            switch (reason, stuck) {
            case (.dirtyWorktree, false):
                "Crow can't rebase this branch onto its base: the worktree has uncommitted "
                    + "changes. It will retry once the tree is clean."
            case (.dirtyWorktree, true):
                "Crow has tried to rebase this branch \(count) times and the worktree still "
                    + "has uncommitted changes. Commit or stash them — retrying won't clear it."
            case (.outOfSyncAhead, false):
                "Crow can't rebase this branch onto its base: it has local commits the remote "
                    + "doesn't, and a force-push would publish them. Push or drop them and "
                    + "Crow will retry."
            case (.outOfSyncAhead, true):
                "Crow has tried to rebase this branch \(count) times; it still has local "
                    + "commits the remote doesn't, so a force-push would publish unpushed "
                    + "work. Push or drop them yourself."
            case (.outOfSyncDiverged, false):
                "Crow can't rebase this branch onto its base: it and the remote have both "
                    + "moved, so a force-push would revert remote commits. Reconcile them and "
                    + "Crow will retry."
            case (.outOfSyncDiverged, true):
                "Crow has tried to rebase this branch \(count) times; it and the remote have "
                    + "both moved, so any force-push would revert remote commits. Reconcile "
                    + "them by hand — Crow will not."
            }
        }
    }

    /// PRs already announced as stuck, keyed `"<url>\n<reason>"`. A wedged
    /// deferral re-publishes its verdict on every poll forever, so without this
    /// the escalation is a chime every 15 minutes. Mirrors
    /// ``autoMergeBlockNotified``, including keying on the reason so a branch
    /// that moves from `ahead` to `diverged` announces itself again.
    private var autoRebaseStuckNotified: Set<String> = []

    /// Consecutive `.failed` rebase attempts per head-key, so a transient git
    /// failure (fetch flake, rejected lease, unreachable base) is retried a
    /// bounded number of times rather than either stalling forever or
    /// hot-looping on a genuinely-broken config. Cleared on any non-failure
    /// outcome. In-memory only. Internal for `@testable` tests.
    var autoRebaseFailureCounts: [String: Int] = [:]

    /// Max consecutive `.failed` auto-rebase attempts per head state before
    /// the watcher gives up until the head commit changes.
    nonisolated static let maxAutoRebaseFailureRetries = 3

    /// Backoff bounds for deferred auto-rebase attempts. The base matches one
    /// board poll so the first retry is immediate-ish; the cap keeps a
    /// permanently stuck branch to ~4 attempts an hour.
    nonisolated static let autoRebaseDeferralBaseDelay: TimeInterval = 60
    nonisolated static let autoRebaseDeferralMaxDelay: TimeInterval = 900

    /// Consecutive deferrals of the same reason before the watcher stops
    /// backing off quietly and tells a human (#944).
    ///
    /// 5 is not arbitrary: it is the first count at which
    /// `autoRebaseDeferralBackoff` saturates at `autoRebaseDeferralMaxDelay`
    /// (60 · 2⁴ = 960, capped to 900) — roughly 30 minutes and four failed
    /// retries in. Below it Crow is genuinely "waiting a bit longer"; from here
    /// on it asks the same question every 15 minutes and gets the same answer,
    /// which is exactly the state nobody found out about. A test pins it to the
    /// backoff curve so the two can't drift apart.
    nonisolated static let autoRebaseStuckDeferralThreshold = 5

    // MARK: - Auto-Rebase Watcher (CROW-318)

    /// Decide whether `pr` is worth *looking at* — a candidate filter, not an
    /// answer. Pure so unit tests can exercise it without an `IssueTracker`.
    ///
    /// This deliberately does **not** try to decide whether the branch is
    /// behind. `mergeStateStatus` is GitHub's single-valued summary of why the
    /// merge button isn't green, not a set of flags: it reports the
    /// highest-priority reason, so a PR that is behind base *and* anything else
    /// reports the other value. `BLOCKED` (required review pending) masks
    /// `BEHIND`, and so do `DIRTY`, `DRAFT` and `UNKNOWN` — which meant the
    /// watcher never saw the single most common shape, a PR drifting behind its
    /// base while it waits for a reviewer (#944). Git is the only thing that
    /// actually knows, so `attemptRebase` asks it (`GitManager.behindBase`) and
    /// a PR that needs nothing costs one `fetch` per head state.
    ///
    /// Unlike `shouldAttemptAutoMerge` there is **no label requirement**, and
    /// review state and draft-ness are irrelevant — a rebase doesn't need
    /// approval, and the operation is a rebase-onto-base + `--force-with-lease`
    /// on the session's own branch, never a merge. Three consequences worth
    /// naming, because they are decisions and not accidents:
    ///
    /// - **Drafts stay eligible**, as they have been since CROW-318. A draft's
    ///   `mergeStateStatus` is *always* `DRAFT`, so behind-ness was masked
    ///   permanently — drafts are exactly where long-lived Crow branches rot.
    ///   They remain excluded from auto-*merge* by `shouldAttemptAutoMerge`'s
    ///   own draft guard, so nothing here can merge one.
    /// - **Every open GitLab MR becomes a candidate.** `PRRecord`'s
    ///   `mergeStateStatus` defaults to `"UNKNOWN"` and `GitLabCodeBackend`
    ///   never populates it. MRs do fall behind and nothing else handles them,
    ///   so this is wanted — and it is bounded to one probe per head.
    /// - **`UNKNOWN` costs one probe per push** while GitHub recomputes
    ///   mergeability. That is the price of no longer being permanently blind
    ///   to a mid-recompute PR.
    ///
    /// Crow-authorship and per-head loop-safety are enforced by the caller.
    nonisolated static func shouldAttemptAutoRebase(pr: ViewerPR) -> Bool {
        guard pr.state == "OPEN" else { return false }
        // The `CONFLICTING` disjunct is subsumed by `!= CLEAN` (a PR cannot be
        // both), but kept: it costs nothing and survives a provider that
        // populates one field and not the other.
        return pr.mergeStateStatus != "CLEAN" || pr.mergeable == "CONFLICTING"
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
    func applyAutoRebase(viewerPRs: [ViewerPR]) {
        guard owner.autoRebaseAndResolveConflictsProvider() else {
            // Turning the watcher off must not leave verdicts behind — but do
            // this before the non-empty guard below, so a *failed poll* can't
            // masquerade as a toggle-off and wipe live chips.
            appState.autoRebaseState.removeAll()
            autoRebaseStuckNotified.removeAll()
            return
        }
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: IssueTracker.mergePRRecords)

        // Drop per-head bookkeeping for heads no longer in the poll, so these
        // maps don't grow for the lifetime of the daemon. Guarded by the
        // non-empty check above so a failed/empty poll can't wipe live state;
        // a PR that briefly drops out and returns just gets re-dispatched once.
        let liveHeadKeys = Set(viewerPRs.map { "\($0.url)\n\($0.headRefOid)" })
        autoRebaseAttempted.formIntersection(liveHeadKeys)
        autoRebaseFailureCounts = autoRebaseFailureCounts.filter { liveHeadKeys.contains($0.key) }
        autoRebaseDeferrals = autoRebaseDeferrals.filter { liveHeadKeys.contains($0.key) }
        autoRebaseUpToDateHeads = autoRebaseUpToDateHeads.filter { liveHeadKeys.contains($0.key) }

        let now = Date()
        var dispatched = 0
        for session in appState.sessions where Self.sessionEligibleForAutoRebase(session) {
            guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else { continue }
            guard !autoRebaseInFlight.contains(prLink.url) else { continue }
            guard let pr = byURL[prLink.url] else { continue }
            guard Self.shouldAttemptAutoRebase(pr: pr) else {
                // The PR stopped being a candidate — hand-rebased, merged, or
                // closed. This is the *only* recovery path (`attemptRebase`
                // never runs again for a non-candidate), so without the clear a
                // `blocked` chip would outlive its cause forever.
                publishAutoRebaseVerdict(nil, session: session, pr: pr)
                continue
            }

            let key = "\(prLink.url)\n\(pr.headRefOid)"

            // Precedence: when auto-merge is also enabled and this PR is a
            // crow:merge BEHIND candidate, let auto-merge's `gh pr update-branch`
            // own bringing it up to date so the two watchers don't fight over
            // the same branch.
            //
            // Yield only while auto-merge *can still act* — actively trying
            // (`owner.autoMergeInFlight`) or not yet out of attempts. Before #944
            // this yielded unconditionally, so once auto-merge burned its
            // one-shot `owner.autoUpdateBranchAttempted` key and gave up, nobody
            // fixed the branch at all. The in-flight disjunct is load-bearing:
            // `owner.autoUpdateBranchAttempted.insert` happens *before* the async
            // attempt and `applyAutoMerge` runs immediately before this in the
            // same poll, so `!contains` alone is already false in the very poll
            // auto-merge dispatched.
            if owner.autoMergeWatcherEnabledProvider(),
               IssueTracker.shouldUpdateBranchBeforeMerge(pr: pr, session: session),
               owner.autoMergeInFlight.contains(prLink.url) || !owner.autoUpdateBranchAttempted.contains(key) {
                // One piece of work, one chip: auto-merge owns this branch's
                // verdict while it's the one acting on it.
                publishAutoRebaseVerdict(nil, session: session, pr: pr)
                continue
            }

            // A head we latched as "already on base" is probed again once
            // GitHub's view of it changes OR the re-check interval elapses.
            // The clock is the important one: the base moving is invisible in
            // both `headRefOid` and `mergeStateStatus` (BLOCKED outranks
            // BEHIND and stays BLOCKED), so without it a PR first seen
            // up-to-date-but-BLOCKED would wait for approval before anyone
            // looked again — the exact serialization #944 removes. Both gates
            // keep the cost bounded, so a persistent git/GitHub disagreement
            // re-probes on the interval rather than every poll.
            if let seen = autoRebaseUpToDateHeads[key],
               Self.shouldRecheckUpToDateHead(seen, currentStatus: pr.mergeStateStatus, now: now) {
                autoRebaseUpToDateHeads[key] = AutoRebaseUpToDateHead(
                    mergeStateStatus: pr.mergeStateStatus,
                    recheckAt: now.addingTimeInterval(Self.autoRebaseUpToDateRecheckInterval))
                autoRebaseAttempted.remove(key)
            }

            // A deferral re-arms `autoRebaseAttempted`, so the backoff window is
            // what actually paces retries for a head that keeps deferring.
            if let deferral = autoRebaseDeferrals[key], now < deferral.retryAt { continue }
            guard !autoRebaseAttempted.contains(key) else { continue }
            autoRebaseAttempted.insert(key)
            autoRebaseInFlight.insert(prLink.url)
            dispatched += 1
            CrowLog.automation("auto-rebase: dispatched #\(pr.number) (\(pr.mergeStateStatus), mergeable=\(pr.mergeable))")
            let capturedSession = session
            Task { [weak self] in await self?.attemptRebase(session: capturedSession, pr: pr) }
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

    /// Whether a deferral that has recurred this many times should escalate
    /// from `.stalled` to `.blocked` and notify. Pure so the policy is
    /// unit-testable without an `IssueTracker`, matching
    /// `shouldRetryFailedRebase`.
    ///
    /// Escalating is **not** giving up: past the threshold the deferral keeps
    /// retrying at the backoff cap, so whatever a human does to unwedge the
    /// branch is picked up on the next cycle with nothing to re-arm. Do not
    /// "fix" this into a give-up — the whole point is that #944's dead-end was
    /// silent, not that it was persistent.
    nonisolated static func shouldEscalateDeferral(deferralCount: Int) -> Bool {
        deferralCount >= autoRebaseStuckDeferralThreshold
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

        // Ask git whether there is anything to do, before spending a provider
        // API call finding out who authored the PR. `shouldAttemptAutoRebase`
        // is only a candidate filter now (#944) — GitHub's `mergeStateStatus`
        // masks behind-ness behind BLOCKED/DIRTY/DRAFT/UNKNOWN — so this probe
        // is what keeps the widened candidate set from multiplying backend
        // calls. It is the same "cheap local checks first" rule as above.
        switch await owner.gitManager.behindBase(
            worktreePath: primary.worktreePath,
            branch: primary.branch,
            baseBranch: pr.baseRefName
        ) {
        case .upToDate:
            recordRebaseNoOp(headKey: headKey, session: session, pr: pr, source: "pre-check")
            return
        case .unknown(let msg):
            // Fall through on purpose: `rebaseOntoBase` re-runs the same
            // commands and will report a real `.failed`, which feeds the
            // bounded-retry counter. Incrementing it here too would count one
            // underlying failure twice per attempt.
            CrowLog.automation(
                "auto-rebase: #\(pr.number) behind-check inconclusive, attempting anyway: \(msg)")
        case .behind(let count):
            CrowLog.automation(
                "auto-rebase: #\(pr.number) behind base by \(count) "
                + "(github: \(pr.mergeStateStatus)/\(pr.mergeable))")
        }

        guard let backend = owner.codeBackend(for: session) else {
            CrowLog.automation("auto-rebase: #\(pr.number) skipped:no-backend")
            return
        }
        guard await owner.prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            CrowLog.automation("auto-rebase: #\(pr.number) skipped:no-crow-session-trailer")
            return
        }

        let outcome = await owner.gitManager.rebaseOntoBase(
            worktreePath: primary.worktreePath,
            branch: primary.branch,
            baseBranch: pr.baseRefName
        )
        switch outcome {
        case .rebasedAndPushed:
            autoRebaseFailureCounts[headKey] = nil
            autoRebaseDeferrals[headKey] = nil
            publishAutoRebaseVerdict(nil, session: session, pr: pr)
            let priorState = pr.mergeable == "CONFLICTING" ? "CONFLICTING" : "BEHIND"
            CrowLog.automation(
                "auto-rebase: #\(pr.number) rebased & force-pushed (was \(priorState), session \(session.id))")
            owner.onAutoRebasePushed?(session.id, pr.url, pr.number)
        case .alreadyUpToDate:
            // The base moved, or somebody pushed a rebase, between the
            // pre-check above and `rebaseOntoBase`'s own fetch. Same answer,
            // same bookkeeping — and crucially not `.rebasedAndPushed`, which
            // would announce a rebase that never happened.
            recordRebaseNoOp(headKey: headKey, session: session, pr: pr, source: "post-fetch")
        case .conflicts:
            autoRebaseFailureCounts[headKey] = nil
            autoRebaseDeferrals[headKey] = nil
            // No chip: the conflict is already on screen three ways (the PR
            // pill's conflict glyph, the activity badge once the agent picks
            // it up, and the Rebase & Fix Conflicts button).
            publishAutoRebaseVerdict(nil, session: session, pr: pr)
            CrowLog.automation(
                "auto-rebase: #\(pr.number) conflicts — delegating to agent (session \(session.id))")
            owner.onAutoRebaseConflicts?(session.id, pr.url, pr.number)
        case .dirtyWorktree:
            // Transient (a Claude session is mid-edit). Re-arm so a later poll
            // retries once the tree is clean.
            deferRebase(headKey: headKey, reason: .dirtyWorktree, session: session, pr: pr)
        case .outOfSyncWithRemote(let divergence):
            // Transient: local has unpushed commits, or local and origin have
            // both moved. Either way a force-push would destroy work, so wait
            // for a human to reconcile and retry on a later poll. (A branch
            // that is merely behind is fast-forwarded by `rebaseOntoBase` and
            // never lands here — that was the #889 hot loop.)
            deferRebase(
                headKey: headKey,
                reason: divergence == .ahead ? .outOfSyncAhead : .outOfSyncDiverged,
                session: session,
                pr: pr)
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
            // Stay quiet while retries remain — one flaky fetch is not news.
            publishAutoRebaseVerdict(
                willRetry ? nil : .gaveUp(attempts: failures, error: msg),
                session: session, pr: pr)
            CrowLog.automation(
                "auto-rebase: #\(pr.number) failed (attempt \(failures)/"
                + "\(Self.maxAutoRebaseFailureRetries), "
                + "\(willRetry ? "will retry" : "giving up until head changes")): \(msg)")
        }
    }

    /// A rebase attempt that provably had nothing to do. Never fires
    /// `onAutoRebasePushed` — announcing a rebase that didn't happen is exactly
    /// what `RebaseOutcome.alreadyUpToDate` exists to prevent (#944).
    ///
    /// The per-head `autoRebaseAttempted` key deliberately stays **set**: one
    /// check per head state is the whole point of the pre-check, and it is what
    /// bounds the widened candidate filter to one `git fetch` per head rather
    /// than one per poll. `autoRebaseUpToDateHeads` then lets `applyAutoRebase`
    /// re-arm it if GitHub's view of that same head later changes.
    private func recordRebaseNoOp(
        headKey: String, session: Session, pr: ViewerPR, source: String
    ) {
        autoRebaseFailureCounts[headKey] = nil
        autoRebaseDeferrals[headKey] = nil
        autoRebaseUpToDateHeads[headKey] = AutoRebaseUpToDateHead(
            mergeStateStatus: pr.mergeStateStatus,
            recheckAt: Date().addingTimeInterval(Self.autoRebaseUpToDateRecheckInterval))
        publishAutoRebaseVerdict(nil, session: session, pr: pr)
        // A CONFLICTING PR with a zero behind-count is definitionally stale
        // data — you cannot conflict with an ancestor. Say so, rather than
        // logging a bare no-op: this is the line someone greps when a PR shows
        // a conflict chip that no rebase will ever clear.
        let note = pr.mergeable == "CONFLICTING"
            ? " — github reports mergeable=CONFLICTING, which is stale"
            : ""
        CrowLog.automation(
            "auto-rebase: #\(pr.number) no-op:already-on-base (\(source), "
            + "github: \(pr.mergeStateStatus)/\(pr.mergeable))\(note)")
    }

    /// Record a deferred auto-rebase attempt: re-arm the per-head key so it can
    /// be dispatched again, but stamp a backoff deadline so a head that keeps
    /// deferring doesn't re-fetch every poll forever (#889). A *different*
    /// reason than last time restarts the backoff — the branch moved to a new
    /// situation, which deserves a prompt retry rather than the previous
    /// reason's accumulated delay.
    ///
    /// Past `autoRebaseStuckDeferralThreshold` the verdict escalates from
    /// `.stalled` to `.blocked` and fires `onAutoRebaseStuck`. That is a
    /// notification, **not** a give-up: the deferral keeps retrying at the
    /// backoff cap, so a human fix is picked up on the next cycle with nothing
    /// to re-arm. Before #944 this state simply backed off forever in silence.
    private func deferRebase(
        headKey: String, reason: AutoRebaseDeferReason, session: Session, pr: ViewerPR
    ) {
        autoRebaseFailureCounts[headKey] = nil
        autoRebaseAttempted.remove(headKey)
        let count = autoRebaseDeferrals[headKey].map { $0.reason == reason ? $0.count + 1 : 1 } ?? 1
        let delay = Self.autoRebaseDeferralBackoff(deferralCount: count)
        autoRebaseDeferrals[headKey] = AutoRebaseDeferral(
            reason: reason, count: count, retryAt: Date().addingTimeInterval(delay))
        publishAutoRebaseVerdict(.deferred(reason, count: count), session: session, pr: pr)
        CrowLog.automation(
            "auto-rebase: #\(pr.number) deferred:\(reason.rawValue) "
            + "(deferral \(count), retry in \(Int(delay))s"
            + "\(Self.shouldEscalateDeferral(deferralCount: count) ? ", escalated" : "")")
    }

    /// Publish what the auto-rebase watcher concluded about this session's
    /// branch, and notify the first time a permanent verdict appears. `nil`
    /// clears. The auto-rebase twin of `publishAutoMergeVerdict`, and it
    /// co-locates publish / clear / notify-once for the same reason: no call
    /// site can then do three of the four.
    ///
    /// Unlike auto-merge, silence really is the default — nothing opts a PR
    /// into auto-rebase, so a published state only ever means "Crow tried and
    /// couldn't".
    private func publishAutoRebaseVerdict(
        _ verdict: AutoRebaseVerdict?, session: Session, pr: ViewerPR?
    ) {
        guard let verdict else {
            appState.autoRebaseState.removeValue(forKey: session.id)
            clearAutoRebaseStuckNotifications(prURL: pr?.url)
            return
        }
        let state = verdict.state
        appState.autoRebaseState[session.id] = state
        guard state.phase == .blocked, let pr else {
            if state.phase != .blocked { clearAutoRebaseStuckNotifications(prURL: pr?.url) }
            return
        }
        // Keyed with the reason, like `autoMergeBlockNotified`: a branch that
        // moves from `ahead` to `diverged` is a genuinely new situation for a
        // human to look at, and deserves to be announced again.
        let key = "\(pr.url)\n\(state.reason)"
        guard autoRebaseStuckNotified.insert(key).inserted else { return }
        owner.onAutoRebaseStuck?(session.id, pr.url, pr.number, state)
    }

    /// Drop the notify-once latch for every reason on `prURL`, so a branch that
    /// un-wedges and later re-wedges announces itself again.
    private func clearAutoRebaseStuckNotifications(prURL: String?) {
        guard let prURL else { return }
        autoRebaseStuckNotified = autoRebaseStuckNotified.filter { !$0.hasPrefix("\(prURL)\n") }
    }
}

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` / `tracker.<member>` spelling used by
// the tests and by AutoReReviewController (shouldAttemptAutoRebase). All logic
// and state live on `AutoRebaseController`.
extension IssueTracker {
    typealias AutoRebaseVerdict = AutoRebaseController.AutoRebaseVerdict
    typealias AutoRebaseDeferReason = AutoRebaseController.AutoRebaseDeferReason
    typealias AutoRebaseUpToDateHead = AutoRebaseController.AutoRebaseUpToDateHead

    nonisolated static func shouldAttemptAutoRebase(pr: ViewerPR) -> Bool {
        AutoRebaseController.shouldAttemptAutoRebase(pr: pr)
    }
    nonisolated static func sessionEligibleForAutoRebase(_ session: Session) -> Bool {
        AutoRebaseController.sessionEligibleForAutoRebase(session)
    }
    nonisolated static func shouldRetryFailedRebase(failureCount: Int) -> Bool {
        AutoRebaseController.shouldRetryFailedRebase(failureCount: failureCount)
    }
    nonisolated static func shouldEscalateDeferral(deferralCount: Int) -> Bool {
        AutoRebaseController.shouldEscalateDeferral(deferralCount: deferralCount)
    }
    nonisolated static func autoRebaseDeferralBackoff(deferralCount: Int) -> TimeInterval {
        AutoRebaseController.autoRebaseDeferralBackoff(deferralCount: deferralCount)
    }
    nonisolated static func shouldRecheckUpToDateHead(
        _ seen: AutoRebaseUpToDateHead, currentStatus: String, now: Date
    ) -> Bool {
        AutoRebaseController.shouldRecheckUpToDateHead(seen, currentStatus: currentStatus, now: now)
    }

    nonisolated static var maxAutoRebaseFailureRetries: Int { AutoRebaseController.maxAutoRebaseFailureRetries }
    nonisolated static var autoRebaseDeferralBaseDelay: TimeInterval { AutoRebaseController.autoRebaseDeferralBaseDelay }
    nonisolated static var autoRebaseDeferralMaxDelay: TimeInterval { AutoRebaseController.autoRebaseDeferralMaxDelay }
    nonisolated static var autoRebaseStuckDeferralThreshold: Int { AutoRebaseController.autoRebaseStuckDeferralThreshold }
    nonisolated static var autoRebaseUpToDateRecheckInterval: TimeInterval { AutoRebaseController.autoRebaseUpToDateRecheckInterval }

    var autoRebaseInFlight: Set<String> {
        get { autoRebase.autoRebaseInFlight } set { autoRebase.autoRebaseInFlight = newValue }
    }
    var autoRebaseAttempted: Set<String> {
        get { autoRebase.autoRebaseAttempted } set { autoRebase.autoRebaseAttempted = newValue }
    }
    var autoRebaseUpToDateHeads: [String: AutoRebaseUpToDateHead] {
        get { autoRebase.autoRebaseUpToDateHeads } set { autoRebase.autoRebaseUpToDateHeads = newValue }
    }
    var autoRebaseDeferrals: [String: AutoRebaseController.AutoRebaseDeferral] {
        get { autoRebase.autoRebaseDeferrals } set { autoRebase.autoRebaseDeferrals = newValue }
    }
    var autoRebaseFailureCounts: [String: Int] {
        get { autoRebase.autoRebaseFailureCounts } set { autoRebase.autoRebaseFailureCounts = newValue }
    }
}
