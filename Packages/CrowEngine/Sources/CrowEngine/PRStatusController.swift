import Foundation
import CrowCore
import CrowProvider

/// PR-status piggyback extracted from `IssueTracker` (CROW-1251). Builds
/// `PRStatus` for each session with a `.pr` link, emits checks-failing /
/// needs-refine transitions, and then drives auto-merge / auto-rebase /
/// auto-re-review in that order. Owns the first-observation skip, needs-refine
/// cooldown, idle-terminal gate, sticky `crow:merge` marker (#838), and the
/// shared steady-state log dedupe. Reaches `appState`, the user-toggle
/// closures, the transition callback, and the three watchers through an
/// unowned back-reference. `refresh()` / `applyFetchedBoard` still drive
/// `applyPRStatuses` in the current order.
@MainActor
final class PRStatusController {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    init(owner: IssueTracker) { self.owner = owner }

    // MARK: - State

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

    // MARK: - Piggyback

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
        let byURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: IssueTracker.mergePRRecords)

        var transitions: [PRStatusTransition] = []
        let now = Date()
        let respondToChangesRequested = owner.respondToChangesRequestedProvider()
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
            owner.onPRStatusTransitions?(transitions)
        }

        owner.autoMerge.applyAutoMerge(viewerPRs: viewerPRs)
        owner.autoRebase.applyAutoRebase(viewerPRs: viewerPRs)
        owner.autoReReview.applyAutoReRequestReview(viewerPRs: viewerPRs)
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
                $0.name.caseInsensitiveCompare(AutoMergeController.autoMergeLabel) == .orderedSame
            }
        )
    }
}

// MARK: - IssueTracker compatibility surface (CROW-1251)
//
// Preserves the `IssueTracker.<symbol>` / `tracker.<member>` spelling used by
// the tests, by `addMergeLabel`, and by auto-re-review (owner.logSteadyState /
// owner.agentSettled / IssueTracker.buildPRStatus). All logic and state live
// on `PRStatusController`.
extension IssueTracker {
    typealias NeedsRefineGate = PRStatusController.NeedsRefineGate

    func applyPRStatuses(viewerPRs: [ViewerPR]) {
        prStatus.applyPRStatuses(viewerPRs: viewerPRs)
    }

    nonisolated static func needsRefineGate(
        status: PRStatus,
        toggleOn: Bool,
        isReviewSession: Bool,
        firstObservation: Bool,
        terminalIdle: Bool,
        cooldownElapsed: Bool
    ) -> NeedsRefineGate? {
        PRStatusController.needsRefineGate(
            status: status,
            toggleOn: toggleOn,
            isReviewSession: isReviewSession,
            firstObservation: firstObservation,
            terminalIdle: terminalIdle,
            cooldownElapsed: cooldownElapsed
        )
    }

    @discardableResult
    func logSteadyState(
        channel: String, prURL: String, message: String, now: Date
    ) -> Bool {
        prStatus.logSteadyState(channel: channel, prURL: prURL, message: message, now: now)
    }

    func agentSettled(sessionID: UUID) -> Bool {
        prStatus.agentSettled(sessionID: sessionID)
    }

    nonisolated static func iso(_ date: Date?) -> String {
        PRStatusController.iso(date)
    }

    nonisolated static func buildPRStatus(from pr: ViewerPR) -> PRStatus {
        PRStatusController.buildPRStatus(from: pr)
    }

    nonisolated static var needsRefineCooldown: TimeInterval { PRStatusController.needsRefineCooldown }
    nonisolated static var steadyStateLogHeartbeat: TimeInterval { PRStatusController.steadyStateLogHeartbeat }
    nonisolated static var needsRefineLogChannel: String { PRStatusController.needsRefineLogChannel }
    nonisolated static var autoReReviewLogChannel: String { PRStatusController.autoReReviewLogChannel }

    nonisolated static func steadyStateLogKey(channel: String, prURL: String) -> String {
        PRStatusController.steadyStateLogKey(channel: channel, prURL: prURL)
    }

    var previousPRStatus: [UUID: PRStatus] {
        get { prStatus.previousPRStatus } set { prStatus.previousPRStatus = newValue }
    }
    var seenPRs: Set<String> {
        get { prStatus.seenPRs } set { prStatus.seenPRs = newValue }
    }
    var lastRefineDispatchAt: [String: Date] {
        get { prStatus.lastRefineDispatchAt } set { prStatus.lastRefineDispatchAt = newValue }
    }
    var lastNotifiedChangesRequestedAt: [String: Date] {
        get { prStatus.lastNotifiedChangesRequestedAt } set { prStatus.lastNotifiedChangesRequestedAt = newValue }
    }
    var steadyStateLogDedupe: [String: (message: String, at: Date)] {
        get { prStatus.steadyStateLogDedupe } set { prStatus.steadyStateLogDedupe = newValue }
    }
    var pendingMergeLabelSessions: Set<UUID> {
        get { prStatus.pendingMergeLabelSessions } set { prStatus.pendingMergeLabelSessions = newValue }
    }
}
