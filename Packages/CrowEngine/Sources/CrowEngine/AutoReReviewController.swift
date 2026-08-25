import Foundation
import CrowCore
import CrowProvider

/// The auto-re-request-review watcher (CROW-921), extracted from `IssueTracker`
/// (CROW-1094). When a changes-requested PR's fix has landed and the agent has
/// settled, it re-requests the reviewer once per (head, round). Owns its own
/// in-flight / attempted / failure-count bookkeeping; reaches the shared
/// `codeBackend`, steady-state logger, agent-settled check, the
/// `autoReRequestReview` toggle, `appState`, and `providerManager` through an
/// unowned back-reference. `applyPRStatuses` drives it each poll.
@MainActor
final class AutoReReviewController {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }
    private var providerManager: ProviderManager { owner.providerManager }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    /// PR URLs with an auto-re-request-review call in flight (CROW-921).
    /// Cleared in the attempt's `defer`. Internal so `@testable` tests can read
    /// the dispatch decision without a live backend.
    var autoReRequestInFlight: Set<String> = []

    /// One re-request per (PR head, review round), keyed
    /// `"<url>\n<headRefOid>\n<lastChangesRequestedAt>"`. Belt-and-braces over
    /// the self-limiting watcher; internal for `@testable` tests.
    var autoReRequestAttempted: Set<String> = []

    /// Consecutive failed re-request attempts per round key. Bounds the retry
    /// loop; cleared on success and pruned with `autoReRequestAttempted`.
    var autoReReviewFailureCounts: [String: Int] = [:]

    /// Hourly clock for the "enabled, nothing to do" line, so a healthy steady
    /// state doesn't fill `crowd-automation.log`.
    private var lastAutoReReviewIdleLogAt: Date?

    init(owner: IssueTracker) { self.owner = owner }

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
    func applyAutoReRequestReview(viewerPRs: [ViewerPR]) {
        guard owner.autoReRequestReviewProvider() else { return }
        guard !viewerPRs.isEmpty else { return }
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: IssueTracker.mergePRRecords)

        // Prune the per-round guard against what this poll actually saw, so a
        // new push or a new reviewer submission re-arms the watcher. Guarded
        // by the non-empty check above: a failed fetch must not wipe live
        // state and let a second request fire.
        let liveRoundKeys = Set(viewerPRs.map {
            Self.autoReReviewRoundKey(url: $0.url, headRefOid: $0.headRefOid, lastChangesRequestedAt: $0.lastChangesRequestedAt)
        })
        autoReRequestAttempted.formIntersection(liveRoundKeys)
        autoReReviewFailureCounts = autoReReviewFailureCounts.filter { liveRoundKeys.contains($0.key) }

        let now = Date()
        var dispatched = 0
        for session in appState.sessions where Self.sessionEligibleForAutoReReview(session) {
            guard let prLink = appState.links(for: session.id).first(where: { $0.linkType == .pr }) else { continue }
            guard !autoReRequestInFlight.contains(prLink.url) else { continue }
            guard let pr = byURL[prLink.url] else { continue }

            let status = IssueTracker.buildPRStatus(from: pr)
            let skip = Self.autoReReviewSkipReason(
                pr: pr,
                status: status,
                isReviewSession: session.kind == .review,
                agentSettled: owner.agentSettled(sessionID: session.id)
            )
            if let skip {
                // Only the states a reader would wonder about get a line —
                // `.notAwaitingReRequest` is the overwhelming majority of
                // healthy PRs and is already covered by the needs-refine
                // gated log. The rest go through the shared rate limiter: a
                // PR parked on `.agentBusy` or `.noReviewers` would otherwise
                // emit a line every 60s poll for as long as it stayed there.
                if skip != .notAwaitingReRequest {
                    owner.logSteadyState(
                        channel: IssueTracker.autoReReviewLogChannel,
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
            let capturedSession = session
            Task { [weak self] in await self?.attemptReRequestReview(session: capturedSession, pr: pr, roundKey: roundKey) }
        }
        if dispatched == 0 {
            if lastAutoReReviewIdleLogAt.map({ now.timeIntervalSince($0) >= IssueTracker.steadyStateLogHeartbeat }) ?? true {
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
        "\(url)\n\(headRefOid)\n\(IssueTracker.iso(lastChangesRequestedAt))"
    }

    /// Give up on a round after this many failed attempts. The inputs to a
    /// re-request are fixed for the life of a round — same PR, same logins —
    /// so a failure that isn't transient will never stop being a failure.
    /// Retrying forever would re-dispatch every 60s poll for the life of the
    /// PR (review of #930).
    nonisolated static let maxAutoReReviewFailureRetries = 3

    /// Perform the re-request. Capability-gated like every other PR write, so
    /// a provider without `.requestReviewers` degrades to a logged skip.
    ///
    /// Failure handling mirrors `attemptRebase`'s bounded-retry shape rather
    /// than `attemptDirectMerge`'s latch-everything one: a re-request is
    /// idempotent, so retrying a transient network failure is free, while
    /// retrying forever is not. Both terminal conditions below leave the round
    /// key latched, so they log once per round rather than once per poll.
    private func attemptReRequestReview(session: Session, pr: ViewerPR, roundKey: String) async {
        defer { autoReRequestInFlight.remove(pr.url) }
        guard let backend = owner.codeBackend(for: session) else {
            // Terminal for this session, not transient: the provider is a
            // property of the session and can't change under a live round.
            // Latch, like the capability gate below.
            owner.logSteadyState(
                channel: IssueTracker.autoReReviewLogChannel,
                prURL: pr.url,
                message: "auto-re-request: #\(pr.number) skipped:no-code-backend",
                now: Date())
            return
        }
        guard backend.capabilities.contains(.requestReviewers) else {
            owner.logSteadyState(
                channel: IssueTracker.autoReReviewLogChannel,
                prURL: pr.url,
                message: "auto-re-request: #\(pr.number) skipped:provider-unsupported "
                    + "(\(backend.provider.rawValue))",
                now: Date())
            return
        }
        let logins = pr.changesRequestedReviewerLogins
        // Logged here rather than at dispatch so `grep dispatched` counts
        // attempts that actually reached the host: both terminal guards above
        // return before this point, and used to leave a "dispatched" line
        // standing in front of a skip that contradicted it.
        //
        // Through the shared limiter, and stamped with the head: a retry
        // within the same round repeats this message verbatim and is deduped,
        // while a genuinely new round (new push or new reviewer submission)
        // changes the sha or the timestamp and logs.
        owner.logSteadyState(
            channel: IssueTracker.autoReReviewLogChannel,
            prURL: pr.url,
            message: "auto-re-request: dispatched #\(pr.number) → \(logins.joined(separator: ", ")) "
                + "(sha=\(pr.headRefOid.prefix(8)), lastCR=\(IssueTracker.iso(pr.lastChangesRequestedAt)), "
                + "lastCommit=\(IssueTracker.iso(pr.lastSubstantiveCommitAt)))",
            now: Date())
        do {
            try await backend.requestReviewers(prURL: pr.url, logins: logins)
            autoReReviewFailureCounts.removeValue(forKey: roundKey)
            CrowLog.automation(
                "auto-re-request: #\(pr.number) re-requested \(logins.joined(separator: ", ")) "
                + "— session=\(session.id.uuidString)")
        } catch {
            let failures = (autoReReviewFailureCounts[roundKey] ?? 0) + 1
            autoReReviewFailureCounts[roundKey] = failures
            let giveUp = failures >= Self.maxAutoReReviewFailureRetries
            if !giveUp {
                // Clear the round key so the next poll retries. The PR is
                // still in `.awaitingReRequest` (nothing changed host-side),
                // so this is a genuine retry rather than a duplicate request —
                // and if the call actually landed despite the error, re-adding
                // a pending reviewer is a no-op.
                autoReRequestAttempted.remove(roundKey)
            }
            owner.logSteadyState(
                channel: IssueTracker.autoReReviewLogChannel,
                prURL: pr.url,
                message: "auto-re-request: #\(pr.number) failed "
                    + "(attempt \(failures)/\(Self.maxAutoReReviewFailureRetries)"
                    + "\(giveUp ? ", giving up until the next round" : "")): "
                    + "\(error.localizedDescription.prefix(200))",
                now: Date())
        }
    }
}

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` / `tracker.<member>` spelling the tests
// use. All logic and state live on `AutoReReviewController`.
extension IssueTracker {
    typealias AutoReReviewSkipReason = AutoReReviewController.AutoReReviewSkipReason

    nonisolated static func autoReReviewSkipReason(
        pr: ViewerPR,
        status: PRStatus,
        isReviewSession: Bool,
        agentSettled: Bool
    ) -> AutoReReviewSkipReason? {
        AutoReReviewController.autoReReviewSkipReason(
            pr: pr, status: status, isReviewSession: isReviewSession, agentSettled: agentSettled)
    }

    nonisolated static func sessionEligibleForAutoReReview(_ session: Session) -> Bool {
        AutoReReviewController.sessionEligibleForAutoReReview(session)
    }

    nonisolated static func autoReReviewRoundKey(
        url: String, headRefOid: String, lastChangesRequestedAt: Date?
    ) -> String {
        AutoReReviewController.autoReReviewRoundKey(
            url: url, headRefOid: headRefOid, lastChangesRequestedAt: lastChangesRequestedAt)
    }

    nonisolated static var maxAutoReReviewFailureRetries: Int {
        AutoReReviewController.maxAutoReReviewFailureRetries
    }

    var autoReRequestInFlight: Set<String> {
        get { autoReReview.autoReRequestInFlight }
        set { autoReReview.autoReRequestInFlight = newValue }
    }
    var autoReRequestAttempted: Set<String> {
        get { autoReReview.autoReRequestAttempted }
        set { autoReReview.autoReRequestAttempted = newValue }
    }
    var autoReReviewFailureCounts: [String: Int] {
        get { autoReReview.autoReReviewFailureCounts }
        set { autoReReview.autoReReviewFailureCounts = newValue }
    }
}
