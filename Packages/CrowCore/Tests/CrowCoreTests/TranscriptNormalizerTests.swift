import Foundation
import Testing
import CrowCore

@Suite struct TranscriptNormalizerTests {
    /// Make a unique temp directory for a test's fixture files.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logsync-normalizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func concatenatesJSONLFilesInOrder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jsonl")
        let b = dir.appendingPathComponent("b.jsonl")
        try #"{"i":1}"#.write(to: a, atomically: true, encoding: .utf8) // no trailing newline
        try "{\"i\":2}\n".write(to: b, atomically: true, encoding: .utf8)

        let result = TranscriptNormalizer.normalize(files: [a, b], format: .jsonl, maxBytes: 10_000)
        let text = String(data: result!.data, encoding: .utf8)!
        #expect(text == "{\"i\":1}\n{\"i\":2}\n") // newline inserted between files
        #expect(result!.eventCount == 2)
        #expect(result!.truncated == false)
    }

    @Test func countsToolUseEvents() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("t.jsonl")
        let body = """
        {"type":"user"}
        {"type":"assistant","content":[{"type":"tool_use","name":"Bash"}]}
        {"type":"assistant","content":[{"type":"tool_use","name":"Read"}]}
        """
        try body.write(to: f, atomically: true, encoding: .utf8)
        let result = TranscriptNormalizer.normalize(files: [f], format: .jsonl, maxBytes: 10_000)
        #expect(result!.eventCount == 3)
        #expect(result!.toolCallCount == 2)
    }

    @Test func truncatesAtLineBoundaryAndFlagsIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("big.jsonl")
        let body = "{\"line\":1}\n{\"line\":2}\n{\"line\":3}\n"
        try body.write(to: f, atomically: true, encoding: .utf8)
        // Cap between the first and second newline → should keep only line 1.
        let result = TranscriptNormalizer.normalize(files: [f], format: .jsonl, maxBytes: 15)
        #expect(result!.truncated == true)
        let text = String(data: result!.data, encoding: .utf8)!
        #expect(text == "{\"line\":1}\n") // trimmed to last complete line
    }

    @Test func sqliteFormatIsNotNormalized() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("state.vscdb")
        try Data([0x1, 0x2, 0x3]).write(to: f)
        #expect(TranscriptNormalizer.normalize(files: [f], format: .sqlite, maxBytes: 10_000) == nil)
    }

    @Test func emptyInputsYieldNil() {
        #expect(TranscriptNormalizer.normalize(files: [], format: .jsonl, maxBytes: 10_000) == nil)
    }

    // MARK: OpenCode SQLite store (CROW-1096)

    @Test func openCodeStoreFormatIsNotNormalizedViaFileList() throws {
        // OpenCode's `opencode.db` selects rows by cwd/session-id — a selector the
        // file-list `normalize` can't express — so it returns nil here and is
        // normalized through `OpenCodeStore` directly by the collector/backfill.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("opencode.db")
        try Data([0x1, 0x2]).write(to: f)
        #expect(TranscriptNormalizer.normalize(files: [f], format: .openCodeStore, maxBytes: 10_000) == nil)
    }

    @Test func finalizeWrapsNDJSONWithHintCounts() {
        let body = "{\"type\":\"user\"}\n{\"type\":\"assistant\",\"content\":[{\"type\":\"tool_use\"}]}\n"
        let t = TranscriptNormalizer.finalize(Data(body.utf8), truncated: true)
        #expect(t?.eventCount == 2)
        #expect(t?.toolCallCount == 1)
        #expect(t?.truncated == true)
        // Empty in ⇒ nil out.
        #expect(TranscriptNormalizer.finalize(Data(), truncated: false) == nil)
    }

    @Test func artifactStampMapsOpenCodeStoreToLogDir() {
        // The object-store format never leaves the collector — it uploads NDJSON
        // stamped `.logDir`; every other format stamps itself.
        #expect(AgentLogFormat.openCodeStore.artifactStamp == .logDir)
        #expect(AgentLogFormat.jsonl.artifactStamp == .jsonl)
        #expect(AgentLogFormat.logDir.artifactStamp == .logDir)
        #expect(AgentLogFormat.sqlite.artifactStamp == .sqlite)
    }

    // MARK: gzip + compressed cap (CROW-1394)

    /// NDJSON lines that compress well, like real transcripts do.
    private func ndjson(lines: Int) -> Data {
        var s = ""
        for i in 0..<lines {
            s += "{\"type\":\"assistant\",\"i\":\(i),\"text\":\"the quick brown fox jumps over the lazy dog\"}\n"
        }
        return Data(s.utf8)
    }

    /// NDJSON whose bytes barely compress, so the compressed size stays over a
    /// small cap and forces a cut.
    private func incompressibleNDJSON(lines: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var s = ""
        for _ in 0..<lines {
            let noise = (0..<48).map { _ in String(UInt8.random(in: 0...255, using: &rng), radix: 16) }.joined()
            s += "{\"n\":\"\(noise)\"}\n"
        }
        return Data(s.utf8)
    }

    @Test func gzipRoundTrips() throws {
        let raw = ndjson(lines: 500)
        let gz = try #require(Gzip.compress(raw))
        #expect(gz.prefix(2) == Data([0x1F, 0x8B])) // gzip magic, which Corveil sniffs
        #expect(gz.count < raw.count / 3)
        #expect(Gzip.decompress(gz) == raw)
        // Empty input is still a valid gzip member.
        #expect(Gzip.decompress(try #require(Gzip.compress(Data()))) == Data())
        // A truncated stream does not inflate.
        #expect(Gzip.decompress(gz.prefix(gz.count / 2)) == nil)
    }

    /// The cap is on the compressed body: a transcript several times the cap
    /// raw ships whole, untruncated, once it compresses under it.
    @Test func capAppliesToCompressedSize() throws {
        let raw = ndjson(lines: 2_000)
        let cap = raw.count / 4
        let t = try #require(TranscriptNormalizer.finalize(raw, truncated: false))
        let out = try #require(TranscriptNormalizer.gzipForUpload(t, maxBytes: cap))
        #expect(out.gzipped)
        #expect(out.truncated == false)
        #expect(out.data.count <= cap)
        #expect(out.eventCount == 2_000)
        #expect(Gzip.decompress(out.data) == raw)
    }

    /// Still over the cap once compressed ⇒ cut on a line boundary, oldest
    /// lines kept, flagged truncated, counts describing what was kept.
    @Test func truncatesOnlyWhenCompressedSizeIsStillOver() throws {
        let raw = incompressibleNDJSON(lines: 2_000)
        let cap = 20_000
        let t = try #require(TranscriptNormalizer.finalize(raw, truncated: false))
        #expect(try #require(Gzip.compress(raw)).count > cap)
        let out = try #require(TranscriptNormalizer.gzipForUpload(t, maxBytes: cap))
        #expect(out.gzipped)
        #expect(out.truncated)
        #expect(out.data.count <= cap)
        let kept = try #require(Gzip.decompress(out.data))
        #expect(kept.count < raw.count)
        #expect(raw.prefix(kept.count) == kept) // oldest bytes kept
        #expect(kept.last == 0x0A)              // whole lines only
        #expect(out.eventCount == kept.filter { $0 == 0x0A }.count)
    }

    /// A read that already stopped at the raw budget stays flagged truncated
    /// even when what was read compresses under the cap.
    @Test func readTruncationSurvivesCompression() throws {
        let t = try #require(TranscriptNormalizer.finalize(ndjson(lines: 10), truncated: true))
        let out = try #require(TranscriptNormalizer.gzipForUpload(t, maxBytes: 1 << 20))
        #expect(out.truncated)
    }

    @Test func rawReadBudgetScalesTheCompressedCap() {
        #expect(TranscriptNormalizer.rawReadBudget(forCompressedCap: 8_388_608) == 16 * 8_388_608)
        #expect(TranscriptNormalizer.rawReadBudget(forCompressedCap: 0) == 16)
        #expect(TranscriptNormalizer.rawReadBudget(forCompressedCap: Int.max) == Int.max)
    }

    /// A cap no line-bounded prefix compresses under still ships something:
    /// the head, uncompressed and flagged, instead of nothing.
    @Test func capTooSmallForAnyCompressedLineFallsBackUncompressed() throws {
        let raw = incompressibleNDJSON(lines: 3)
        let cap = 20 // under gzip's own header + trailer, so nothing compressed fits
        let t = try #require(TranscriptNormalizer.finalize(raw, truncated: false))
        let out = try #require(TranscriptNormalizer.gzipForUpload(t, maxBytes: cap))
        #expect(!out.gzipped)
        #expect(out.truncated)
        #expect(out.data.count <= cap)
        #expect(raw.prefix(out.data.count) == out.data)
    }
}
