import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import Crow

/// Rework / merge-rate signal capture (#694, ADR 0008 follow-up 6).
/// Mirrors `IssueTrackerPRAttributionTests`: a real `IssueTracker` over a
/// temp-dir `JSONStore`, explicit `now:` values (no timing dependence),
/// reads back through the store / `PRAttributionRepository`.
@MainActor
@Suite("IssueTracker rework / merge-rate metrics")
struct IssueTrackerReworkTests {

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-rework-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private func makeTracker(store: JSONStore) -> IssueTracker {
        IssueTracker(appState: AppState(), providerManager: ProviderManager(), store: store)
    }

    private func makePR(
        url: String = "https://github.com/corveil/crow/pull/42",
        number: Int = 42,
        state: String = "OPEN",
        repo: String = "corveil/crow",
        mergeCommitOid: String? = nil
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: number,
            url: url,
            state: state,
            repoNameWithOwner: repo,
            mergeCommitOid: mergeCommitOid
        )
    }

    private func trailer(for uuid: UUID) -> String {
        "feat: thing\n\nCrow-Session: \(uuid.uuidString)\n"
    }

    private func seed(_ store: JSONStore, _ attributions: [PRSessionAttribution]) {
        store.mutate { data in
            data.prAttributions = Dictionary(uniqueKeysWithValues: attributions.map { ($0.prURL, $0) })
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_752_000_600)
    private let t2 = Date(timeIntervalSince1970: 1_752_001_200)

    // MARK: - extractRevertedCommitSHAs

    @Test func extractsRevertTargetFromConventionalBodyLine() {
        let message = """
        Revert "feat: thing"

        This reverts commit 0123456789abcdef0123456789abcdef01234567.
        """
        #expect(IssueTracker.extractRevertedCommitSHAs(from: message)
            == ["0123456789abcdef0123456789abcdef01234567"])
    }

    @Test func extractsMultipleTargetsAndAbbreviatedSHAs() {
        let message = """
        Revert two things

        This reverts commit aabbccd.
        This reverts commit 1122334455667788990011223344556677889900.
        """
        #expect(IssueTracker.extractRevertedCommitSHAs(from: message)
            == ["aabbccd", "1122334455667788990011223344556677889900"])
    }

    @Test func rejectsShortSHAsMidLineMentionsAndPlainMessages() {
        // 6 chars is below git's abbreviation floor.
        #expect(IssueTracker.extractRevertedCommitSHAs(from: "This reverts commit abc123.").isEmpty)
        // Line anchor: a quoted mention mid-line is not a revert declaration.
        #expect(IssueTracker.extractRevertedCommitSHAs(
            from: "see the note: This reverts commit 0123456789abcdef.").isEmpty)
        #expect(IssueTracker.extractRevertedCommitSHAs(from: "fix: normal commit").isEmpty)
    }

    // MARK: - shaMatches

    @Test func shaMatchingIsPrefixTolerantCaseInsensitiveAndFloored() {
        #expect(IssueTracker.shaMatches("aabbccd", "aabbccd0123456789"))
        #expect(IssueTracker.shaMatches("AABBCCD0123456789", "aabbccd"))
        #expect(!IssueTracker.shaMatches("aabbcc", "aabbcc0123456789"))   // 6 < floor
        #expect(!IssueTracker.shaMatches("aabbccd", "aabbcce0123456789"))
    }

    // MARK: - Revert detection

    @Test func revertOfMergeCommitIsDetectedAndAttributedToOriginatingSession() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let sessionID = UUID()
        let mergeSHA = "0123456789abcdef0123456789abcdef01234567"
        let pr = makePR()

        // Session-attributed PR merges; the squash SHA is captured.
        tracker.recordPRAttribution(pr: pr, commits: [CommitInfo(sha: "feed123", message: trailer(for: sessionID))], now: t0)
        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED", mergeCommitOid: mergeSHA)], now: t1)

        // A revert PR's commit fetch sees the conventional revert line.
        let revertPR = makePR(url: "https://github.com/corveil/crow/pull/43", number: 43)
        tracker.recordPRAttribution(
            pr: revertPR,
            commits: [CommitInfo(sha: "beef4567890", message: "Revert \"feat: thing\"\n\nThis reverts commit \(mergeSHA).")],
            now: t2)

        let reverts = store.data.prAttributions?[pr.url]?.reverts
        #expect(reverts?.count == 1)
        #expect(reverts?.first?.revertedCommitSHA == mergeSHA)
        #expect(reverts?.first?.revertCommitSHA == "beef4567890")
        #expect(reverts?.first?.sourcePRURL == revertPR.url)

        // The signal reaches the originating session's read values.
        let metrics = PRAttributionRepository(store: store)
            .reworkMetrics(for: sessionID, in: DateInterval(start: t0, end: t2.addingTimeInterval(60)))
        #expect(metrics.revertCount == 1)
    }

    @Test func revertOfBranchCommitIsDetectedViaStoredCommitSHAs() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let branchSHA = "fedcba9876543210fedcba9876543210fedcba98"
        let pr = makePR()
        tracker.recordPRAttribution(pr: pr, commits: [CommitInfo(sha: branchSHA, message: trailer(for: UUID()))], now: t0)

        let revertPR = makePR(url: "https://github.com/corveil/crow/pull/43", number: 43)
        tracker.recordPRAttribution(
            pr: revertPR,
            commits: [CommitInfo(sha: "beef4567890", message: "This reverts commit fedcba987654321.")],
            now: t1)

        #expect(store.data.prAttributions?[pr.url]?.reverts?.first?.revertedCommitSHA == "fedcba987654321")
    }

    @Test func sameRevertSeenThroughBothPathsStampsOnce() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let mergeSHA = "0123456789abcdef0123456789abcdef01234567"
        let pr = makePR()
        tracker.recordPRAttribution(pr: pr, commits: [CommitInfo(sha: "feed123", message: trailer(for: UUID()))], now: t0)
        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED", mergeCommitOid: mergeSHA)], now: t0)

        // Path A: the revert PR's own commit.
        let revertPR = makePR(url: "https://github.com/corveil/crow/pull/43", number: 43)
        tracker.recordPRAttribution(
            pr: revertPR,
            commits: [CommitInfo(sha: "beef4567890", message: "This reverts commit \(mergeSHA).")],
            now: t1)
        // Path B equivalent: the revert PR's squash commit on the default
        // branch carries the same target — must dedupe, not double-stamp.
        let detections = IssueTracker.revertDetections(
            commits: [CommitInfo(sha: "5quash9876543", message: "Revert (#43)\n\nThis reverts commit \(mergeSHA).")],
            attributions: store.data.prAttributions ?? [:],
            repo: "corveil/crow",
            excludingPRURL: nil,
            sourcePRURL: nil,
            now: t2)

        #expect(detections.isEmpty)
        #expect(store.data.prAttributions?[pr.url]?.reverts?.count == 1)
    }

    @Test func revertOfUnattributedCommitStampsNothing() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let pr = makePR()
        tracker.recordPRAttribution(pr: pr, commits: [CommitInfo(sha: "feed1234", message: trailer(for: UUID()))], now: t0)

        let revertPR = makePR(url: "https://github.com/corveil/crow/pull/43", number: 43)
        tracker.recordPRAttribution(
            pr: revertPR,
            commits: [CommitInfo(sha: "beef4567890", message: "This reverts commit 9999999999999999999999999999999999999999.")],
            now: t1)

        #expect(store.data.prAttributions?[pr.url]?.reverts == nil)
    }

    @Test func inPRSelfRevertIsInternalChurnNotRework() {
        // A PR that reverts one of its own commits (the reverting commit is
        // in the attribution's own SHA set) must not stamp itself.
        let store = Self.tempStore()
        let attribution = PRSessionAttribution(
            prURL: "https://github.com/corveil/crow/pull/50",
            repoNameWithOwner: "corveil/crow",
            prNumber: 50,
            sessionIDs: [UUID()],
            state: "MERGED",
            mergedAt: t0,
            firstSeenAt: t0,
            updatedAt: t0,
            commitSHAs: ["aaaa11122233", "bbbb44455566"],
            mergeCommitSHA: "cccc77788899900"
        )
        seed(store, [attribution])

        // The squash commit (its own mergeCommitSHA) contains an internal
        // revert of one of its own branch commits.
        let detections = IssueTracker.revertDetections(
            commits: [CommitInfo(sha: "cccc77788899900", message: "feat (#50)\n\nThis reverts commit aaaa11122233.")],
            attributions: store.data.prAttributions ?? [:],
            repo: "corveil/crow",
            excludingPRURL: nil,
            sourcePRURL: nil,
            now: t1)

        #expect(detections.isEmpty)
    }

    // MARK: - mergeCommitSHA / closedAt / commitSHAs capture

    @Test func mergeCommitSHAAndClosedAtStampOnceAndNeverMove() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let pr = makePR()
        tracker.recordPRAttribution(pr: pr, commits: [CommitInfo(sha: "feed123", message: trailer(for: UUID()))], now: t0)

        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED", mergeCommitOid: "0123456789ab")], now: t1)
        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED", mergeCommitOid: "fffffffffff")], now: t2)
        #expect(store.data.prAttributions?[pr.url]?.mergeCommitSHA == "0123456789ab")

        let closedPR = makePR(url: "https://github.com/corveil/crow/pull/44", number: 44)
        tracker.recordPRAttribution(pr: closedPR, commits: [CommitInfo(sha: "aa11bb22", message: trailer(for: UUID()))], now: t0)
        tracker.updatePRAttributions(viewerPRs: [makePR(url: closedPR.url, number: 44, state: "CLOSED")], now: t1)
        tracker.updatePRAttributions(viewerPRs: [makePR(url: closedPR.url, number: 44, state: "CLOSED")], now: t2)
        let closed = store.data.prAttributions?[closedPR.url]
        #expect(closed?.closedAt == t1)
        #expect(closed?.mergedAt == nil)
    }

    @Test func commitSHAsAreMonotonicDedupedAndCapped() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let sessionID = UUID()
        let pr = makePR()

        tracker.recordPRAttribution(pr: pr, commits: [
            CommitInfo(sha: "aaaa1112223", message: trailer(for: sessionID)),
            CommitInfo(sha: "aaaa1112223", message: "dup"),
            CommitInfo(sha: "", message: "empty sha ignored"),
        ], now: t0)
        // A rebase replaced the branch commits; old SHAs must survive.
        tracker.recordPRAttribution(pr: pr, commits: [CommitInfo(sha: "bbbb4445556", message: trailer(for: sessionID))], now: t1)
        #expect(store.data.prAttributions?[pr.url]?.commitSHAs == ["aaaa1112223", "bbbb4445556"])

        let flood = (0..<(IssueTracker.maxStoredCommitSHAs + 50)).map {
            CommitInfo(sha: String(format: "%040d", $0), message: "c\($0)")
        }
        tracker.recordPRAttribution(pr: pr, commits: flood, now: t2)
        #expect(store.data.prAttributions?[pr.url]?.commitSHAs?.count == IssueTracker.maxStoredCommitSHAs)
    }

    // MARK: - Post-merge-fix detection

    private func mergedAttribution(
        url: String,
        number: Int,
        sessionID: UUID = UUID(),
        firstSeenAt: Date,
        mergedAt: Date?,
        files: [String]?,
        repo: String = "corveil/crow"
    ) -> PRSessionAttribution {
        PRSessionAttribution(
            prURL: url,
            repoNameWithOwner: repo,
            prNumber: number,
            sessionIDs: [sessionID],
            state: mergedAt != nil ? "MERGED" : "OPEN",
            mergedAt: mergedAt,
            firstSeenAt: firstSeenAt,
            updatedAt: firstSeenAt,
            changedFiles: files
        )
    }

    @Test func fixMergedWithinWindowTouchingSameFilesStampsTheFixedPR() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let sessionID = UUID()
        let a = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/1", number: 1, sessionID: sessionID,
            firstSeenAt: t0, mergedAt: t0, files: ["Sources/App/Foo.swift", "README.md"])
        // Same-session follow-up: still rework (rule 5).
        let b = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/2", number: 2, sessionID: sessionID,
            firstSeenAt: t1, mergedAt: t2, files: ["Sources/App/Foo.swift"])
        seed(store, [a, b])

        tracker.detectPostMergeFixes(now: t2)

        let fixes = store.data.prAttributions?[a.prURL]?.postMergeFixes
        #expect(fixes?.count == 1)
        #expect(fixes?.first?.fixPRURL == b.prURL)
        #expect(fixes?.first?.overlappingFileCount == 1)
        // The fix PR itself gains nothing — the signal belongs to the PR
        // that needed fixing.
        #expect(store.data.prAttributions?[b.prURL]?.postMergeFixes == nil)
        // Re-running must not duplicate.
        tracker.detectPostMergeFixes(now: t2.addingTimeInterval(60))
        #expect(store.data.prAttributions?[a.prURL]?.postMergeFixes?.count == 1)

        let metrics = PRAttributionRepository(store: store)
            .reworkMetrics(for: sessionID, in: DateInterval(start: t0, end: t2.addingTimeInterval(120)))
        #expect(metrics.postMergeFixCount == 1)
    }

    @Test func fixOutsideWindowOrWithoutOverlapOrPredatingMergeDoesNotStamp() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let a = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/1", number: 1,
            firstSeenAt: t0, mergedAt: t0, files: ["Foo.swift"])
        let lateFix = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/2", number: 2,
            firstSeenAt: t1, mergedAt: t0.addingTimeInterval(IssueTracker.postMergeFixWindow + 60),
            files: ["Foo.swift"])
        let noOverlap = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/3", number: 3,
            firstSeenAt: t1, mergedAt: t2, files: ["Bar.swift"])
        let stacked = mergedAttribution(   // first seen BEFORE a merged
            url: "https://github.com/corveil/crow/pull/4", number: 4,
            firstSeenAt: t0.addingTimeInterval(-600), mergedAt: t2, files: ["Foo.swift"])
        let unmergedTouch = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/5", number: 5,
            firstSeenAt: t1, mergedAt: nil, files: ["Foo.swift"])
        seed(store, [a, lateFix, noOverlap, stacked, unmergedTouch])

        tracker.detectPostMergeFixes(now: t2)

        #expect(store.data.prAttributions?[a.prURL]?.postMergeFixes == nil)
    }

    @Test func revertPRIsNeverAlsoCountedAsPostMergeFix() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        var a = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/1", number: 1,
            firstSeenAt: t0, mergedAt: t0, files: ["Foo.swift"])
        a.reverts = [PRRevertRecord(
            revertedCommitSHA: "0123456789ab",
            revertCommitSHA: "beef4567890",
            sourcePRURL: "https://github.com/corveil/crow/pull/2",
            detectedAt: t1)]
        let revertPR = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/2", number: 2,
            firstSeenAt: t1, mergedAt: t2, files: ["Foo.swift"])
        seed(store, [a, revertPR])

        tracker.detectPostMergeFixes(now: t2)

        #expect(store.data.prAttributions?[a.prURL]?.postMergeFixes == nil)
    }
}
