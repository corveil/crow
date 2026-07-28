import Foundation
import Testing
@testable import CrowCore

/// `CrowLog` is the durable automation log added for CROW-782, and since
/// CROW-874 the process-wide non-blocking sink. Every test here points the sink
/// at a fresh temp directory (ADR 0012 — tests never write to the live
/// `~/Library/Logs/crow`) and restores the default afterwards.
///
/// Delivery is asynchronous, so any test that asserts on file contents must
/// `flush()` first. `flush` is a real barrier on the drain thread's progress —
/// never sleep to wait for a line.
@Suite(.serialized)
struct CrowLogTests {
    private func withTempLogDirectory(_ body: (URL) throws -> Void) rethrows {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-test-crowlog-\(UUID().uuidString)", isDirectory: true)
        CrowLog.configure(directory: dir)
        defer {
            // Drain into `dir` BEFORE retargeting and deleting it — otherwise an
            // in-flight line lands after the removal and the drain recreates the
            // directory, littering NSTemporaryDirectory().
            CrowLog.flush(timeout: 5)
            CrowLog.configure(directory: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    @Test func automationAppendsTimestampedLines() throws {
        try withTempLogDirectory { dir in
            CrowLog.automation("auto-merge: enabled=1 skipped=0")
            CrowLog.automation("auto-rebase: candidates=0")
            #expect(CrowLog.flush(timeout: 5))

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

    @Test func fileURLLivesUnderTheConfiguredDirectory() {
        withTempLogDirectory { dir in
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
            #expect(CrowLog.flush(timeout: 5))

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
            #expect(CrowLog.flush(timeout: 5))
            let fm = FileManager.default
            let filePerms = try #require(
                (try fm.attributesOfItem(atPath: CrowLog.fileURL.path))[.posixPermissions] as? NSNumber)
            let dirPerms = try #require(
                (try fm.attributesOfItem(atPath: dir.path))[.posixPermissions] as? NSNumber)
            #expect(filePerms.int16Value == 0o600)
            #expect(dirPerms.int16Value == 0o700)

            // Still owner-only after an append to the existing file...
            CrowLog.automation("second line appends")
            #expect(CrowLog.flush(timeout: 5))
            let afterAppend = try #require(
                (try fm.attributesOfItem(atPath: CrowLog.fileURL.path))[.posixPermissions] as? NSNumber)
            #expect(afterAppend.int16Value == 0o600)
        }
    }

    @Test func permissionsSurviveRotation() throws {
        try withTempLogDirectory { _ in
            let url = CrowLog.fileURL
            CrowLog.automation("seed")
            // Interior flush, not just a trailing one: the filler below is an
            // atomic write that replaces the inode, so if "seed" landed after it
            // the filler would be clobbered and rotation would never fire.
            #expect(CrowLog.flush(timeout: 5))
            let filler = String(repeating: "x", count: CrowLog.maxBytes + 1)
            try filler.write(to: url, atomically: true, encoding: .utf8)

            CrowLog.automation("triggers rotation")
            #expect(CrowLog.flush(timeout: 5))

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

    // MARK: - CROW-874

    @Test func infoDoesNotTouchTheAutomationFile() {
        // `crowd-automation.log` is a *decision* log, capped at 5 MiB with one
        // rotated generation. General traffic (SessionService alone has 65 call
        // sites) would evict the auto-merge trail CROW-782 exists to preserve.
        withTempLogDirectory { _ in
            CrowLog.info("[TmuxBackend] created cockpit surface")
            CrowLog.error("[crowd] socket bind failed")
            #expect(CrowLog.flush(timeout: 5))
            #expect(!FileManager.default.fileExists(atPath: CrowLog.fileURL.path))
        }
    }

    @Test func flushReturnsImmediatelyOnAnIdleSink() {
        // Nothing queued: the barrier must not burn its timeout. Deliberately
        // asks for a long deadline so a regression shows up as a slow test.
        let started = Date()
        #expect(CrowLog.flush(timeout: 30))
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func backlogOverflowDropsInsteadOfBlocking() throws {
        // A wedged sink must cost bounded memory and a gap in the log — never a
        // blocked caller. Capacity 0 forces every line down the drop path
        // deterministically, with no reliance on out-running the drain thread.
        try withTempLogDirectory { _ in
            let realCapacity = CrowLog.backlogCapacity
            defer { CrowLog.backlogCapacity = realCapacity }

            let before = CrowLog.droppedLineCount
            CrowLog.backlogCapacity = 0
            for i in 0..<50 { CrowLog.automation("dropped line \(i)") }

            // Dropped lines never take a sequence, so `flush` must not wait on
            // them — this returning false would mean flush can hang under load.
            #expect(CrowLog.flush(timeout: 5))
            #expect(CrowLog.droppedLineCount == before + 50)
            #expect(!FileManager.default.fileExists(atPath: CrowLog.fileURL.path))

            // ...and the sink recovers once there is room again.
            CrowLog.backlogCapacity = realCapacity
            CrowLog.automation("after recovery")
            #expect(CrowLog.flush(timeout: 5))
            let contents = try String(contentsOf: CrowLog.fileURL, encoding: .utf8)
            #expect(contents.hasSuffix("[automation] after recovery\n"))
        }
    }

    @Test func automationFileFormatIsPinned() throws {
        // The file format is `<ISO8601> [automation] <message>`, independent of
        // the stderr line format (which also carries `processName[pid]`). Pinned
        // so a future change to one cannot silently drift the other.
        try withTempLogDirectory { _ in
            CrowLog.automation("auto-merge: pr=42 skipped reason=checks-pending")
            #expect(CrowLog.flush(timeout: 5))

            let line = try String(contentsOf: CrowLog.fileURL, encoding: .utf8)
                .trimmingCharacters(in: .newlines)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            #expect(parts.count == 2)
            // Fractional seconds are part of the format — a bare
            // ISO8601DateFormatter would not parse these back.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(iso.date(from: parts[0]) != nil)
            #expect(parts[1] == "[automation] auto-merge: pr=42 skipped reason=checks-pending")
        }
    }
}
