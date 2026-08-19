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
}
