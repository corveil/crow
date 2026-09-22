import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

// MARK: - Auto-merge attempt paths (CROW-1286)
//
// The three irreversible side-effect paths — enable native auto-merge, direct
// squash merge, and `update-branch` — plus the shared `codeBackend` /
// authorship helpers and the `recordAutoMergeSuccess` writer. Split out of
// `AutoMergeController` so the poll/targeted decision reviews apart from the
// code that actually merges. `attemptEnableAutoMerge` / `attemptDirectMerge`
// are dispatched from `evaluateAutoMerge` in the watcher, so they are internal
// (not private); `performDirectMerge` / `recordAutoMergeSuccess` are only
// reached from within this file and stay private.
extension AutoMergeController {
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
    func attemptEnableAutoMerge(session: Session, pr: ViewerPR) async {
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
    func attemptDirectMerge(session: Session, pr: ViewerPR) async {
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
}
