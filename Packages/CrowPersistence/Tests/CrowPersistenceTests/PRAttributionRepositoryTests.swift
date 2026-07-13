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
    mergedAt: Date? = nil
) -> PRSessionAttribution {
    PRSessionAttribution(
        prURL: prURL,
        repoNameWithOwner: repo,
        prNumber: number,
        sessionIDs: sessionIDs,
        state: state,
        mergedAt: mergedAt,
        firstSeenAt: Date(timeIntervalSince1970: 1_752_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_752_000_100)
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
