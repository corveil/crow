import Foundation
import Testing
@testable import CrowPersistence
@testable import CrowCore

// #693 (ADR 0008 follow-up 5): durable PR→session attribution store —
// round-trip persistence, forward compat, delete-cascade exclusion, and
// the merged-PR-per-window rollup.

private func makeAttribution(
    prURL: String = "https://github.com/corveil/crow/pull/42",
    repo: String = "corveil/crow",
    number: Int = 42,
    sessionIDs: [UUID],
    state: String = "OPEN",
    mergedAt: Date? = nil,
    closedAt: Date? = nil,
    reverts: [PRRevertRecord]? = nil,
    postMergeFixes: [PostMergeFixRecord]? = nil
) -> PRSessionAttribution {
    PRSessionAttribution(
        prURL: prURL,
        repoNameWithOwner: repo,
        prNumber: number,
        sessionIDs: sessionIDs,
        state: state,
        mergedAt: mergedAt,
        firstSeenAt: Date(timeIntervalSince1970: 1_752_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_752_000_100),
        closedAt: closedAt,
        reverts: reverts,
        postMergeFixes: postMergeFixes
    )
}

@Test func attributionPersistsAcrossRelaunch() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = UUID()
    let attribution = makeAttribution(
        sessionIDs: [sessionID],
        state: "MERGED",
        mergedAt: Date(timeIntervalSince1970: 1_752_100_000)
    )
    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.prAttributions = [attribution.prURL: attribution]
    }

    // A new store over the same directory simulates an app relaunch.
    let reloaded = JSONStore(directory: dir)
    let repo = PRAttributionRepository(store: reloaded)
    #expect(repo.attribution(prURL: attribution.prURL) == attribution)
    #expect(repo.attributions(for: sessionID) == [attribution])
}

