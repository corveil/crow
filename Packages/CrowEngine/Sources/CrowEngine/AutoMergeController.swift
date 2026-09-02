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
/// `codeBackend` / `prHasCrowAuthoredCommit` helpers live here now and are
/// re-exposed on the tracker for the rebase / re-review watchers.
@MainActor
final class AutoMergeController {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }
    private var providerManager: ProviderManager { owner.providerManager }
    private var store: JSONStore { owner.store }

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

    /// Max consecutive failed `gh pr update-branch` calls per head state before
    /// the watcher gives up until the head commit changes.
    nonisolated static let maxAutoUpdateBranchFailureRetries = 3

    /// Whether a failed `updateBranch` should be retried on the next poll.
    /// Pure so the policy is unit-testable, matching `shouldRetryFailedRebase`.
    nonisolated static func shouldRetryFailedUpdateBranch(failureCount: Int) -> Bool {
        failureCount < maxAutoUpdateBranchFailureRetries
    }

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
    /// *throws* on the real `gh pr edit --add-label` failure.
    private var ensuredMergeLabelRepos: Set<String> = []

    /// In-flight `ensureMergeLabel` calls, same key as
    /// ``ensuredMergeLabelRepos``. Without this, the first poll that dispatches
    /// N PRs in one repo fires N concurrent identical shell-outs before any of
    /// them can populate the memo — which would only take effect from the
    /// *second* poll onward.
    private var ensureMergeLabelTasks: [String: Task<Void, Error>] = [:]

    // MARK: - Watcher
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
            for uuid in IssueTracker.extractCrowSessionUUIDs(from: message) {
                if knownSessionIDs.contains(uuid) { return true }
            }
        }
        return false
    }


    /// What one session's auto-merge evaluation did. Returned by
    /// ``evaluateAutoMerge(session:byURL:)`` so the per-poll caller can keep its
    /// aggregate summary line without the loop body reaching into the caller's
    /// counters — the single-session caller has no counters at all.
    struct AutoMergeOutcome {
        enum Dispatch: String { case none, enable, updateBranch, directMerge }
        var dispatch: Dispatch = .none
        /// Pre-formatted `<key>:<reason>` token for the per-poll summary line.
        /// `nil` when the session was never a candidate (no `.pr` link) — that
        /// is not a skip, it's a session the watcher doesn't speak about.
        var skip: String?
    }

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
        owner.onAutoMergeBlocked?(session.id, pr.url, pr.number, state)
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
            "auto-merge: skipped entirely — owner.autoMergeWatcherEnabledProvider() is false "
            + "(config `autoMergeWatcherEnabled` off, or the provider was never wired)")
    }

    /// Resolve the `CodeBackend` for a session's PR/merge actions, following the
    /// `codeProvider ?? provider ?? .github` convention (ADR 0005) so a
    /// Jira/Corveil-tasked GitHub-code session routes to GitHub rather than its
    /// task provider (CROW-532). `nil` only for a task-only resolution with no
    /// code surface — callers must bow out.
    func codeBackend(for session: Session) -> CodeBackend? {
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
        owner.onAutoMergeEnabled?(session.id, pr.url, pr.number)
    }

    /// Bring a `BEHIND` PR up to date by merging the latest base into its
    /// branch (`gh pr update-branch`, i.e. the GitHub "Update branch" button),
    /// then bow out — the merge itself happens on a later poll once GitHub has
    /// recomputed mergeability and checks have re-run. Deliberately does NOT
    /// persist `Session.autoMergeEnabledAt`: an update must not burn the
    /// one-shot merge guard. The same Crow-authorship check as the merge path
    /// applies.
    ///
    /// Every return path clears `autoMergeInFlight` (#944). Two of them used to
    /// sit *above* the `defer`, so a PR with no code backend or no Crow trailer
    /// was latched for the lifetime of the process — and because nothing
    /// recorded a reason, `evaluateAutoMerge`'s in-flight guard reported the
    /// bare `.inFlight` verdict, i.e. the UI claimed Crow was working on the PR
    /// right then. Forever. Suppression is `autoUpdateBranchAttempted`'s job,
    /// not the in-flight marker's: it returns before any dispatch, so clearing
    /// here costs no extra backend calls.
    /// Internal (not private) so `@testable` tests can drive the two early
    /// returns directly and assert they don't latch.
    func attemptUpdateBranch(session: Session, pr: ViewerPR, headKey: String) async {
        defer { autoMergeInFlight.remove(pr.url) }

        guard let backend = codeBackend(for: session) else {
            // Was a bare `return` — invisible in the log as well as latched.
            CrowLog.automation("auto-merge: #\(pr.number) update-branch skipped:no-code-backend")
            return
        }
        guard await prHasCrowAuthoredCommit(pr: pr, backend: backend) else {
            // Authorship can't change without a new commit, and a new commit
            // means a new head key — so record the reason rather than letting
            // the per-head guard report the vaguer
            // `update-branch-already-attempted`.
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.noCrowSessionTrailer.rawValue
            publishAutoMergeVerdict(.noCrowSessionTrailer, session: session, pr: pr)
            CrowLog.automation(
                "auto-merge: #\(pr.number) update-branch skipped — no Crow-Session trailer matching a known session")
            return
        }
        guard backend.capabilities.contains(.updateBranch) else {
            // Capability sets are static, so this is permanent for the backend.
            autoMergePermanentSkips[pr.url] = AutoMergeSkipReason.backendLacksAutoMerge.rawValue
            publishAutoMergeVerdict(.backendLacksAutoMerge, session: session, pr: pr)
            CrowLog.automation("auto-merge: #\(pr.number) update-branch skipped — backend lacks the updateBranch capability")
            return
        }
        do {
            try await backend.updateBranch(prURL: pr.url)
            autoUpdateBranchFailureCounts[headKey] = nil
            CrowLog.automation(
                "auto-merge: #\(pr.number) branch updated from base (session \(session.id.uuidString), was BEHIND)")
        } catch {
            // A *failed* update leaves `headRefOid` unchanged, so the per-head
            // guard's "retry once the branch moves" is a deadlock: the branch
            // is precisely what didn't move. Retry a bounded number of times
            // instead, mirroring `attemptRebase`'s `.failed` branch.
            let failures = (autoUpdateBranchFailureCounts[headKey] ?? 0) + 1
            autoUpdateBranchFailureCounts[headKey] = failures
            let willRetry = Self.shouldRetryFailedUpdateBranch(failureCount: failures)
            if willRetry { autoUpdateBranchAttempted.remove(headKey) }
            CrowLog.automation(
                "auto-merge: #\(pr.number) updateBranch failed (attempt \(failures)/"
                + "\(Self.maxAutoUpdateBranchFailureRetries), "
                + "\(willRetry ? "will retry" : "giving up until head changes")): "
                + "\(error.localizedDescription.prefix(200))")
        }
    }

    /// Fetch the PR's commits and return true iff at least one carries a
    /// `Crow-Session: <uuid>` trailer matching a known session.
    func prHasCrowAuthoredCommit(pr: ViewerPR, backend: CodeBackend) async -> Bool {
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
        owner.attribution.recordPRAttribution(pr: pr, commits: commits)
        let knownIDs = Set(appState.sessions.map(\.id))
        return Self.crowAuthored(commitMessages: commits.map(\.message), knownSessionIDs: knownIDs)
    }

    /// Memo key for ``ensuredMergeLabelRepos`` / ``ensureMergeLabelTasks``.
    private static func mergeLabelMemoKey(provider: Provider, repo: String) -> String {
        "\(provider.rawValue)\n\(repo)"
    }

    /// Ensure the `crow:merge` label exists in `repo`, at most once per
    /// (provider, repo) per process (#931).
    ///
    /// **Throws exactly what the backend throws.** The memo is a latency
    /// optimization, not a policy change: `addMergeLabel` calls this directly
    /// and must keep reporting a real label-creation failure (CROW-816), so the
    /// throwing form is the primitive and the watcher's best-effort behaviour
    /// is a `do`/`catch` on top of it — not the other way round.
    func ensureMergeLabelOnce(repo: String, backend: CodeBackend) async throws {
        guard !repo.isEmpty else { return }
        guard backend.capabilities.contains(.autoMergeLabel) else { return }
        let key = Self.mergeLabelMemoKey(provider: backend.provider, repo: repo)
        if ensuredMergeLabelRepos.contains(key) { return }
        if let inFlight = ensureMergeLabelTasks[key] {
            // Join the existing call rather than issuing a duplicate. Awaiting
            // `.value` rethrows its error, so a joiner sees the same outcome an
            // originator would; the originator owns the map cleanup.
            try await inFlight.value
            return
        }
        let task = Task { @MainActor in try await backend.ensureMergeLabel(repo: repo) }
        ensureMergeLabelTasks[key] = task
        defer { ensureMergeLabelTasks[key] = nil }
        try await task.value
        // Reached only on success — see `ensuredMergeLabelRepos`.
        ensuredMergeLabelRepos.insert(key)
    }

    /// Best-effort: ensure the `crow:merge` label exists in the repo so
    /// repo owners don't need to pre-create it. The backend swallows the
    /// "already exists" failure; this swallows the rest, because the auto-merge
    /// watcher's next step (`enableAutoMerge`) reports its own failures and a
    /// missing label is not on its own a reason to abandon the attempt.
    private func ensureMergeLabel(repo: String, backend: CodeBackend) async {
        do {
            try await ensureMergeLabelOnce(repo: repo, backend: backend)
        } catch {
            // Best-effort — swallow.
        }
    }



    /// Pure projection of a provider PR record onto the UI-facing `PRStatus`.
    /// `nonisolated static` (like `shouldAttemptAutoMerge`) because it touches
    /// no tracker state — which also makes it directly unit-testable.

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

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` / `tracker.<member>` spelling used by
// the tests, by addMergeLabel, and by the rebase / re-review watchers
// (owner.codeBackend / owner.prHasCrowAuthoredCommit). All logic and state live
// on `AutoMergeController`.
extension IssueTracker {
    typealias AutoMergeSkipReason = AutoMergeController.AutoMergeSkipReason
    typealias AutoMergeOutcome = AutoMergeController.AutoMergeOutcome

    nonisolated static func shouldAttemptAutoMerge(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.shouldAttemptAutoMerge(pr: pr, session: session)
    }
    nonisolated static func autoMergeSkipReason(pr: ViewerPR, session: Session) -> AutoMergeSkipReason? {
        AutoMergeController.autoMergeSkipReason(pr: pr, session: session)
    }
    nonisolated static func hasAutoMergeLabel(pr: ViewerPR) -> Bool {
        AutoMergeController.hasAutoMergeLabel(pr: pr)
    }
    nonisolated static func isPermanentAutoMergeFailure(_ error: Error) -> Bool {
        AutoMergeController.isPermanentAutoMergeFailure(error)
    }
    nonisolated static func directMergeGatesPass(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.directMergeGatesPass(pr: pr, session: session)
    }
    nonisolated static func shouldDirectMerge(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.shouldDirectMerge(pr: pr, session: session)
    }
    nonisolated static func shouldUpdateBranchBeforeMerge(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.shouldUpdateBranchBeforeMerge(pr: pr, session: session)
    }
    nonisolated static func crowAuthored(commitMessages: [String], knownSessionIDs: Set<UUID>) -> Bool {
        AutoMergeController.crowAuthored(commitMessages: commitMessages, knownSessionIDs: knownSessionIDs)
    }
    nonisolated static func shouldRetryFailedUpdateBranch(failureCount: Int) -> Bool {
        AutoMergeController.shouldRetryFailedUpdateBranch(failureCount: failureCount)
    }
    nonisolated static var maxAutoUpdateBranchFailureRetries: Int {
        AutoMergeController.maxAutoUpdateBranchFailureRetries
    }

    // Shared merge helpers (also used by the rebase / re-review watchers).
    func codeBackend(for session: Session) -> CodeBackend? { autoMerge.codeBackend(for: session) }
    func prHasCrowAuthoredCommit(pr: ViewerPR, backend: CodeBackend) async -> Bool {
        await autoMerge.prHasCrowAuthoredCommit(pr: pr, backend: backend)
    }

    // Instance entry points exercised directly by tests / addMergeLabel.
    func evaluateAutoMerge(session: Session, byURL: [String: ViewerPR]) -> AutoMergeOutcome {
        autoMerge.evaluateAutoMerge(session: session, byURL: byURL)
    }
    func publishWatcherOffVerdict(session: Session, byURL: [String: ViewerPR]) {
        autoMerge.publishWatcherOffVerdict(session: session, byURL: byURL)
    }
    func attemptUpdateBranch(session: Session, pr: ViewerPR, headKey: String) async {
        await autoMerge.attemptUpdateBranch(session: session, pr: pr, headKey: headKey)
    }
    func autoMergeWarning(sessionID: UUID) -> String? { autoMerge.autoMergeWarning(sessionID: sessionID) }

    nonisolated static var autoMergeLabel: String { AutoMergeController.autoMergeLabel }

    var autoMergeInFlight: Set<String> {
        get { autoMerge.autoMergeInFlight } set { autoMerge.autoMergeInFlight = newValue }
    }
    var autoUpdateBranchAttempted: Set<String> {
        get { autoMerge.autoUpdateBranchAttempted } set { autoMerge.autoUpdateBranchAttempted = newValue }
    }
    var autoUpdateBranchFailureCounts: [String: Int] {
        get { autoMerge.autoUpdateBranchFailureCounts } set { autoMerge.autoUpdateBranchFailureCounts = newValue }
    }
}
