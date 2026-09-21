import CrowCore
import CrowEngine
import CrowPersistence
import Foundation

/// Tracker + terminal automation wiring extracted from `CrowDaemon` (CROW-1279).
/// `wireTrackerAutomations` stays unconditional (no tmux/`SessionService` gate);
/// `wireTerminalAutomations` is the tmux-only half (CROW-782).
extension CrowDaemon {
    /// Wire the terminal-independent half of the automation wiring: the
    /// config-flag providers, plus the outcome hooks that only need `eventHub` to
    /// push a user-facing notification to connected web clients (CROW-768 —
    /// restoring what the retired native NotificationManager did). Each provider
    /// reads `{devRoot}/.claude/config.json` fresh on every poll so Settings edits
    /// take effect without a restart (CROW-581).
    ///
    /// MUST be called unconditionally, not from inside a `if let sessionService`
    /// (i.e. tmux-present) branch: a provider left at its `{ false }` default
    /// disables the whole watcher — `applyAutoMerge`'s first guard — even though
    /// enabling auto-merge and rebasing a branch need no terminal at all
    /// (CROW-782). `internal` (not `private`) so `CrowDaemonTests` can assert the
    /// providers come up armed.
    ///
    /// `autoRespond` is optional here precisely because it's nil without tmux: the
    /// conflict hand-off is then skipped, but the notification still fires.
    @MainActor
    static func wireTrackerAutomations(
        tracker: IssueTracker,
        appState: AppState,
        devRoot: String,
        autoRespond: AutoRespondCoordinator? = nil,
        eventHub: EventHub? = nil
    ) {
        func config() -> AppConfig? { ConfigStore.loadConfig(devRoot: devRoot) }
        // The tracker's hooks are synchronous; the hub is an actor. Hop off in a
        // detached-from-the-caller Task so a broadcast never blocks a watcher.
        func notify(_ event: NotificationEvent, key: String, title: String, body: String) {
            guard let eventHub else { return }
            Task { await eventHub.broadcastNotification(event: event, key: key, title: title, body: body) }
        }
        // Name a session for a notification title, as the native manager did.
        func sessionName(_ id: UUID) -> String {
            appState.sessions.first(where: { $0.id == id })?.name ?? "session"
        }

        // crow:auto — gate only; the dispatch lives in wireTerminalAutomations.
        // The tracker refuses to strip the label when no handler is wired, so an
        // armed provider with no Manager terminal can't burn the trigger (#787).
        tracker.autoCreateWatcherEnabledProvider = { (config()?.autoCreateWatcherEnabled ?? false) }

        // Auto-respond / auto-rebase gates. The rebase + force-push itself runs in
        // the tracker (pure git); only the conflict hand-off needs a terminal.
        tracker.respondToChangesRequestedProvider = { (config()?.autoRespond.respondToChangesRequested ?? false) }
        tracker.autoRebaseAndResolveConflictsProvider = { (config()?.autoRespond.autoRebaseAndResolveConflicts ?? false) }

        // Auto re-request review (CROW-921). Needs no terminal at all — the
        // daemon calls the host API directly — which is the point: the PRs it
        // rescues are exactly the ones no prompt can reach.
        tracker.autoReRequestReviewProvider = { (config()?.autoRespond.autoReRequestReview ?? false) }

        // Auto-rebase outcomes. The conflict hand-off dispatches to the session's
        // agent when a coordinator exists, but the notification fires either way —
        // conflicts need a human's attention even with no terminal to paste into.
        tracker.onAutoRebasePushed = { sessionID, _, number in
            notify(.autoRebasePushed, key: sessionID.uuidString,
                   title: "Branch rebased — \(sessionName(sessionID))",
                   body: "PR #\(number) was rebased onto its base and force-pushed.")
        }
        tracker.onAutoRebaseConflicts = { sessionID, _, number in
            // Only claim the agent was asked to resolve when the prompt actually
            // reached a managed terminal — with no coordinator, no terminal, or a
            // refused review session the body would otherwise mislead (review).
            let handedOff = autoRespond?.dispatchManual(
                action: .fixConflicts, sessionID: sessionID).isSent ?? false
            let body = handedOff
                ? "PR #\(number) has conflicts. Crow asked the agent to resolve them."
                : "PR #\(number) has conflicts that need attention."
            notify(.autoRebaseConflicts, key: sessionID.uuidString,
                   title: "Rebase conflicts — \(sessionName(sessionID))",
                   body: body)
        }
        // The third auto-rebase outcome, and the one with no automated next
        // step: a dirty worktree, or a branch holding commits `origin` doesn't.
        // Deliberately no `dispatchManual` — there are no conflicts to resolve,
        // and an agent told to "fix" a diverged branch reaches for a reset that
        // would destroy the very commits blocking the rebase (#944).
        // `state.message` is the daemon's own sentence, rendered verbatim —
        // same contract as `onAutoMergeBlocked` below.
        tracker.onAutoRebaseStuck = { sessionID, _, number, state in
            notify(.autoRebaseStuck, key: sessionID.uuidString,
                   title: "Rebase stuck — \(sessionName(sessionID))",
                   body: "PR #\(number): \(state.message)")
        }

        // Auto-merge (enable GitHub native auto-merge on eligible Crow PRs). The
        // audit line goes to the automation log at the tracker's call site
        // regardless of whether any client is connected to receive the notification.
        tracker.autoMergeWatcherEnabledProvider = { (config()?.autoMergeWatcherEnabled ?? false) }
        tracker.onAutoMergeEnabled = { sessionID, _, number in
            notify(.autoMergeEnabled, key: sessionID.uuidString,
                   title: "Auto-merge enabled — \(sessionName(sessionID))",
                   body: "PR #\(number) will merge once required reviews and checks pass.")
        }
        // The counterpart, and the one that actually needed a channel: a
        // permanent skip latches, so no later poll re-announces it. Before #888
        // the only trace was one line in crowd-automation.log (CROW-621).
        tracker.onAutoMergeBlocked = { sessionID, _, number, state in
            notify(.autoMergeBlocked, key: sessionID.uuidString,
                   title: "Auto-merge blocked — \(sessionName(sessionID))",
                   body: "PR #\(number): \(state.message)")
        }
    }