@Test func storeWithoutAttributionKeyDecodesCleanly() throws {
    // Older store.json files predate the prAttributions key; decoding must
    // leave the field nil and every other field intact.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let legacy = """
    {
      "sessions": [],
      "worktrees": [],
      "links": [],
      "terminals": []
    }
    """
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try legacy.write(to: dir.appendingPathComponent("store.json"), atomically: true, encoding: .utf8)

    let store = JSONStore(directory: dir)
    #expect(store.data.prAttributions == nil)
    #expect(store.data.sessions.isEmpty)
    let repo = PRAttributionRepository(store: store)
    #expect(repo.attribution(prURL: "https://example.com/pr/1") == nil)
    #expect(repo.mergedPRCount(for: UUID(), in: DateInterval(start: .distantPast, end: .distantFuture)) == 0)
}

// Like analyticsSnapshots (#690), attribution records are scorecard history
// and must survive the retention reaper deleting the session.
@Test func deleteDoesNotCascadePRAttributions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let sessionRepo = SessionRepository(store: store)

    let sessionID = UUID()
    sessionRepo.save(Session(id: sessionID, name: "reaped"))
    let attribution = makeAttribution(sessionIDs: [sessionID])
    store.mutate { data in
        data.prAttributions = [attribution.prURL: attribution]
    }

    sessionRepo.delete(id: sessionID)

    #expect(sessionRepo.find(id: sessionID) == nil)
    #expect(store.data.prAttributions?[attribution.prURL] == attribution)
}

@Test func mergedPRCountFiltersBySessionStateAndWindow() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = UUID()
    let otherSession = UUID()
    let window = DateInterval(
        start: Date(timeIntervalSince1970: 1_752_000_000),
        end: Date(timeIntervalSince1970: 1_752_604_800)
    )
    let insideWindow = window.start.addingTimeInterval(3_600)

    let counted = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/1", number: 1,
        sessionIDs: [sessionID], state: "MERGED", mergedAt: insideWindow)
    let mergedOutsideWindow = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/2", number: 2,
        sessionIDs: [sessionID], state: "MERGED",
        mergedAt: window.end.addingTimeInterval(3_600))
    let stillOpen = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/3", number: 3,
        sessionIDs: [sessionID], state: "OPEN")
    let otherSessionsPR = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/4", number: 4,
        sessionIDs: [otherSession], state: "MERGED", mergedAt: insideWindow)

    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.prAttributions = Dictionary(
            uniqueKeysWithValues: [counted, mergedOutsideWindow, stillOpen, otherSessionsPR].map { ($0.prURL, $0) })
    }

    let repo = PRAttributionRepository(store: store)
    #expect(repo.mergedPRCount(for: sessionID, in: window) == 1)
    #expect(repo.mergedPRCount(for: otherSession, in: window) == 1)
    #expect(repo.mergedPRCount(for: UUID(), in: window) == 0)
}

@Test func multiSessionPRCountsForEachSession() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = UUID()
    let b = UUID()
    let window = DateInterval(
        start: Date(timeIntervalSince1970: 1_752_000_000),
        end: Date(timeIntervalSince1970: 1_752_604_800)
    )
    let attribution = makeAttribution(
        sessionIDs: [a, b], state: "MERGED",
        mergedAt: window.start.addingTimeInterval(60))

    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.prAttributions = [attribution.prURL: attribution]
    }

    let repo = PRAttributionRepository(store: store)
    #expect(repo.mergedPRCount(for: a, in: window) == 1)
    #expect(repo.mergedPRCount(for: b, in: window) == 1)
    #expect(repo.attributions(for: a) == [attribution])
    #expect(repo.attributions(for: b) == [attribution])
}

// MARK: - reworkMetrics (#694, ADR 0008 follow-up 6)

@Test func mergeRateIsMergedOverResolved() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = UUID()
    let window = DateInterval(
        start: Date(timeIntervalSince1970: 1_752_000_000),
        end: Date(timeIntervalSince1970: 1_752_604_800)
    )
    let inWindow = window.start.addingTimeInterval(3_600)

    var attributions: [PRSessionAttribution] = (1...3).map { n in
        makeAttribution(
            prURL: "https://github.com/corveil/crow/pull/\(n)", number: n,
            sessionIDs: [sessionID], state: "MERGED", mergedAt: inWindow)
    }
    attributions.append(makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/4", number: 4,
        sessionIDs: [sessionID], state: "CLOSED", closedAt: inWindow))

    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.prAttributions = Dictionary(uniqueKeysWithValues: attributions.map { ($0.prURL, $0) })
    }

    let metrics = PRAttributionRepository(store: store).reworkMetrics(for: sessionID, in: window)
    #expect(metrics.mergedCount == 3)
    #expect(metrics.closedWithoutMergeCount == 1)
    #expect(metrics.mergeRate == 0.75)
    #expect(metrics.revertCount == 0)
    #expect(metrics.postMergeFixCount == 0)
}

@Test func sessionWithNoAttributedPRsIsNeutral() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let metrics = PRAttributionRepository(store: store)
        .reworkMetrics(for: UUID(), in: DateInterval(start: .distantPast, end: .distantFuture))
    #expect(metrics == SessionReworkMetrics(
        mergedCount: 0, closedWithoutMergeCount: 0, mergeRate: nil,
        revertCount: 0, postMergeFixCount: 0))
}

@Test func reworkMetricsWindowAndStateFiltering() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = UUID()
    let window = DateInterval(
        start: Date(timeIntervalSince1970: 1_752_000_000),
        end: Date(timeIntervalSince1970: 1_752_604_800)
    )
    let inWindow = window.start.addingTimeInterval(3_600)
    let beforeWindow = window.start.addingTimeInterval(-3_600)

    // Reopened after closing: closedAt is stamped but current state is
    // OPEN — must not count as closed-without-merge.
    let reopened = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/1", number: 1,
        sessionIDs: [sessionID], state: "OPEN", closedAt: inWindow)
    // Closed outside the window: not counted.
    let closedEarly = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/2", number: 2,
        sessionIDs: [sessionID], state: "CLOSED", closedAt: beforeWindow)
    // Revert/fix records windowed by detectedAt.
    let reverted = makeAttribution(
        prURL: "https://github.com/corveil/crow/pull/3", number: 3,
        sessionIDs: [sessionID], state: "MERGED", mergedAt: inWindow,
        reverts: [
            PRRevertRecord(revertedCommitSHA: "aaaa1112223", revertCommitSHA: "bbbb4445556", detectedAt: inWindow),
            PRRevertRecord(revertedCommitSHA: "cccc7778889", revertCommitSHA: "dddd0001112", detectedAt: beforeWindow),
        ],
        postMergeFixes: [
            PostMergeFixRecord(fixPRURL: "https://github.com/corveil/crow/pull/9", overlappingFileCount: 2, detectedAt: inWindow),
            PostMergeFixRecord(fixPRURL: "https://github.com/corveil/crow/pull/10", overlappingFileCount: 1, detectedAt: beforeWindow),
        ])

    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.prAttributions = Dictionary(
            uniqueKeysWithValues: [reopened, closedEarly, reverted].map { ($0.prURL, $0) })
    }

    let metrics = PRAttributionRepository(store: store).reworkMetrics(for: sessionID, in: window)
    #expect(metrics.mergedCount == 1)
    #expect(metrics.closedWithoutMergeCount == 0)
    #expect(metrics.mergeRate == 1.0)
    #expect(metrics.revertCount == 1)
    #expect(metrics.postMergeFixCount == 1)
}

@Test func legacyAttributionWithoutReworkKeysDecodesCleanly() throws {
    // #693-era records predate every #694 field; decoding must leave them
    // nil and the metrics neutral-but-correct.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = UUID()
    let legacy = """
    {
      "sessions": [], "worktrees": [], "links": [], "terminals": [],
      "prAttributions": {
        "https://github.com/corveil/crow/pull/7": {
          "prURL": "https://github.com/corveil/crow/pull/7",
          "repoNameWithOwner": "corveil/crow",
          "prNumber": 7,
          "sessionIDs": ["\(sessionID.uuidString)"],
          "state": "MERGED",
          "mergedAt": "2026-07-08T12:00:00Z",
          "firstSeenAt": "2026-07-08T09:00:00Z",
          "updatedAt": "2026-07-08T12:00:00Z"
        }
      }
    }
    """
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try legacy.write(to: dir.appendingPathComponent("store.json"), atomically: true, encoding: .utf8)

    let store = JSONStore(directory: dir)
    let attribution = store.data.prAttributions?.values.first
    #expect(attribution?.commitSHAs == nil)
    #expect(attribution?.mergeCommitSHA == nil)
    #expect(attribution?.closedAt == nil)
    #expect(attribution?.changedFiles == nil)
    #expect(attribution?.reverts == nil)
    #expect(attribution?.postMergeFixes == nil)

    let metrics = PRAttributionRepository(store: store)
        .reworkMetrics(for: sessionID, in: DateInterval(start: .distantPast, end: .distantFuture))
    #expect(metrics.mergedCount == 1)
    #expect(metrics.mergeRate == 1.0)
    #expect(metrics.revertCount == 0)
}
