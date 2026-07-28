import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

/// #888 — a `crow:merge` label used to be able to land on a PR that would never
/// merge, with the reason visible only in `crowd-automation.log`. Two halves of
/// the fix are pure and therefore pinned here: the direct-merge fallback's
/// eligibility gates (the predicate standing between a labeled PR and an
/// irreversible merge), and the skip-reason taxonomy that carries a verdict to
/// the UI.
@Suite("IssueTracker direct-merge fallback + skip-reason taxonomy (#888)")
struct IssueTrackerDirectMergeTests {

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "0E8A16")

    /// A PR in the exact shape the ticket's smoking gun describes: corveil#1866,
    /// CLEAN + APPROVED + MERGEABLE + green checks, in a repo with GitHub's
    /// "Allow auto-merge" turned off.
    private func makePR(
        state: String = "OPEN",
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String = "CLEAN",
        reviewDecision: String = "APPROVED",
        isDraft: Bool = false,
        labels: [LabelInfo] = [crowMergeLabel],
        checksState: String = "SUCCESS",
        repoAutoMergeAllowed: Bool? = false
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: 1866,
            url: "https://github.com/corveil/corveil/pull/1866",
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: "feature/x",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: "corveil/corveil",
            labels: labels,
            linkedIssueReferences: [],
            checksState: checksState,
            failedCheckNames: [],
            latestReviewStates: ["APPROVED"],
            repoAutoMergeAllowed: repoAutoMergeAllowed
        )
    }

    private func makeSession(autoMergeEnabledAt: Date? = nil) -> Session {
        Session(id: UUID(), name: "session", autoMergeEnabledAt: autoMergeEnabledAt)
    }

    // MARK: - The one case the fallback exists for

    @Test func mergesAFullyGreenPRWhenTheRepoForbidsAutoMerge() {
        #expect(IssueTracker.shouldDirectMerge(pr: makePR(), session: makeSession()))
    }

    // MARK: - repoAutoMergeAllowed gating

    @Test func neverMergesWhenTheRepoPolicyIsUnknown() {
        // `nil` is "we didn't fetch the field" — GitLab, a partial SAML
        // recovery, a record cached before #888. Treating unknown as forbidden
        // would turn every such PR into a direct merge.
        #expect(!IssueTracker.shouldDirectMerge(
            pr: makePR(repoAutoMergeAllowed: nil), session: makeSession()))
    }

    @Test func neverMergesWhenTheRepoAllowsAutoMerge() {
        // The normal path: let GitHub queue it, so GitHub keeps enforcing its
        // own required checks and reviews.
        #expect(!IssueTracker.shouldDirectMerge(
            pr: makePR(repoAutoMergeAllowed: true), session: makeSession()))
    }

    // MARK: - Green-state gates (stricter than the auto-merge path on purpose)

    @Test func refusesWhenChecksAreNotGreen() {
        for checks in ["PENDING", "FAILURE", "ERROR", "EXPECTED", ""] {
            #expect(!IssueTracker.shouldDirectMerge(
                pr: makePR(checksState: checks), session: makeSession()),
                "checksState \(checks) must not merge")
        }
    }

    @Test func refusesEveryNonCleanMergeState() {
        // BLOCKED/UNSTABLE/BEHIND/HAS_HOOKS/DIRTY all mean GitHub itself would
        // not have shown a green merge button.
        for status in ["BLOCKED", "UNSTABLE", "BEHIND", "HAS_HOOKS", "DIRTY", "UNKNOWN"] {
            #expect(!IssueTracker.shouldDirectMerge(
                pr: makePR(mergeStateStatus: status), session: makeSession()),
                "mergeStateStatus \(status) must not merge")
        }
    }

    @Test func refusesWithoutAnApproval() {
        // Includes the empty string — a repo with no required reviewers. The
        // fallback stays out of its way rather than merging something no human
        // approved.
        for decision in ["", "REVIEW_REQUIRED", "CHANGES_REQUESTED"] {
            #expect(!IssueTracker.shouldDirectMerge(
                pr: makePR(reviewDecision: decision), session: makeSession()),
                "reviewDecision '\(decision)' must not merge")
        }
    }

    @Test func refusesWhenNotMergeable() {
        #expect(!IssueTracker.shouldDirectMerge(
            pr: makePR(mergeable: "UNKNOWN"), session: makeSession()))
        #expect(!IssueTracker.shouldDirectMerge(
            pr: makePR(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY"), session: makeSession()))
    }

    @Test func refusesDraftsClosedPRsAndUnlabeledPRs() {
        #expect(!IssueTracker.shouldDirectMerge(pr: makePR(isDraft: true), session: makeSession()))
        #expect(!IssueTracker.shouldDirectMerge(pr: makePR(state: "CLOSED"), session: makeSession()))
        #expect(!IssueTracker.shouldDirectMerge(pr: makePR(labels: []), session: makeSession()))
    }

    @Test func refusesWhenTheOneShotGuardIsAlreadyBurnt() {
        // `autoMergeEnabledAt` set means Crow already acted on this session —
        // the guard that stops a second merge attempt.
        #expect(!IssueTracker.shouldDirectMerge(pr: makePR(), session: makeSession(autoMergeEnabledAt: Date())))
    }

    // MARK: - The gates alone, for the enableAutoMerge catch path

    @Test func gatesIgnoreRepoPolicyBecauseTheCallerHasAlreadyProvenIt() {
        // `attemptEnableAutoMerge`'s catch path has just watched the mutation
        // fail with "Auto merge is not allowed for this repository", so it
        // reuses only the green-state half of the predicate.
        #expect(IssueTracker.directMergeGatesPass(
            pr: makePR(repoAutoMergeAllowed: nil), session: makeSession()))
        #expect(!IssueTracker.directMergeGatesPass(
            pr: makePR(checksState: "PENDING", repoAutoMergeAllowed: nil), session: makeSession()))
    }

    // MARK: - Log-string stability

    @Test func skipReasonRawValuesStayGreppable() {
        // These strings are documented in docs/troubleshooting.md and greppable
        // in crowd-automation.log. Folding the six ad-hoc literals into the enum
        // (#888) must not have renamed any of them.
        let expected: Set<String> = [
            "already-enabled", "not-open", "draft", "no-crow-merge-label", "conflicting",
            "changes-requested", "in-flight", "not-in-viewer-prs",
            "update-branch-already-attempted-for-head", "no-crow-session-trailer",
            "backend-lacks-auto-merge-capability", "repo-disallows-auto-merge",
            "repo-disallows-auto-merge-not-yet-mergeable",
            "watcher-off", "direct-merge-failed",
        ]
        let actual = Set([
            IssueTracker.AutoMergeSkipReason.alreadyEnabled, .notOpen, .draft, .noMergeLabel,
            .conflicting, .changesRequested, .inFlight, .notInViewerPRs,
            .updateBranchAlreadyAttempted, .noCrowSessionTrailer, .backendLacksAutoMerge,
            .repoDisallowsAutoMerge, .repoDisallowsAutoMergePending, .watcherOff, .directMergeFailed,
        ].map(\.rawValue))
        #expect(actual == expected)
    }

    /// The regression this case exists to prevent: `crow:merge` is normally
    /// applied while CI is still running, so a repo that forbids auto-merge
    /// must NOT latch a permanent verdict on the first poll — the PR would be
    /// frozen before it could ever qualify for the direct-merge fallback, which
    /// is the headline acceptance criterion of #888.
    @Test func aNotYetGreenPRInADisallowingRepoIsTransientNotPermanent() {
        let reason = IssueTracker.AutoMergeSkipReason.repoDisallowsAutoMergePending
        #expect(!reason.isPermanent)
        let state = reason.state(repo: "corveil/corveil")
        #expect(state?.phase == .stalled)
        // Must promise the fallback, not read as a dead end.
        #expect(state?.message.contains("once checks pass") == true)
    }

    // MARK: - Which reasons reach the UI

    @Test func suppressesReasonsThePRPillAlreadyRenders() {
        // A conflicting PR draws the conflict chip; a CHANGES_REQUESTED one
        // draws a red review chip; an unlabeled one simply has no 🏷. A second
        // chip saying the same thing is the "two surfaces disagreeing" failure
        // CROW-773 consolidated the vocabulary to avoid.
        for reason: IssueTracker.AutoMergeSkipReason in
            [.notOpen, .draft, .noMergeLabel, .conflicting, .changesRequested] {
            #expect(reason.state(repo: "corveil/corveil") == nil,
                    "\(reason.rawValue) is already on screen and must not be re-reported")
        }
    }

    @Test func publishesTheReasonsNothingElseCanTellYou() {
        let published: [IssueTracker.AutoMergeSkipReason: AutoMergeState.Phase] = [
            .alreadyEnabled: .enabled,
            .watcherOff: .off,
            .inFlight: .stalled,
            .notInViewerPRs: .stalled,
            .updateBranchAlreadyAttempted: .stalled,
            .repoDisallowsAutoMergePending: .stalled,
            .noCrowSessionTrailer: .blocked,
            .backendLacksAutoMerge: .blocked,
            .repoDisallowsAutoMerge: .blocked,
            .directMergeFailed: .blocked,
        ]
        for (reason, phase) in published {
            let state = reason.state(repo: "corveil/corveil")
            #expect(state != nil, "\(reason.rawValue) must publish a verdict")
            #expect(state?.phase == phase, "\(reason.rawValue) should publish \(phase.rawValue)")
            #expect(state?.reason == reason.rawValue, "the machine token must match the log string")
            #expect(state?.permanent == reason.isPermanent)
            #expect(!(state?.message.isEmpty ?? true), "\(reason.rawValue) needs a human sentence")
        }
    }

    @Test func onlyBlockedVerdictsArePermanent() {
        // The notification fires on permanence, so a stalled reason marked
        // permanent would chime for something that fixes itself.
        for reason: IssueTracker.AutoMergeSkipReason in
            [.inFlight, .notInViewerPRs, .watcherOff, .repoDisallowsAutoMergePending] {
            #expect(!reason.isPermanent)
        }
        for reason: IssueTracker.AutoMergeSkipReason in
            [.noCrowSessionTrailer, .backendLacksAutoMerge, .repoDisallowsAutoMerge, .directMergeFailed] {
            #expect(reason.isPermanent)
        }
    }

    @Test func theRepoPolicyMessageNamesTheRepoAndTheSetting() {
        // The whole point of the verdict: an actionable sentence, not a token.
        let state = IssueTracker.AutoMergeSkipReason.repoDisallowsAutoMerge
            .state(repo: "corveil/corveil")
        #expect(state?.message.contains("corveil/corveil") == true)
        #expect(state?.message.contains("Allow auto-merge") == true)
    }

    @Test func theRepoPolicyMessageDegradesWithoutARepoSlug() {
        let state = IssueTracker.AutoMergeSkipReason.repoDisallowsAutoMerge.state(repo: "")
        #expect(state?.message.hasPrefix("This repository") == true)
    }
}
