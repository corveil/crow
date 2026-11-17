import Foundation
import Testing
import ArgumentParser
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

// MARK: - `crow backfill scan --output` (CROW-1462)

@Test func backfillScanParsesOutput() throws {
    #expect(try BackfillScan.parse([]).output == nil)
    #expect(try BackfillScan.parse(["--output", "rows.json"]).output == "rows.json")
}

@Test func backfillScanResolvesOutputToAnAbsolutePath() {
    let now = Date(timeIntervalSince1970: 1_763_400_000) // 2025-11-17T17:20:00Z
    // The daemon runs elsewhere, so a relative path is resolved against the CLI's cwd.
    #expect(BackfillScan.outputPath("rows.json", cwd: "/work/dir", tmpDir: "/t", now: now)
            == "/work/dir/rows.json")
    #expect(BackfillScan.outputPath("../out/rows.json", cwd: "/work/dir", tmpDir: "/t", now: now)
            == "/work/out/rows.json")
    #expect(BackfillScan.outputPath("/abs/rows.json", cwd: "/work/dir", tmpDir: "/t", now: now)
            == "/abs/rows.json")
    #expect(BackfillScan.outputPath("~/rows.json", cwd: "/work/dir", tmpDir: "/t", now: now)
            == (NSHomeDirectory() as NSString).appendingPathComponent("rows.json"))
}

@Test func backfillScanDefaultsToATimestampedFileUnderTmpDir() {
    let now = Date(timeIntervalSince1970: 1_763_400_000)
    #expect(BackfillScan.outputPath(nil, cwd: "/work", tmpDir: "/var/tmp/x/", now: now)
            == "/var/tmp/x/crow-backfill-scan-20251117T172000Z.json")
    #expect(BackfillScan.outputPath("", cwd: "/work", tmpDir: "/t", now: now)
            == "/t/crow-backfill-scan-20251117T172000Z.json")
}
