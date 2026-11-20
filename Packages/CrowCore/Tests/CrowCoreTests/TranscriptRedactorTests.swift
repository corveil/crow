import Foundation
import Testing
import CrowCore

/// CROW-1484: log sync must not upload a gateway key an agent printed into its
/// transcript. All keys here are fakes.
@Suite struct TranscriptRedactorTests {
    private let ownKey = "sk-citadel-TESTTESTTESTOWNKEY0123456789"

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func redactsTheSessionsOwnKeyEvenWithoutTheCorveilPrefix() {
        // A self-hosted gateway's key needn't look like a Corveil key; the
        // literal pass catches it anyway.
        let custom = "gw-live-0123456789abcdef"
        let line = #"{"type":"tool_result","content":"x-api-key: gw-live-0123456789abcdef"}"# + "\n"
        let out = TranscriptRedactor.redact(Data(line.utf8), secrets: [custom])
        #expect(out.count == 1)
        #expect(!text(out.data).contains(custom))
        #expect(text(out.data).contains("x-api-key: \(TranscriptRedactor.replacement)"))
    }

    @Test func redactsAnyCorveilShapedKey() {
        // The incident: `env | grep ANTHROPIC` printing the header variable.
        let other = "sk-citadel-OTHERWORKSPACEKEY99"
        let line = #"{"content":"ANTHROPIC_CUSTOM_HEADERS=x-citadel-api-key: \#(other)\nX-Crow-Version: 1.0"}"# + "\n"
        let out = TranscriptRedactor.redact(Data(line.utf8), secrets: [ownKey])
        #expect(out.count == 1)
        #expect(!text(out.data).contains("OTHERWORKSPACEKEY99"))
        #expect(!text(out.data).contains("sk-citadel-O"))
        // Neighbouring text, including the JSON-escaped newline, survives.
        #expect(text(out.data).contains(#"\nX-Crow-Version: 1.0"#))
    }

    @Test func redactsAPrintedKeyPrefix() {
        // `corveil whoami` prints `key_prefix: sk-citadel-0a1b2c3d4`.
        let out = TranscriptRedactor.redact(Data(#"{"key_prefix":"sk-citadel-0a1b2c3d4"}"#.utf8), secrets: [])
        #expect(text(out.data) == #"{"key_prefix":"\#(TranscriptRedactor.replacement)"}"#)
    }

    @Test func leavesProseAboutKeysAlone() {
        for prose in ["sk-citadel-…", "sk-citadel-<key>", "sk-citadel-", "the sk-citadel- prefix", "sk-citadel-abc"] {
            let data = Data(#"{"text":"\#(prose)"}"#.utf8)
            let out = TranscriptRedactor.redact(data, secrets: [])
            #expect(out.count == 0, "\(prose)")
            #expect(out.data == data)
        }
    }

    @Test func keepsEveryLineValidJSON() throws {
        let lines = [
            #"{"a":"\#(ownKey)"}"#,
            #"{"b":"before \#(ownKey) after","n":2}"#,
            #"{"c":"sk-citadel-\#(String(repeating: "x", count: 40))"}"#,
        ]
        let input = Data((lines.joined(separator: "\n") + "\n").utf8)
        let out = TranscriptRedactor.redact(input, secrets: [ownKey])
        #expect(out.count == 3)
        let outLines = text(out.data).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(outLines.count == 4) // three lines plus the trailing empty one
        for line in outLines where !line.isEmpty {
            #expect(throws: Never.self) {
                _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
            }
        }
        #expect(!text(out.data).contains("sk-citadel-"))
    }

    @Test func overlappingMatchesCollapseToOneReplacement() {
        // The literal and the shape pass both hit the same key.
        let out = TranscriptRedactor.redact(Data("k=\(ownKey);".utf8), secrets: [ownKey])
        #expect(out.count == 1)
        #expect(text(out.data) == "k=\(TranscriptRedactor.replacement);")
    }

    @Test func ignoresBlankAndShortSecrets() {
        let data = Data(#"{"status":"ok","n":"1"}"#.utf8)
        let out = TranscriptRedactor.redact(data, secrets: ["", "  ", "ok", "1"])
        #expect(out.count == 0)
        #expect(out.data == data)
    }

    @Test func leavesInvalidUTF8BytesUntouched() {
        var data = Data([0xFF, 0xFE, 0x20])
        data.append(Data("sk-citadel-ABCDEFGHIJ".utf8))
        data.append(Data([0x20, 0xC3]))
        let out = TranscriptRedactor.redact(data, secrets: [])
        var want = Data([0xFF, 0xFE, 0x20])
        want.append(Data(TranscriptRedactor.replacement.utf8))
        want.append(Data([0x20, 0xC3]))
        #expect(out.data == want)
    }

    @Test func gzipForUploadRedactsBeforeCompressing() throws {
        let raw = Data((#"{"type":"user","text":"run env"}"# + "\n"
            + #"{"type":"tool_result","text":"ANTHROPIC_CUSTOM_HEADERS=x-citadel-api-key: \#(ownKey)"}"# + "\n").utf8)
        let t = try #require(TranscriptNormalizer.finalize(raw, truncated: false))
        let out = try #require(TranscriptNormalizer.gzipForUpload(t, maxBytes: 1 << 20, redacting: [ownKey]))
        let body = try #require(Gzip.decompress(out.data))
        #expect(!text(body).contains("sk-citadel-"))
        #expect(!text(body).contains("TESTTESTTESTOWNKEY"))
        #expect(text(body).contains(TranscriptRedactor.replacement))
        // Hint counts still describe the same lines.
        #expect(out.eventCount == t.eventCount)
        #expect(out.toolCallCount == t.toolCallCount)
    }

    @Test func gzipForUploadStillCatchesTheShapeWithNoNamedSecret() throws {
        let raw = Data((#"{"text":"sk-citadel-NAMELESSKEY123"}"# + "\n").utf8)
        let t = try #require(TranscriptNormalizer.finalize(raw, truncated: false))
        let out = try #require(TranscriptNormalizer.gzipForUpload(t, maxBytes: 1 << 20, redacting: []))
        let body = try #require(Gzip.decompress(out.data))
        #expect(!text(body).contains("NAMELESSKEY"))
    }
}