    /// Wire the automation hooks that need somewhere to act: the daemon's Manager
    /// terminal, the session's managed terminal, or `SessionService`. Only called
    /// when the tmux cockpit came up (CROW-581). Notifications for these paths go
    /// to connected web clients over `eventHub` (CROW-768).
    @MainActor
    static func wireTerminalAutomations(
        tracker: IssueTracker,
        appState: AppState,
        sessionService: SessionService,
        autoRespond: AutoRespondCoordinator?,
        devRoot: String,
        reviewSerializer: ReviewKickoffSerializer,
        eventHub: EventHub
    ) {
        func config() -> AppConfig? { ConfigStore.loadConfig(devRoot: devRoot) }
        // The tracker's hooks are synchronous; the hub is an actor. Hop off in a
        // detached-from-the-caller Task so a broadcast never blocks a watcher.
        func notify(_ event: NotificationEvent, key: String, title: String, body: String) {
            Task { await eventHub.broadcastNotification(event: event, key: key, title: title, body: body) }
        }
        // Name a session for a notification title, as the native manager did.
        func sessionName(_ id: UUID) -> String {
            appState.sessions.first(where: { $0.id == id })?.name ?? "session"
        }

        // crow:auto — run /crow-workspace on the Manager for a newly-labeled
        // assigned issue (the tracker strips the label after, so once-only).
        tracker.onAutoCreateRequest = { issue, kind in
            guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
                log("crow:auto: Manager terminal not ready; dropped \(issue.url)")
                return
            }
            TerminalRouter.send(
                managerTerminal,
                text: workspaceLaunchCommand(urls: [issue.url], explore: kind == .explore))
            // No session exists yet — key the notification on the issue URL.
            let exploring = kind == .explore
            notify(.autoWorkspaceCreated, key: issue.url,
                   title: exploring
                    ? "Auto-creating exploration — \(issue.repo)"
                    : "Auto-creating workspace — \(issue.repo)",
                   body: "#\(issue.number): \(issue.title)")
        }

