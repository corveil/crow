import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

@Suite("IssueTracker auto-merge watcher (crow:merge label)")
struct IssueTrackerAutoMergeTests {

    // MARK: - Fixtures

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "0E8A16")
    private static let otherLabel = LabelInfo(name: "documentation", color: "ffffff")

    private func makePR(
        url: String = "https://github.com/corveil/crow/pull/42",
        number: Int = 42,
        state: String = "OPEN",
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String = "CLEAN",
        reviewDecision: String = "APPROVED",
        isDraft: Bool = false,
        labels: [LabelInfo] = [crowMergeLabel],
        repo: String = "corveil/crow"
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: number,
            url: url,
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: "feature/x",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: repo,
            labels: labels,
            linkedIssueReferences: [],
            checksState: "SUCCESS",
            failedCheckNames: [],
            latestReviewStates: ["APPROVED"]
        )
    }

    private func makeSession(autoMergeEnabledAt: Date? = nil) -> Session {
        Session(
            id: UUID(),
            name: "session",
            autoMergeEnabledAt: autoMergeEnabledAt
        )
    }

    // MARK: - buildPRStatus surfaces the label to the UI (CROW-773)

    @Test func buildPRStatusFlagsCrowMergeLabel() {
        #expect(IssueTracker.buildPRStatus(from: makePR()).hasMergeLabel)
    }

    @Test func buildPRStatusClearsFlagWithoutTheLabel() {
        #expect(!IssueTracker.buildPRStatus(from: makePR(labels: [Self.otherLabel])).hasMergeLabel)
        #expect(!IssueTracker.buildPRStatus(from: makePR(labels: [])).hasMergeLabel)
    }

    @Test func buildPRStatusMatchesLabelCaseInsensitively() {
        // Same case-insensitive rule `shouldAttemptAutoMerge` gates on — the
        // indicator must never disagree with the watcher about the same PR.
        let pr = makePR(labels: [LabelInfo(name: "Crow:Merge", color: nil)])
        #expect(IssueTracker.buildPRStatus(from: pr).hasMergeLabel)
        #expect(IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    // MARK: - shouldAttemptAutoMerge guards

    @Test func acceptsHealthyLabeledPR() {
        let pr = makePR()
        let session = makeSession()
        #expect(IssueTracker.shouldAttemptAutoMerge(pr: pr, session: session))
    }

    @Test func ignoresPRWithoutCrowMergeLabel() {
        let pr = makePR(labels: [Self.otherLabel])
        let session = makeSession()
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: session))
    }

    @Test func ignoresAlreadyEnabledSession() {
        let pr = makePR()
        let session = makeSession(autoMergeEnabledAt: Date())
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: session))
    }

    @Test func ignoresConflictingPR() {
        let pr = makePR(mergeable: "CONFLICTING")
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func ignoresDraftPR() {
        let pr = makePR(isDraft: true)
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func ignoresChangesRequestedPR() {
        let pr = makePR(reviewDecision: "CHANGES_REQUESTED")
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func ignoresClosedPR() {
        let pr = makePR(state: "CLOSED")
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func ignoresMergedPR() {
        let pr = makePR(state: "MERGED")
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func acceptsCaseInsensitiveLabelMatch() {
        // GitHub treats labels as case-insensitive on lookup. Crow does too,
        // so a stored label of "Crow:Merge" still triggers the watcher.
        let pr = makePR(labels: [LabelInfo(name: "Crow:Merge", color: nil)])
        #expect(IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func acceptsPRWithReviewDecisionNotYetSet() {
        // Repos without required reviewers report `reviewDecision: ""` even
        // when the PR is mergeable. GitHub will still honor --auto for them.
        let pr = makePR(reviewDecision: "")
        #expect(IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    // MARK: - shouldUpdateBranchBeforeMerge (BEHIND base)

    @Test func updatesBranchWhenBehindBase() {
        // Otherwise-mergeable labeled PR that GitHub reports as out-of-date.
        let pr = makePR(mergeStateStatus: "BEHIND")
        #expect(IssueTracker.shouldUpdateBranchBeforeMerge(pr: pr, session: makeSession()))
    }

    @Test func behindPRIsStillAMergeCandidate() {
        // BEHIND must not disqualify candidacy — we update first, merge later.
        let pr = makePR(mergeStateStatus: "BEHIND")
        #expect(IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }

    @Test func doesNotUpdateBranchWhenClean() {
        let pr = makePR(mergeStateStatus: "CLEAN")
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(pr: pr, session: makeSession()))
    }

    @Test func doesNotUpdateBranchWhenStateUnknown() {
        let pr = makePR(mergeStateStatus: "UNKNOWN")
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(pr: pr, session: makeSession()))
    }

    @Test func doesNotUpdateBranchForRealConflict() {
        // CONFLICTING is gated by shouldAttemptAutoMerge; DIRTY is not BEHIND.
        let conflicting = makePR(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY")
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(pr: conflicting, session: makeSession()))
        let dirty = makePR(mergeStateStatus: "DIRTY")
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(pr: dirty, session: makeSession()))
    }

    @Test func doesNotUpdateBranchWhenNotACandidate() {
        // A BEHIND PR that fails the candidate gate (no label / already
        // enabled / draft / changes requested) must not trigger an update.
        let session = makeSession()
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(
            pr: makePR(mergeStateStatus: "BEHIND", labels: [Self.otherLabel]), session: session))
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(
            pr: makePR(mergeStateStatus: "BEHIND", reviewDecision: "CHANGES_REQUESTED"), session: session))
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(
            pr: makePR(mergeStateStatus: "BEHIND", isDraft: true), session: session))
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(
            pr: makePR(mergeStateStatus: "BEHIND"), session: makeSession(autoMergeEnabledAt: Date())))
    }

    // MARK: - Trailer parsing

    @Test func extractsSingleTrailer() {
        let uuid = UUID()
        let msg = """
        feat: add the thing

        Some body text.

        Crow-Session: \(uuid.uuidString)
        Co-Authored-By: Claude <noreply@anthropic.com>
        """
        let result = IssueTracker.extractCrowSessionUUIDs(from: msg)
        #expect(result == [uuid])
    }

    @Test func extractsMultipleTrailers() {
        let a = UUID()
        let b = UUID()
        let msg = """
        squash merge of two commits

        Crow-Session: \(a.uuidString)
        Crow-Session: \(b.uuidString)
        """
        let result = IssueTracker.extractCrowSessionUUIDs(from: msg)
        #expect(Set(result) == Set([a, b]))
    }

    @Test func ignoresMalformedUUID() {
        let msg = "subject\n\nCrow-Session: not-a-real-uuid\n"
        #expect(IssueTracker.extractCrowSessionUUIDs(from: msg).isEmpty)
    }

    @Test func requiresLineStartAnchor() {
        // Mid-line "Crow-Session:" doesn't count — trailers are line-anchored
        // (matches `git interpret-trailers`).
        let uuid = UUID()
        let msg = "subject ending with prefix Crow-Session: \(uuid.uuidString) inline"
        #expect(IssueTracker.extractCrowSessionUUIDs(from: msg).isEmpty)
    }

    @Test func returnsEmptyWhenNoTrailerPresent() {
        let msg = "subject\n\nbody with no trailers\n\nCo-Authored-By: Claude\n"
        #expect(IssueTracker.extractCrowSessionUUIDs(from: msg).isEmpty)
    }

    // MARK: - crowAuthored

    @Test func crowAuthoredTrueWhenTrailerMatchesKnownSession() {
        let known = UUID()
        let messages = [
            "fix: typo\n",
            "feat: add\n\nCrow-Session: \(known.uuidString)\n"
        ]
        #expect(IssueTracker.crowAuthored(commitMessages: messages, knownSessionIDs: [known]))
    }

    @Test func crowAuthoredFalseWhenTrailerPointsToUnknownSession() {
        // Acceptance criterion #4: trailer-with-unknown-session must be
        // treated as NOT Crow-authored. Prevents someone copy-pasting the
        // trailer convention into a hand-written commit from triggering us.
        let known = UUID()
        let other = UUID()
        let messages = ["feat: thing\n\nCrow-Session: \(other.uuidString)\n"]
        #expect(!IssueTracker.crowAuthored(commitMessages: messages, knownSessionIDs: [known]))
    }

    @Test func crowAuthoredFalseWhenNoTrailers() {
        // Acceptance criterion #3: a labeled PR with no Crow trailers
        // (hand-written commits) must be ignored entirely.
        let messages = ["fix: external contribution\n\nCo-Authored-By: Someone\n"]
        #expect(!IssueTracker.crowAuthored(commitMessages: messages, knownSessionIDs: [UUID()]))
    }

    @Test func crowAuthoredFalseOnEmptyCommitList() {
        #expect(!IssueTracker.crowAuthored(commitMessages: [], knownSessionIDs: [UUID()]))
    }

    @Test func crowAuthoredTrueWhenAnyCommitMatches() {
        let known = UUID()
        let other = UUID()
        let messages = [
            "first commit\n\nCrow-Session: \(other.uuidString)\n",     // unknown — ignored
            "later commit\n\nCrow-Session: \(known.uuidString)\n"      // known — wins
        ]
        #expect(IssueTracker.crowAuthored(commitMessages: messages, knownSessionIDs: [known]))
    }

    // MARK: - Permanent auto-merge failures (CROW-621)

    @Test func permanentFailureWhenRepoDisallowsAutoMerge() {
        let error = ShellRunnerError.nonZeroExit(
            exitCode: 1,
            output: "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)\n"
        )
        #expect(IssueTracker.isPermanentAutoMergeFailure(error))
    }

    @Test func cleanStatusWithMutationNameIsRetryable() {
        // `gh` embeds `enablePullRequestAutoMerge` in every error from that
        // mutation — including when the PR is already mergeable/clean and
        // auto-merge was requested too late. That is not a permanent repo
        // policy denial; matching the bare field name would freeze retries.
        let error = ShellRunnerError.nonZeroExit(
            exitCode: 1,
            output: "GraphQL: Pull request is in clean status (enablePullRequestAutoMerge)\n"
        )
        #expect(!IssueTracker.isPermanentAutoMergeFailure(error))
    }

    @Test func bareMutationNameAloneIsNotPermanent() {
        let error = ShellRunnerError.nonZeroExit(
            exitCode: 1,
            output: "GraphQL: Something about enablePullRequestAutoMerge\n"
        )
        #expect(!IssueTracker.isPermanentAutoMergeFailure(error))
    }

    @Test func transientNetworkFailureIsRetryable() {
        let error = ShellRunnerError.nonZeroExit(
            exitCode: 1,
            output: "error connecting to api.github.com: dial tcp: i/o timeout\n"
        )
        #expect(!IssueTracker.isPermanentAutoMergeFailure(error))
    }

    @Test func transientAuthFailureIsRetryable() {
        let error = ShellRunnerError.nonZeroExit(
            exitCode: 1,
            output: "gh: To get started with GitHub CLI, please run:  gh auth login\n"
        )
        #expect(!IssueTracker.isPermanentAutoMergeFailure(error))
    }

    @Test func permanentFailureAlsoReadsLocalizedDescription() {
        // Non-ShellRunnerError path still classifies via localizedDescription.
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? {
                "Auto merge is not allowed for this repository"
            }
        }
        #expect(IssueTracker.isPermanentAutoMergeFailure(FakeError()))
    }
}

