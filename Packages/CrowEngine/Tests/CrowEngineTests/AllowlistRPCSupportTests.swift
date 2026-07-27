import CrowIPC
import Foundation
import Testing
@testable import CrowEngine

/// Coverage for `AllowlistRPC` (#819). The decode that `promote-allowlist` used
/// inline was `compactMap { $0.stringValue }`, which silently dropped non-string
/// elements — so `{"patterns":["Read",42]}` granted one of two patterns and
/// reported success. Reachable from any script piping `jq` output at the CLI.
@Suite("Allowlist RPC support")
struct AllowlistRPCSupportTests {

    // MARK: - Accepts

    @Test func decodesTrimmedDedupedPatterns() throws {
        let value = JSONValue.array([.string(" Read "), .string("Read"), .string("Write")])
        #expect(try AllowlistRPC.decodePatterns(value) == ["Read", "Write"])
    }

    @Test func decodesPatternsWithSpacesAndGlobs() throws {
        let value = JSONValue.array([.string("Bash(npm run build:*)")])
        #expect(try AllowlistRPC.decodePatterns(value) == ["Bash(npm run build:*)"])
    }

    @Test func dropsBlankEntriesAlongsideRealOnes() throws {
        let value = JSONValue.array([.string("Read"), .string("   "), .string("")])
        #expect(try AllowlistRPC.decodePatterns(value) == ["Read"])
    }

    // MARK: - Rejects

    @Test func rejectsMissingParam() {
        #expect(throws: RPCError.self) { try AllowlistRPC.decodePatterns(nil) }
    }

    @Test func rejectsNonArray() {
        for bad: JSONValue in [.string("Read"), .int(1), .bool(true), .object(["a": .int(1)])] {
            #expect(throws: RPCError.self, "expected \(bad) to be rejected") {
                try AllowlistRPC.decodePatterns(bad)
            }
        }
    }

    /// The regression guard for the silent-drop bug: a mixed array must fail
    /// outright rather than promote the string subset.
    @Test func rejectsNonStringElement() {
        for bad: JSONValue in [
            .array([.string("Read"), .int(42)]),
            .array([.string("Read"), .null]),
            .array([.string("Read"), .array([.string("Write")])]),
        ] {
            #expect(throws: RPCError.self, "expected \(bad) to be rejected") {
                try AllowlistRPC.decodePatterns(bad)
            }
        }
    }

    @Test func rejectsEmptyAndAllBlankArrays() {
        for bad: JSONValue in [.array([]), .array([.string("")]), .array([.string(" "), .string("\n")])] {
            #expect(throws: RPCError.self, "expected \(bad) to be rejected") {
                try AllowlistRPC.decodePatterns(bad)
            }
        }
    }

    // MARK: - Response shape

    @Test func promotionJSONKeepsOkAndReportsWhatChanged() {
        let json = AllowlistRPC.promotionJSON(
            AllowlistPromotion(
                added: ["Write"], alreadyGlobal: ["Read"],
                globalSettingsPath: "/tmp/settings.json"))

        // `ok` stays for the web caller that has always read it.
        #expect(json["ok"] == .bool(true))
        #expect(json["added"] == .array([.string("Write")]))
        #expect(json["already_global"] == .array([.string("Read")]))
        #expect(json["global_settings_path"] == .string("/tmp/settings.json"))
    }
}
