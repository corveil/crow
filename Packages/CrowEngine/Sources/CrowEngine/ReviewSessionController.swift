import Foundation
import CrowCore
import CrowPersistence
import CrowProvider

/// Review-session creation (CROW-1113), extracted from `SessionService`.
/// This file keeps the creator: `createReviewSession` and `ReviewClonePrep`.
///
/// Split across sibling files by CROW-1302 so a prompt-wording change reviews
/// apart from the hostile-head strip. The per-agent strips and
/// `removeReviewCloneConfig` live in `ReviewCloneStrips`, the off-main-actor
/// clone in `ReviewSessionController+Clone`, the prompt builders in
/// `ReviewSessionController+Prompt`, and the `SessionService` facade in
/// `ReviewSessionController+SessionService`.
///
/// This is a **behavior-preserving** split: the strip rules, prompt format,
/// clone/checkout steps, and kickoff dedup are unchanged. Reaches `appState`,
/// the shared **injected** `JSONStore`, `providerManager`, and the shared
/// shell / `prepareTerminal` primitives through an unowned back-reference
/// (ADR 0012 / #728). The static strips/prompt helpers and `createReviewSession`
/// are re-exposed on `SessionService` as facades so the launch gate, tests, and
/// other modules call them unchanged.
@MainActor
final class ReviewSessionController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var providerManager: ProviderManager? { owner.providerManager }
    private var telemetryPort: UInt16? { owner.telemetryPort }

    init(owner: SessionService) { self.owner = owner }

    /// Create a review session for an incoming PR review request.
    ///
    /// Returns the new session's ID on success, or `nil` if the PR URL could not
    /// be resolved or session creation failed. `selectAfterCreate` defaults to
    /// false: review kickoff is normally driven by `AppDelegate.enqueueReviewKickoff`
    /// which intentionally leaves the user's current detail-pane focus alone, so
    /// new review sessions appear in the sidebar without yanking the view.
    /// Concurrent writes to `appState.selectedSessionID` from racing kickoffs are
    /// what produced the SwiftUI reentrant-layout crash in #266.
    @discardableResult
    public func createReviewSession(prURL: String, selectAfterCreate: Bool = false) async -> UUID? {
        // The duplicate/round guard lives *below*, after `fetchPRMetadata`,
        // because deciding it needs the PR's real head — see the note there.

        // Parse org/repo and PR number from URL like "https://github.com/org/repo/pull/123"
        guard let parsed = Session.parseReviewPR(url: prURL) else {
            CrowLog.info("[SessionService] Could not parse PR URL: \(prURL)")
            return nil
        }
        let owner = parsed.owner
        let repoName = parsed.repo
        let prNumber = parsed.number
        let repoSlug = "\(owner)/\(repoName)"

        // Determine clone path
        guard let devRoot = ConfigStore.loadDevRoot() else {
            CrowLog.info("[SessionService] No devRoot configured")
            return nil
        }

        // All git/network/file-write work runs off the main actor so the UI
        // never beachballs while a review spins up (#404). The detached task
        // hands back just the metadata the main-actor tail needs to build
        // the Session/Worktree/Terminal/Link rows.
        //
        // The resolved review-agent kind is captured here (main actor) so the
        // detached prepareReviewClone can pick the right prompt-file content
        // — Claude reads a `/crow-review-pr` slash command; Cursor reads the
        // expanded SKILL.md body (#431).
        let reviewAgentKind = appState.agentKind(for: .review)
        // Which severities gate this review's verdict (CROW-963). Resolved by repo
        // slug, NOT by worktree path: a review clone lives at
        // `{devRoot}/crow-reviews/…`, whose first path component matches no
        // workspace — the same trap that silently unset the gateway for every
        // review in CROW-891. Sampled here, on the main actor and before the
        // `await`s, for the same reason `reviewAgentKind` is: a config save
        // landing mid-clone would otherwise render a policy the session was never
        // launched under. Nil (no workspace claims the repo, or it never set the
        // field) means Crow's default, not "nothing blocks".
        let reviewBlocking = ConfigStore.loadConfig(devRoot: devRoot)?
            .workspace(forRepoSlug: repoSlug)?
            .effectiveReviewBlockingSeverities ?? ReviewSeverity.defaultBlocking
        let env = ShellEnvironment.shared.env

        // Fetch PR metadata via the GitHub CodeBackend (ADR 0005) before
        // dispatching the heavyweight clone work to a detached task. Done
        // here on the main actor so the providerManager dependency doesn't
        // need to cross the actor boundary into the detached task.
        let prMetadata: PRMetadata
        do {
            guard let manager = providerManager else {
                CrowLog.info("[SessionService] No providerManager wired; cannot prepare review for \(prURL)")
                return nil
            }
            let backend = manager.codeBackend(for: .github)!
            prMetadata = try await backend.fetchPRMetadata(prURL: prURL)
        } catch {
            CrowLog.info("[SessionService] Failed to fetch PR metadata for \(prURL): \(error.localizedDescription)")
            return nil
        }

        // Duplicate/round guard — the *one* kickoff decision, run through the
        // same pure function the daemon's auto-review hook uses so the
        // manual/board path and the `autoReviewRepos` path can't disagree about
        // whether a round is still open (CROW-945; before this there were two
        // divergent dedup rules and only the auto path could ever re-review).
        //
        // Deliberately placed here, after the metadata fetch, for two reasons.
        // It needs the PR's *real* head to tell "already covered" from "the
        // author pushed and this is a new round" — `appState.reviewRequests` is
        // up to a poll stale and is simply absent for a PR hidden by the board
        // filters or for a voluntary `crow start-review` on a PR nobody asked
        // you to review, which would pin the decision to `.skip` forever with
        // no way out. And reading `existingReviewSession` *after* the awaits
        // keeps the CROW-406 property the old top-of-function check had: a
        // session that landed while we were fetching is still seen. (Callers
        // are serialized on the review kickoff queue, so this is belt and
        // braces.) The fetch is not extra work — the clone below needs it
        // regardless.
        if let existing = appState.existingReviewSession(forPRURL: prURL) {
            let action = IssueTracker.reviewKickoffAction(
                reviewSessionID: existing.id,
                headRefOid: prMetadata.headRefOid,
                linkedSession: existing,
                existingByPRSessionID: existing.id
            )
            switch action {
            case .skip, .create:
                // `.create` is unreachable here (it requires no existing
                // session) — treat it as `.skip` rather than racing the live
                // session with a second one for the same PR.
                CrowLog.info("[SessionService] Skipping duplicate review session for \(prURL); reusing \(existing.id)")
                if selectAfterCreate { appState.selectedSessionID = existing.id }
                return existing.id
            case .reReview(let staleID):
                // Retire the stale round before creating the new one. Called
                // directly rather than through `appState.onCompleteSession`:
                // that callback is optional and only CrowDaemon wires it, so a
                // nil one would complete nothing and then leave two live
                // sessions on one PR — the CROW-406 double-session this guard
                // exists to prevent. Completing (not deleting) also writes the
                // round's end-of-run analytics snapshot, and makes it invisible
                // to `existingReviewSession`, which is what lets the create
                // below proceed.
                CrowLog.info("[SessionService] PR head advanced past review session \(staleID); completing it and starting a new round for \(prURL)")
                self.owner.completeSession(id: staleID)
            }
        }

        let prep: ReviewClonePrep
        do {
            prep = try await Task.detached(priority: .userInitiated) {
                try await Self.prepareReviewClone(
                    prURL: prURL,
                    repoSlug: repoSlug,
                    repoName: repoName,
                    prNumber: prNumber,
                    devRoot: devRoot,
                    env: env,
                    reviewAgentKind: reviewAgentKind,
                    reviewBlocking: reviewBlocking,
                    prMetadata: prMetadata
                )
            }.value
        } catch {
            CrowLog.info("[SessionService] Failed to prepare review clone for \(prURL): \(error.localizedDescription)")
            return nil
        }

        // Create session
        let session = Session(
            name: "review-\(repoName)-\(prNumber)",
            kind: .review,
            // Reuse the `reviewAgentKind` captured before the clone `await`s
            // (#829 review round 11), NOT a fresh `appState.agentKind(for:)`.
            // `SessionService` is `@MainActor` but the PR-metadata fetch and the
            // `gh repo clone` both suspend, so a config save landing in that
            // window would otherwise make the launching agent differ from the
            // one that gated the `.cursor/`/`.codex/` strip and picked the
            // prompt body — a Claude→Cursor drift would run Cursor unstripped in
            // the hostile clone AND hand it a `/crow-review-pr` slash line it has
            // no engine for. Sampling once makes the strip gate, prompt format,
            // attribution, and launching agent the same value by construction.
            agentKind: reviewAgentKind,
            ticketTitle: prep.prTitle,
            provider: .github,
            lastReviewedHeadSha: prep.headRefOid,
            reviewAuthor: prMetadata.author.isEmpty ? nil : prMetadata.author
        )

        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoName,
            repoPath: prep.clonePath,
            worktreePath: prep.clonePath,
            branch: prep.headBranch,
            isPrimary: true
        )

        let terminal = SessionTerminal(
            sessionID: session.id,
            name: session.agentKind.displayName,
            cwd: prep.clonePath,
            isManaged: true
        )

        let prLink = SessionLink(
            sessionID: session.id,
            label: "PR #\(prNumber)",
            url: prURL,
            linkType: .pr
        )

        // Backend dispatch — prepareTerminal returns the row with
        // backend/tmuxBinding set and starts the surface or tmux window.
        let preparedTerminal = self.owner.prepareTerminal(terminal, trackReadiness: true)

        // Add to state
        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [preparedTerminal]
        appState.links[session.id] = [prLink]
        appState.terminalReadiness[preparedTerminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(preparedTerminal.id)

        // Persist
        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(preparedTerminal)
            data.links.append(prLink)
        }

        // Select the new session
        if selectAfterCreate {
            appState.selectedSessionID = session.id
        }

        CrowLog.info("[SessionService] Created review session '\(session.name)' for \(prURL)")
        return session.id
    }

    /// Metadata produced by the off-main-actor `prepareReviewClone` step.
    /// Holds everything the main-actor tail of `createReviewSession` needs to
    /// build the `Session` / `SessionWorktree` / `SessionTerminal` rows.
    /// Internal (not `private`) so `prepareReviewClone` in
    /// `ReviewSessionController+Clone` can return it — Swift `private` is
    /// file-scoped (CROW-1302).
    struct ReviewClonePrep: Sendable {
        let prTitle: String
        let headBranch: String
        let headRefOid: String?
        let clonePath: String
    }
}
