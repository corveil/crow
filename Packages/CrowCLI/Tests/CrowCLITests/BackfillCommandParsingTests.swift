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
