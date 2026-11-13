import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// CROW-1453: one session received 637 "Crow detected merge conflicts" prompts
/// for one unchanged PR head, because the per-head latch that was meant to
/// allow one hand-off lived only in memory. A `crowd` restart, a board poll
/// that omitted the PR, or the 15-minute up-to-date re-check each cleared it.
///
/// Sessions use `provider = .jira` and have no worktree, so a dispatched
/// `attemptRebase` can only log `skipped:no-usable-worktree`: it never runs git
/// or `gh`. Whether a poll *dispatched* is read off `autoRebaseInFlight`, which
/// `applyAutoRebase` sets synchronously before the `Task` starts.
@Suite("Auto-rebase conflict hand-off is bounded per head (CROW-1453)")
@MainActor
struct IssueTrackerConflictHandoffTests {
    private static let prURL = "https://github.com/corveil/crow/pull/1453"
    private static let otherPRURL = "https://github.com/corveil/crow/pull/1"
    private static let head = "c0ffee"

    private static func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1453-\(UUID().uuidString)")
    }

    /// A tracker whose session and PR link are in both `appState` and the
    /// store, as they are in a running daemon. Counts the two hooks.
    @MainActor
    private final class Harness {
        let state: AppState
        let store: JSONStore
        let tracker: IssueTracker
        let session: Session
        var conflictPrompts = 0
        var stuckEvents: [AutoRebaseState] = []

        init(directory: URL, session existing: Session? = nil, links: [SessionLink]? = nil) {
            store = JSONStore(directory: directory)
            state = AppState()
            var session = existing ?? Session(name: "feature/x", kind: .work)
            session.provider = .jira
            self.session = session
            state.sessions = [session]
            let sessionLinks = links ?? [
                SessionLink(sessionID: session.id, label: "PR #1453", url: IssueTrackerConflictHandoffTests.prURL,
                            linkType: .pr)
            ]
            state.links[session.id] = sessionLinks
            if links == nil {
                store.mutate { data in
                    data.sessions = [session]
                    data.links = sessionLinks
                }
            }
            tracker = IssueTracker(appState: state, providerManager: ProviderManager(), store: store)
            tracker.autoMergeWatcherEnabledProvider = { false }
            tracker.autoRebaseAndResolveConflictsProvider = { true }
            tracker.onAutoRebaseConflicts = { [unowned self] _, _, _ in self.conflictPrompts += 1 }
            tracker.onAutoRebaseStuck = { [unowned self] _, _, _, s in self.stuckEvents.append(s) }
        }

        var link: SessionLink? { state.links[session.id]?.first { $0.linkType == .pr } }
        var storedLink: SessionLink? { store.data.links.first { $0.linkType == .pr } }

        /// What `attemptRebase` does when `rebaseOntoBase` returns `.conflicts`.
        func conflict(head: String = IssueTrackerConflictHandoffTests.head) {
            let pr = IssueTrackerConflictHandoffTests.conflictingPR(head: head)
            tracker.autoRebase.handleRebaseConflicts(
                headKey: "\(pr.url)\n\(pr.headRefOid)", session: session, pr: pr)
        }

        func poll(_ prs: [PRRecord]) { tracker.applyPRStatuses(viewerPRs: prs) }

        var dispatched: Bool { tracker.autoRebaseInFlight.contains(IssueTrackerConflictHandoffTests.prURL) }
    }

    private static func conflictingPR(
        url: String = prURL, head: String = head, state: String = "OPEN"
    ) -> PRRecord {
        PRRecord(
            number: url == prURL ? 1453 : 1, url: url, state: state,
            mergeable: "CONFLICTING", mergeStateStatus: "DIRTY",
            reviewDecision: "APPROVED", isDraft: false,
            headRefName: "feature/x", headRefOid: head, baseRefName: "main",
            repoNameWithOwner: "corveil/crow", labels: [])
    }

    // MARK: - The cap

    @Test func twoPromptsPerHeadThenEscalate() {
        #expect(AutoRebaseController.maxConflictHandoffsPerHead == 2)
        #expect(AutoRebaseController.conflictHandoffDecision(promptsSentForHead: 0) == .prompt(number: 1))
        #expect(AutoRebaseController.conflictHandoffDecision(promptsSentForHead: 1) == .prompt(number: 2))
        #expect(AutoRebaseController.conflictHandoffDecision(promptsSentForHead: 2) == .escalate(promptsSent: 2))
    }

    @Test func aHandOffIsRecordedOnThePRLinkInAppStateAndTheStore() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()

        #expect(h.conflictPrompts == 1)
        let expected = AutoRebaseConflictHandoff(headRefOid: Self.head, prompts: 1)
        #expect(h.link?.autoRebaseConflictHandoff == expected)
        #expect(h.storedLink?.autoRebaseConflictHandoff == expected)
    }

    @Test func theThirdConflictOnTheSameHeadEscalatesInsteadOfPrompting() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()
        h.conflict()
        h.conflict()

        #expect(h.conflictPrompts == 2)
        #expect(h.stuckEvents.count == 1)
        #expect(h.stuckEvents.first?.reason == "conflicts-unresolved")
        let chip = h.state.autoRebaseState[h.session.id]
        #expect(chip?.phase == .blocked)
        #expect(chip?.permanent == true)
        #expect(h.link?.autoRebaseConflictHandoff?.prompts == 2)

        // Notify-once: a fourth conflict neither prompts nor chimes again.
        h.conflict()
        #expect(h.conflictPrompts == 2)
        #expect(h.stuckEvents.count == 1)
    }

    // MARK: - What used to re-send

    @Test func aPartialPollThatOmitsThePRDoesNotReSend() {
        let h = Harness(directory: Self.tempDir())
        let pr = Self.conflictingPR()
        h.tracker.autoRebaseAttempted.insert("\(Self.prURL)\n\(Self.head)")
        h.conflict()

        // Some PRs, not this one: the in-memory latch is pruned...
        h.poll([Self.conflictingPR(url: Self.otherPRURL, head: "aaaa")])
        #expect(!h.tracker.autoRebaseAttempted.contains("\(Self.prURL)\n\(Self.head)"))

        // ...but the next full poll doesn't rebase or prompt again.
        h.poll([pr])
        #expect(!h.dispatched)
        #expect(h.tracker.autoRebaseAttempted.contains("\(Self.prURL)\n\(Self.head)"))
        #expect(h.conflictPrompts == 1)
    }

    @Test func aRestartDoesNotReSendForTheSameHead() {
        let dir = Self.tempDir()
        let before = Harness(directory: dir)
        before.conflict()
        #expect(before.conflictPrompts == 1)

        // A fresh daemon: new store instance over the same file, new tracker,
        // empty in-memory latches.
        let reloaded = JSONStore(directory: dir).data
        let after = Harness(directory: dir, session: before.session, links: reloaded.links)
        #expect(after.link?.autoRebaseConflictHandoff?.headRefOid == Self.head)

        after.poll([Self.conflictingPR()])
        #expect(!after.dispatched)
        #expect(after.conflictPrompts == 0)
    }

    @Test func aNewHeadSendsAgain() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()

        h.poll([Self.conflictingPR(head: "newhead")])
        #expect(h.dispatched)
        #expect(h.link?.autoRebaseConflictHandoff == nil)
        #expect(h.storedLink?.autoRebaseConflictHandoff == nil)

        h.conflict(head: "newhead")
        #expect(h.conflictPrompts == 2)
        #expect(h.link?.autoRebaseConflictHandoff == AutoRebaseConflictHandoff(headRefOid: "newhead", prompts: 1))
    }

    /// The re-arm the ticket didn't name: a head first latched "already on
    /// base" that later conflicts was re-dispatched by the 15-minute re-check
    /// and re-prompted each time.
    @Test func aConflictDropsTheUpToDateRecheckForThatHead() {
        let h = Harness(directory: Self.tempDir())
        let key = "\(Self.prURL)\n\(Self.head)"
        h.tracker.autoRebaseUpToDateHeads[key] = AutoRebaseController.AutoRebaseUpToDateHead(
            mergeStateStatus: "BLOCKED", recheckAt: .distantPast)
        h.conflict()
        #expect(h.tracker.autoRebaseUpToDateHeads[key] == nil)
    }

    // MARK: - What clears the record

    @Test func aMergedOrClosedPRClearsTheRecord() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()
        h.poll([Self.conflictingPR(state: "MERGED")])
        #expect(h.link?.autoRebaseConflictHandoff == nil)
        #expect(h.storedLink?.autoRebaseConflictHandoff == nil)
    }

    @Test func turningTheSettingOffClearsTheRecord() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()
        h.tracker.autoRebaseAndResolveConflictsProvider = { false }
        h.poll([Self.conflictingPR()])
        #expect(h.link?.autoRebaseConflictHandoff == nil)
        #expect(h.storedLink?.autoRebaseConflictHandoff == nil)
    }

    @Test func theOperatorsRebaseAndFixConflictsClearsTheRecord() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()
        h.conflict()
        h.tracker.clearAutoRebaseConflictHandoff(sessionID: h.session.id)
        #expect(h.link?.autoRebaseConflictHandoff == nil)
        #expect(h.storedLink?.autoRebaseConflictHandoff == nil)

        // The count starts again.
        h.conflict()
        #expect(h.conflictPrompts == 3)
    }

    @Test func aStillConflictingPollOnTheSameHeadKeepsTheRecord() {
        let h = Harness(directory: Self.tempDir())
        h.conflict()
        h.poll([Self.conflictingPR()])
        #expect(h.link?.autoRebaseConflictHandoff == AutoRebaseConflictHandoff(headRefOid: Self.head, prompts: 1))
    }

    // MARK: - Persistence shape

    @Test func olderStoreFilesWithoutTheFieldStillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sessionID":"\(UUID().uuidString)",\
        "label":"PR #1","url":"\(Self.prURL)","linkType":"pr"}
        """
        let link = try JSONDecoder().decode(SessionLink.self, from: Data(json.utf8))
        #expect(link.autoRebaseConflictHandoff == nil)
    }
}