/// CROW-532: the "Add label crow:merge to PR" affordance must gate on the
/// session's **code** backend, not its **task** provider — so a Jira-tasked
/// session whose PR lives on GitHub gets the action, while a GitLab-code
/// session (no `.autoMergeLabel` capability) does not.
@Suite("canAddMergeLabel — gates on code backend, not task provider")
struct CanAddMergeLabelTests {
    private let providerManager = ProviderManager()

    private func session(provider: Provider?, codeProvider: Provider? = nil) -> Session {
        Session(id: UUID(), name: "s", provider: provider, codeProvider: codeProvider)
    }

    @Test func jiraTaskWithGitHubCodeShowsAffordance() {
        // The bug being fixed: task is Jira but the PR is on GitHub.
        let s = session(provider: .jira, codeProvider: .github)
        #expect(IssueTracker.canAddMergeLabel(session: s, providerManager: providerManager))
    }

    @Test func gitHubTaskStillShowsAffordance() {
        // No regression for the original GitHub-tasked case.
        let s = session(provider: .github)
        #expect(IssueTracker.canAddMergeLabel(session: s, providerManager: providerManager))
    }

    @Test func jiraTaskWithGitLabCodeHidesAffordance() {
        // GitLab declares no `.autoMergeLabel` capability — stays hidden
        // regardless of task provider.
        let s = session(provider: .jira, codeProvider: .gitlab)
        #expect(!IssueTracker.canAddMergeLabel(session: s, providerManager: providerManager))
    }

