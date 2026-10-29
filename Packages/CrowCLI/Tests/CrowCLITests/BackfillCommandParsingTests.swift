import Foundation
import Testing
import ArgumentParser
import CrowIPC
@testable import CrowCLILib

// MARK: - `crow backfill` parsing (CROW-1075)

@Test func backfillRoutesToSubcommands() throws {
    #expect(try Backfill.parseAsRoot(["scan"]) is BackfillScan)
    #expect(try Backfill.parseAsRoot(["upload", "--workspace", "R", "--all"]) is BackfillUpload)
}

@Test func backfillUploadParsesExplicitSessions() throws {
    let cmd = try BackfillUpload.parse(["--workspace", "RadiusMethod", "--session", "a", "--session", "b"])
    #expect(cmd.workspace == "RadiusMethod")
    #expect(cmd.sessions == ["a", "b"])
    #expect(cmd.allHighConfidence == false)
    #expect(cmd.all == false)
}

@Test func backfillUploadParsesBulkFlags() throws {
    let hi = try BackfillUpload.parse(["--workspace", "R", "--all-high-confidence"])
    #expect(hi.allHighConfidence == true)
    let all = try BackfillUpload.parse(["--workspace", "R", "--all"])
    #expect(all.all == true)
}

@Test func backfillUploadRequiresExactlyOneSelectionMode() {
    // None.
    #expect(throws: (any Error).self) {
        _ = try BackfillUpload.parse(["--workspace", "R"])
    }
    // Two at once.
    #expect(throws: (any Error).self) {
        _ = try BackfillUpload.parse(["--workspace", "R", "--all", "--all-high-confidence"])
    }
    #expect(throws: (any Error).self) {
        _ = try BackfillUpload.parse(["--workspace", "R", "--session", "a", "--all"])
    }
}

@Test func backfillUploadRequiresWorkspace() {
    #expect(throws: (any Error).self) {
        _ = try BackfillUpload.parse(["--all"])
    }
    #expect(throws: (any Error).self) {
        _ = try BackfillUpload.parse(["--workspace", "   ", "--all"])
    }
}

// MARK: - `crow backfill scan` summary / paging (CROW-1378)

@Test func backfillScanDefaultsToSummary() throws {
    let cmd = try BackfillScan.parse([])
    #expect(cmd.params == ["view": .string("summary")])
}

@Test func backfillScanParsesPagingAndFilters() throws {
    let cmd = try BackfillScan.parse([
        "--sessions", "--limit", "50", "--offset", "100", "--scan-id", "abc",
        "--workspace", "Corveil", "--confidence", "HIGH", "--status", "not-uploaded",
        "--harness", "codex",
    ])
    #expect(cmd.params == [
        "view": .string("sessions"), "limit": .int(50), "offset": .int(100),
        "scan_id": .string("abc"), "workspace": .string("Corveil"),
        "confidence": .string("high"), "status": .string("not-uploaded"),
        "harness": .string("codex"),
    ])
    #expect(try BackfillScan.parse(["--refresh"]).params["refresh"] == .bool(true))
}

@Test func backfillScanRejectsBadFlags() {
    for args in [
        ["--confidence", "certain"],
        ["--status", "pending"],
        ["--sessions", "--limit", "0"],
        ["--sessions", "--offset", "-1"],
        ["--limit", "10"],                       // paging without --sessions
        ["--scan-id", "abc", "--refresh"],
    ] {
        #expect(throws: (any Error).self) { _ = try BackfillScan.parse(args) }
    }
}

@Test func backfillScanNoteSaysSummarizedOrPaged() {
    let summary = BackfillScan.note(
        for: ["view": .string("summary"), "total_matching": .int(1234)], filterArgs: [])
    #expect(summary?.contains("summary only (1234 matching sessions)") == true)

    let page = BackfillScan.note(for: [
        "paged": .bool(true), "total_matching": .int(1234), "offset": .int(200),
        "returned": .int(200), "next_offset": .int(400), "scan_id": .string("S1"),
    ], filterArgs: ["--workspace", "My WS"])
    #expect(page == "showing rows 201–400 of 1234; next page: crow backfill scan --sessions --scan-id S1 --offset 400 --workspace 'My WS'")

    let last = BackfillScan.note(for: [
        "paged": .bool(true), "total_matching": .int(3), "offset": .int(0),
        "returned": .int(3), "next_offset": .null, "scan_id": .string("S1"),
    ], filterArgs: [])
    #expect(last == "showing rows 1–3 of 3 (last page).")
}
