import CrowCore
import Foundation
import Testing

@testable import CrowIPC

@Suite("MCP token wire")
struct MCPTokenWireTests {

    // MARK: - Duration grammar

    @Test("Durations parse with their unit")
    func durations() {
        #expect(MCPTokenWire.parseDuration("30s") == 30)
        #expect(MCPTokenWire.parseDuration("45m") == 45 * 60)
        #expect(MCPTokenWire.parseDuration("12h") == 12 * 3600)
        #expect(MCPTokenWire.parseDuration("90d") == 90 * 86_400)
        #expect(MCPTokenWire.parseDuration("2w") == 2 * 604_800)
        #expect(MCPTokenWire.parseDuration(" 90D ") == 90 * 86_400)
    }

    @Test("A bare number is rejected rather than guessed")
    func bareNumberRejected() {
        // "90" is ambiguous between 90 seconds and 90 days — seven orders of
        // magnitude of difference in what a leaked token buys. Better an error.
        #expect(MCPTokenWire.parseDuration("90") == nil)
    }

    @Test("Nonsense and non-positive durations are rejected")
    func invalidDurations() {
        #expect(MCPTokenWire.parseDuration("") == nil)
        #expect(MCPTokenWire.parseDuration("d") == nil)
        #expect(MCPTokenWire.parseDuration("0d") == nil)
        #expect(MCPTokenWire.parseDuration("-5d") == nil)
        #expect(MCPTokenWire.parseDuration("1y") == nil)
        #expect(MCPTokenWire.parseDuration("abc") == nil)
    }

    @Test("An absurd duration is refused rather than overflowing into a nonsense date")
    func durationCeiling() {
        #expect(MCPTokenWire.parseDuration("99999999999999d") == nil)
        #expect(MCPTokenWire.parseDuration("3650d") == 3650 * 86_400)
        #expect(MCPTokenWire.parseDuration("3651d") == nil)
    }

    // MARK: - Names

    @Test("Names are required, bounded and control-character free")
    func nameValidation() {
        #expect(MCPTokenWire.validate(name: "grok-bot") == nil)
        #expect(MCPTokenWire.validate(name: "") != nil)
        #expect(MCPTokenWire.validate(name: "   ") != nil)
        #expect(MCPTokenWire.validate(name: String(repeating: "x", count: 101)) != nil)
        // A control character would corrupt both the CLI listing and the Settings UI.
        #expect(MCPTokenWire.validate(name: "bad\u{0007}name") != nil)
        #expect(MCPTokenWire.validate(name: "line\nbreak") != nil)
    }

    // MARK: - Scopes

    @Test("Known scopes parse, sorted and deduplicated")
    func scopesParse() throws {
        let parsed = try MCPTokenWire.parseScopes(["board:read", "sessions:read", "board:read"]).get()
        #expect(parsed == [.boardRead, .sessionsRead])
    }

    @Test("An unknown scope is refused and names the valid ones")
    func unknownScopeRefused() {
        guard case .failure(let error) = MCPTokenWire.parseScopes(["sessions:write"]) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.message.contains("sessions:write"))
        #expect(error.message.contains("board:read"))
    }

    @Test("A scopeless mint is refused")
    func emptyScopesRefused() {
        // A token granting nothing authenticates fine and then shows an empty tool
        // list, which reads as a broken server rather than a misconfigured token.
        guard case .failure = MCPTokenWire.parseScopes([]) else {
            Issue.record("expected a failure")
            return
        }
    }

    @Test("The scope vocabulary is exactly the read-only pair v1 defines")
    func scopeVocabularyIsPinned() {
        // No prompt:send, no sessions:write, no admin — and adding one has to be a
        // deliberate edit here, not a side effect of some other change.
        #expect(Set(MCPScope.allCases.map(\.rawValue)) == ["sessions:read", "board:read"])
    }

    // MARK: - Redaction

    @Test("publicJSON never carries the hash")
    func publicJSONRedacts() throws {
        let token = MCPTokenRecord(
            name: "grok-bot",
            prefix: "AbCdEfGh",
            hashB64: "c2VjcmV0",
            scopes: [.boardRead],
            expiresAt: nil)
        let json = token.publicJSON()
        #expect(json["hashB64"] == nil)
        #expect(json["name"]?.stringValue == "grok-bot")
        #expect(json["prefix"]?.stringValue == "AbCdEfGh")
        #expect(json["expires_at"] == .null)
        #expect(json["expired"]?.boolValue == false)
        let encoded = try JSONEncoder().encode(JSONValue.object(json))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("c2VjcmV0"))
    }

    @Test("publicJSON reports expiry against the supplied clock")
    func publicJSONExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = MCPTokenRecord(
            name: "old", prefix: "AAAAAAAA", hashB64: "aGFzaA==",
            scopes: [.boardRead], expiresAt: now.addingTimeInterval(-1))
        #expect(token.publicJSON(now: now)["expired"]?.boolValue == true)
    }
}