    @Test func gitLabTaskHidesAffordance() {
        let s = session(provider: .gitlab)
        #expect(!IssueTracker.canAddMergeLabel(session: s, providerManager: providerManager))
    }

    @Test func taskOnlyWithoutCodeProviderHidesAffordance() {
        // Defensive: a `.jira` task with no resolved `codeProvider` falls to
        // `.jira` (a task-only provider with no code backend) → hidden. In
        // practice `SessionService.resolvedCodeProvider` populates this field.
        let s = session(provider: .jira, codeProvider: nil)
        #expect(!IssueTracker.canAddMergeLabel(session: s, providerManager: providerManager))
    }
}

/// CROW-749: the "In Review" button gates on the session's **task** backend
/// declaring `.projectBoardStatus` — GitHub Projects v2 / Jira yes, GitLab no
/// (ADR 0005). Restores the retired native `canSetProjectStatus` gate.
@Suite("canSetProjectStatus — gates on task backend project-board capability")
struct CanSetProjectStatusTests {
    private let providerManager = ProviderManager()

    private func session(provider: Provider?) -> Session {
        Session(id: UUID(), name: "s", provider: provider)
    }

    @Test func gitHubTaskCanSetStatus() {
        #expect(IssueTracker.canSetProjectStatus(session: session(provider: .github), providerManager: providerManager))
    }

    @Test func jiraTaskCanSetStatus() {
        #expect(IssueTracker.canSetProjectStatus(session: session(provider: .jira), providerManager: providerManager))
    }

    @Test func gitLabTaskCannotSetStatus() {
        // GitLab declares no `.projectBoardStatus` capability.
        #expect(!IssueTracker.canSetProjectStatus(session: session(provider: .gitlab), providerManager: providerManager))
    }

    @Test func noProviderCannotSetStatus() {
        // A provider-less session (e.g. the Manager) is never eligible.
        #expect(!IssueTracker.canSetProjectStatus(session: session(provider: nil), providerManager: providerManager))
    }
}