        // Auto-respond to PR transitions (changes-requested / checks-failing) and
        // auto-rebase conflict hand-off — both go through the coordinator, which
        // pastes the prompt into the session's managed terminal.
        if let autoRespond {
            tracker.onPRStatusTransitions = { transitions in
                autoRespond.handle(transitions)
            }
        }
        // Note: the auto-rebase/auto-merge OUTCOME hooks (onAutoRebasePushed,
        // onAutoRebaseConflicts, onAutoMergeEnabled) and the config-flag providers
        // are wired in `wireTrackerAutomations` instead — they need only `eventHub`
        // (and, for the conflict hand-off, an optional coordinator), so gating them
        // on tmux would silence notifications for automations that still run
        // (CROW-768 + CROW-782).

        // Auto-complete on merge/close, and auto-move-to-inReview when a
        // session's PR opens, run INSIDE the tracker's own refresh via these
        // `AppState` callbacks (not tracker hooks). The app wires them in
        // AppDelegate; the daemon must too, or `autoCompleteFinishedSessions`
        // / `autoCompleteFinishedReviews` compute the right decisions and then
        // no-op against a nil callback — leaving merged PRs' sessions stuck in
        // `.active`. Authority-gated so the daemon only drives them with the
        // app down; while it's up the app's own refresh owns them (CROW-581).
        appState.onCompleteSession = { id in
            sessionService.completeSession(id: id)
        }
        appState.onSetSessionInReview = { id in
            sessionService.setSessionInReview(id: id)
        }

        // Auto-cleanup — the retention reaper asks the tracker to delete a
        // session; run the daemon's own SessionService teardown.
        tracker.onDeleteSession = { id in
            await sessionService.deleteSession(id: id)
        }

        // Review auto-kickoff — for review requests on repos opted into
        // `autoReviewRepos`, spawn a review session (mirrors the desktop's
        // enqueueReviewKickoff). Fires on every refresh so requests pending at
        // startup are picked up; deduped by a (request, headSHA) fingerprint plus
        // the persisted reviewSessionID, and serialized so a burst can't race
        // duplicate clones. `onNewReviewRequests` is notification-only → dropped.
        //
        // Two kickoff conditions, ported from the legacy `AppDelegate` the
        // headless migration dropped (ADR 0008 / CROW-756): (A) no session yet →
        // create; (B) a linked session's `lastReviewedHeadSha` is stale vs. the
        // PR's current head → complete the stale round and re-review the new head
        // (force-push, or round-2 commits landing before Signal A —
        // `decideReviewCompletions` rule 1 — completed round 1). The SHA-keyed
        // fingerprint makes each head its own round so B isn't blocked by A.
        //
        // Both decisions now live in `SessionService.createReviewSession`, which
        // runs the same `IssueTracker.reviewKickoffAction` against the head it
        // fetches itself (CROW-945). This hook deliberately does NOT pre-decide:
        // it would have to use `request.headRefOid` — a board snapshot up to a
        // poll old — and two callers deciding from two different heads is
        // exactly the divergence that let a round go on shadowing its PR. So
        // this stays a filter + a rate guard, and the service owns the verdict.
        var autoReviewed: Set<String> = []
        tracker.onReviewRequestsRefreshed = { requests in
            let patterns = (config()?.workspaces ?? []).flatMap { $0.autoReviewRepos }
            guard !patterns.isEmpty else { return }
            for request in requests {
                guard repoMatchesPatterns(request.repo, patterns: patterns) else { continue }
                // SHA-keyed dedup: a new head is a fresh round; an unchanged head
                // never re-kicks (also guards the in-flight clone window before
                // the session's link/reviewSessionID land). In-memory only, so a
                // daemon restart can re-ask — `createReviewSession` still refuses
                // to duplicate a live round, so the worst case is one redundant
                // metadata fetch, not a duplicate session.
                let fingerprint = "\(request.id)\n\(request.headRefOid ?? "")"
                guard autoReviewed.insert(fingerprint).inserted else { continue }
                let url = request.url
                Task { _ = await reviewSerializer.enqueue { await sessionService.createReviewSession(prURL: url, selectAfterCreate: false) } }
            }
        }
    }
}
