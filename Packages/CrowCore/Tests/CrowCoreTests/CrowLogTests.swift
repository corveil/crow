import Foundation
import Testing
@testable import CrowCore

/// `CrowLog` is the durable automation log added for CROW-782. Every test here
/// points the sink at a fresh temp directory (ADR 0012 — tests never write to
/// the live `~/Library/Logs/crow`) and restores the default afterwards.
@Suite(.serialized)
struct CrowLogTests {
    private func withTempLogDirectory(_ body: (URL) throws -> Void) rethrows {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-test-crowlog-\(UUID().uuidString)", isDirectory: true)
        CrowLog.configure(directory: dir)
        defer {
            CrowLog.configure(directory: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    @Test func automationAppendsTimestampedLines() throws {
        try withTempLogDirectory { dir in
            CrowLog.automation("auto-merge: enabled=1 skipped=0")
            CrowLog.automation("auto-rebase: candidates=0")

            let contents = try String(contentsOf: CrowLog.fileURL, encoding: .utf8)
            let lines = contents.split(separator: "\n").map(String.init)
            #expect(lines.count == 2)
            #expect(lines[0].hasSuffix("[automation] auto-merge: enabled=1 skipped=0"))
            #expect(lines[1].hasSuffix("[automation] auto-rebase: candidates=0"))
            // Leading ISO8601 timestamp, so lines sort chronologically.
            #expect(lines[0].hasPrefix("2"))
            #expect(CrowLog.fileURL.deletingLastPathComponent() == dir)
        }
    }

    @Test func fileURLLivesUnderTheConfiguredDirectory() throws {
        try withTempLogDirectory { dir in
            #expect(CrowLog.fileURL == dir.appendingPathComponent("crowd-automation.log"))
        }
    }

    @Test func oversizedLogRotatesToASingleGeneration() throws {
        try withTempLogDirectory { _ in
            let url = CrowLog.fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Seed a file past the cap so the next append rotates it.
            let filler = String(repeating: "x", count: CrowLog.maxBytes + 1)
            try filler.write(to: url, atomically: true, encoding: .utf8)

            CrowLog.automation("after rotation")

            let rotated = url.appendingPathExtension("1")
            #expect(FileManager.default.fileExists(atPath: rotated.path))
            let active = try String(contentsOf: url, encoding: .utf8)
            #expect(active.hasSuffix("[automation] after rotation\n"))
            // The active file starts fresh — the old bulk moved aside.
            #expect(active.count < CrowLog.maxBytes)
            #expect(try String(contentsOf: rotated, encoding: .utf8).hasPrefix("xxx"))
        }
    }

    @Test func logFileAndDirectoryAreOwnerOnly() throws {
        // The log carries session UUIDs, PR URLs and raw `gh` error text — same
        // 0o700 dir / 0o600 file treatment as JSONStore/ConfigStore (review #787).
        try withTempLogDirectory { dir in
            CrowLog.automation("first line creates the file")
            let fm = FileManager.default
            let filePerms = try #require(
                (try fm.attributesOfItem(atPath: CrowLog.fileURL.path))[.posixPermissions] as? NSNumber)
            let dirPerms = try #require(
                (try fm.attributesOfItem(atPath: dir.path))[.posixPermissions] as? NSNumber)
            #expect(filePerms.int16Value == 0o600)
            #expect(dirPerms.int16Value == 0o700)

            // Still owner-only after an append to the existing file...
            CrowLog.automation("second line appends")
            let afterAppend = try #require(
                (try fm.attributesOfItem(atPath: CrowLog.fileURL.path))[.posixPermissions] as? NSNumber)
            #expect(afterAppend.int16Value == 0o600)
        }
    }

    @Test func permissionsSurviveRotation() throws {
        try withTempLogDirectory { _ in
            let url = CrowLog.fileURL
            CrowLog.automation("seed")
            let filler = String(repeating: "x", count: CrowLog.maxBytes + 1)
            try filler.write(to: url, atomically: true, encoding: .utf8)

            CrowLog.automation("triggers rotation")

            let fm = FileManager.default
            // Both the fresh active file and the rotated generation stay 0o600 —
            // the atomic write above replaced the inode, dropping any prior mode.
            for path in [url.path, url.appendingPathExtension("1").path] {
                let perms = try #require(
                    (try fm.attributesOfItem(atPath: path))[.posixPermissions] as? NSNumber)
                #expect(perms.int16Value == 0o600, "\(path) should be owner-only")
            }
        }
    }

    @Test func defaultDirectoryUnderTestsIsNotTheLiveLogDirectory() {
        // No `configure` override: the ADR 0012 test-process fallback must keep
        // the suite out of ~/Library/Logs/crow.
        CrowLog.configure(directory: nil)
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/crow", isDirectory: true)
        #expect(CrowLog.directory != live)
    }
}
