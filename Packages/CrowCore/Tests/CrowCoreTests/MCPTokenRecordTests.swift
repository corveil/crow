import Foundation
import Testing

@testable import CrowCore

@Suite("MCP token record")
struct MCPTokenRecordTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func token(
        scopes: [MCPScope] = [.sessionsRead],
        hash: String = "aGFzaA==",
        expiresAt: Date? = nil
    ) -> MCPTokenRecord {
        MCPTokenRecord(
            name: "t", prefix: "AbCdEfGh", hashB64: hash, scopes: scopes,
            createdAt: now, expiresAt: expiresAt)
    }

    // MARK: - Expiry

    @Test("A token with no expiry never expires")
    func neverExpires() {
        #expect(!token().isExpired(now: now))
        #expect(!token().isExpired(now: now.addingTimeInterval(100 * 365 * 86_400)))
    }

    @Test("Expiry is inclusive at the boundary")
    func expiryBoundary() {
        // At exactly the expiry instant the token is already dead. Erring the other
        // way would leave a one-instant window where a revoked-by-time credential
        // still works.
        let t = token(expiresAt: now)
        #expect(t.isExpired(now: now))
        #expect(t.isExpired(now: now.addingTimeInterval(1)))
        #expect(!t.isExpired(now: now.addingTimeInterval(-1)))
    }

    // MARK: - Granted scopes

    @Test("An expired token grants nothing")
    func expiredGrantsNothing() {
        let t = token(scopes: [.sessionsRead, .boardRead], expiresAt: now.addingTimeInterval(-1))
        #expect(t.grantedScopes(now: now).isEmpty)
    }

    @Test("A record with no hash grants nothing")
    func hashlessGrantsNothing() {
        // A truncated or half-written record must never authorize. This also means a
        // config that reached a browser through `strippedForTransport` — where the
        // hash is blanked — cannot be fed back in as a working credential.
        #expect(token(hash: "").grantedScopes(now: now).isEmpty)
    }

    @Test("A live token grants exactly its scopes")
    func liveGrantsScopes() {
        let t = token(scopes: [.boardRead], expiresAt: now.addingTimeInterval(3600))
        #expect(t.grantedScopes(now: now) == [.boardRead])
    }

    // MARK: - Decoding

    @Test("A record decodes tolerantly from a partial object")
    func tolerantDecode() throws {
        let json = #"{"name":"partial"}"#
        let decoded = try JSONDecoder().decode(MCPTokenRecord.self, from: Data(json.utf8))
        #expect(decoded.name == "partial")
        #expect(decoded.hashB64.isEmpty)
        #expect(decoded.scopes.isEmpty)
        // And, being hashless, it authorizes nothing.
        #expect(decoded.grantedScopes(now: now).isEmpty)
    }

    @Test("An unknown scope is dropped rather than failing the whole config")
    func unknownScopeDropped() throws {
        // A config written by a newer Crow that knows a scope this build doesn't
        // should degrade to fewer capabilities — not to an undecodable config.json
        // that the next write would silently replace with defaults.
        let json = #"{"name":"n","hashB64":"aGFzaA==","scopes":["board:read","future:write"]}"#
        let decoded = try JSONDecoder().decode(MCPTokenRecord.self, from: Data(json.utf8))
        #expect(decoded.scopes == [.boardRead])
    }

    @Test("A record round-trips through JSON")
    func roundTrip() throws {
        let original = token(scopes: [.boardRead, .sessionsRead], expiresAt: now)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPTokenRecord.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.hashB64 == original.hashB64)
        #expect(Set(decoded.scopes) == Set(original.scopes))
    }

    // MARK: - Scope parsing

    @Test("Scope raw values are the documented wire strings")
    func scopeRawValues() {
        #expect(MCPScope.sessionsRead.rawValue == "sessions:read")
        #expect(MCPScope.boardRead.rawValue == "board:read")
        #expect(MCPScope.parse(" board:read ") == .boardRead)
        #expect(MCPScope.parse("board:write") == nil)
        #expect(MCPScope.parse("") == nil)
    }

    @Test("Scopes sort deterministically")
    func scopeOrdering() {
        #expect([MCPScope.sessionsRead, .boardRead].sorted() == [.boardRead, .sessionsRead])
    }
}

@Suite("AppConfig MCP token storage")
struct AppConfigMCPTokenTests {

    @Test("A config with no mcpTokens key decodes to an empty list")
    func absentKeyDecodes() throws {
        // Every existing install has no such key; it must load, not trap.
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(decoded.mcpTokens.isEmpty)
    }

    @Test("Tokens survive an encode/decode round trip")
    func tokensRoundTrip() throws {
        var config = AppConfig()
        config.mcpTokens = [
            MCPTokenRecord(
                name: "grok-bot", prefix: "AbCdEfGh", hashB64: "aGFzaA==",
                scopes: [.boardRead], expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.mcpTokens.count == 1)
        #expect(decoded.mcpTokens[0].name == "grok-bot")
        #expect(decoded.mcpTokens[0].scopes == [.boardRead])
    }
}
