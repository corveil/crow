import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowDaemon

// MARK: - `backfill-scan` fits the socket cap (CROW-1378)

/// Counts how many times the injected scan ran.
private actor ScanCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Suite struct BackfillScanRPCTests {
    /// A synthetic history big enough that the old one-shot reply is far over
    /// the 1 MB socket cap: long paths, every optional field populated.
    private static func syntheticSessions(_ n: Int) -> [BackfillSession] {
        let harnesses: [LogSyncHarness] = [.claude, .codex, .cursor]
        let confidences: [BackfillConfidence] = [.high, .medium, .low]
        let statuses: [BackfillUploadStatus] = [.new, .uploaded, .failed]
        let pad = String(repeating: "deep-directory-segment/", count: 6)
        return (0..<n).map { i in
            BackfillSession(
                claudeSessionUID: String(format: "%08d-0000-0000-0000-000000000000", i),
                filePath: "/Users/someone/.claude/projects/\(pad)session-\(i).jsonl",
                slug: "-Users-someone-Dev-Corveil-crow-\(i)",
                harness: harnesses[i % 3],
                cwd: "/Users/someone/Dev/Corveil/\(pad)crow-\(i)-a-long-worktree-slug",
                gitBranch: "feature/crow-\(i)-a-long-branch-name",
                modifiedAt: Double(i % 97),  // plenty of ties, exercising the tie-break order
                sizeBytes: 1000 + i,
                workspace: i % 5 == 0 ? nil : (i % 2 == 0 ? "Corveil" : "Other"),
                worktreeName: "crow-\(i)-a-long-worktree-slug",
                repoName: "crow", ownerRepo: "corveil/crow", host: "github.com",
                ticketNumber: i, worktreeExists: i % 2 == 0,
                confidence: confidences[i % 3], uploadStatus: statuses[(i / 3) % 3])
        }
    }

    private static func encodedSize(_ result: [String: JSONValue]) throws -> Int {
        // The real reply wraps the result in a JSON-RPC envelope; leave room for it.
        try JSONEncoder().encode(JSONRPCResponse.success(id: 1, result: result)).count
    }

    private func handler(
        sessions: [BackfillSession], counter: ScanCounter? = nil
    ) -> (CommandRouter.Handler, BackfillScanCache) {
        let cache = BackfillScanCache(scan: {
            await counter?.bump()
            return sessions
        })
        let handlers = makeBackfillHandlers(devRoot: "/nonexistent", scanCache: cache)
        return (handlers["backfill-scan"]!, cache)
    }

    @Test func summaryAndEveryPageFitTheCapAndPagingIsExactlyOnce() async throws {
        let sessions = Self.syntheticSessions(6000)
        // Precondition: the old shape (every row in one reply) would not fit.
        let fullRows = JSONValue.array(try sessions.map { try JSONValue(encoding: $0) })
        #expect(try JSONEncoder().encode(fullRows).count > SocketServer.maxMessageSize)

        let (scan, _) = handler(sessions: sessions)

        let summary = try await scan([:])
        #expect(try Self.encodedSize(summary) < SocketServer.maxMessageSize)
        #expect(summary["view"] == .string("summary"))
        #expect(summary["sessions"] == nil)
        #expect(summary["summary"]?.objectValue?["total"] == .int(6000))
        #expect(summary["breakdown"]?.objectValue?["total"] == .int(6000))
        let scanID = try #require(summary["scan_id"]?.stringValue)

        // Walk at the maximum limit so the byte budget, not the limit, ends pages.
        var seen: [String] = []
        var offset: Int? = 0
        var pages = 0
        var anyTruncated = false
        while let o = offset {
            let page = try await scan([
                "view": .string("sessions"), "scan_id": .string(scanID),
                "offset": .int(o), "limit": .int(1000),
            ])
            #expect(try Self.encodedSize(page) < SocketServer.maxMessageSize)
            #expect(page["paged"] == .bool(true))
            #expect(page["scan_id"] == .string(scanID))
            if page["truncated_by_size"] == .bool(true) { anyTruncated = true }
            let rows = try #require(page["sessions"]?.arrayValue)
            #expect(page["returned"] == .int(rows.count))
            seen += rows.compactMap { row in
                guard let obj = row.objectValue, let h = obj["harness"]?.stringValue,
                      let uid = obj["uid"]?.stringValue else { return nil }
                return "\(h)/\(uid)"
            }
            offset = page["next_offset"]?.intValue
            pages += 1
            #expect(pages < 100)
            if pages >= 100 { break }
        }
        #expect(anyTruncated)
        #expect(seen.count == sessions.count)
        #expect(Set(seen).count == seen.count)
        #expect(Set(seen) == Set(sessions.map { "\($0.harness.rawValue)/\($0.claudeSessionUID)" }))
    }

    @Test func filtersNarrowBothBreakdownAndPages() async throws {
        let sessions = Self.syntheticSessions(300)
        let (scan, _) = handler(sessions: sessions)
        let expected = sessions.filter {
            $0.workspace == "Corveil" && $0.confidence == .high && $0.uploadStatus != .uploaded
        }
        let page = try await scan([
            "view": .string("sessions"), "workspace": .string("corveil"),
            "confidence": .string("high"), "status": .string("not-uploaded"),
            "limit": .int(1000),
        ])
        #expect(page["total_matching"] == .int(expected.count))
        #expect(page["breakdown"]?.objectValue?["total"] == .int(expected.count))
        #expect(page["sessions"]?.arrayValue?.count == expected.count)
        #expect(page["next_offset"] == .null)
        // The whole-scan summary is unfiltered.
        #expect(page["summary"]?.objectValue?["total"] == .int(300))
    }

    @Test func rejectsBadParams() async throws {
        let (scan, _) = handler(sessions: [])
        for params: [String: JSONValue] in [
            ["view": .string("rows")],
            ["confidence": .string("certain")],
            ["status": .string("pending")],
            ["harness": .string("vim")],
            ["limit": .int(-1)],
            ["offset": .string("ten")],
        ] {
            await #expect(throws: (any Error).self) { _ = try await scan(params) }
        }
    }

    @Test func pinnedScanIDExpiresWhenReplacedOrInvalidated() async throws {
        let (scan, cache) = handler(sessions: Self.syntheticSessions(10))
        let first = try #require(try await scan([:])["scan_id"]?.stringValue)
        // Still pinned.
        _ = try await scan(["view": .string("sessions"), "scan_id": .string(first)])

        let second = try #require(try await scan(["refresh": .bool(true)])["scan_id"]?.stringValue)
        #expect(second != first)
        await #expect(throws: (any Error).self) {
            _ = try await scan(["view": .string("sessions"), "scan_id": .string(first)])
        }

        await cache.invalidate()
        await #expect(throws: (any Error).self) {
            _ = try await scan(["view": .string("sessions"), "scan_id": .string(second)])
        }
        await #expect(throws: (any Error).self) {
            _ = try await scan(["scan_id": .string("not-a-scan")])
        }
    }

    @Test func cacheReusesOneScanUntilTTLOrRefresh() async throws {
        let counter = ScanCounter()
        let (scan, _) = handler(sessions: Self.syntheticSessions(5), counter: counter)
        async let a = scan([:])
        async let b = scan([:])
        _ = try await (a, b)
        _ = try await scan(["view": .string("sessions")])
        #expect(await counter.count == 1)
        _ = try await scan(["refresh": .bool(true)])
        #expect(await counter.count == 2)

        // A snapshot past its TTL is re-scanned on the next unpinned call.
        let clock = Clock()
        let expiring = BackfillScanCache(ttl: 60, now: { clock.now }, scan: {
            await counter.bump()
            return []
        })
        _ = await expiring.snapshot(refresh: false)
        clock.now = clock.now.addingTimeInterval(61)
        _ = await expiring.snapshot(refresh: false)
        #expect(await counter.count == 4)
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1000)
}
