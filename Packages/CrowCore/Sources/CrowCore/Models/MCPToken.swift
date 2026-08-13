import Foundation

/// A capability an MCP caller may exercise (CROW-1004).
///
/// Deliberately coarse and deliberately short. v1 is read-only, so there are
/// exactly two: one for the session surface and one for the boards. There is no
/// `prompt:send`, no `sessions:write`, and no `admin` — not "not yet implemented"
/// but *not defined*, so a token cannot name a capability the server might later
/// grow into. Adding a write scope is a decision someone has to make in this file.
///
/// The raw values are the wire form: they appear in `config.json`, in
/// `crow mcp token mint --scope`, and in the Settings UI, so they are part of the
/// public contract and must not be renamed.
public enum MCPScope: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    /// Read sessions and their derived state: the board summary, the session
    /// list, one session, and the stuck-session join.
    case sessionsRead = "sessions:read"
    /// Read the ticket and review boards.
    case boardRead = "board:read"

    /// Sorted output everywhere (token listings, `tools/list` order, error text)
    /// so the same inputs always render the same bytes.
    public static func < (lhs: MCPScope, rhs: MCPScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Parse a scope from user input, rejecting anything unknown.
    ///
    /// Returns `nil` rather than defaulting: silently dropping an unrecognized
    /// scope would mint a token narrower than the operator asked for, and they'd
    /// find out when a tool went missing rather than at mint time.
    public static func parse(_ raw: String) -> MCPScope? {
        MCPScope(rawValue: raw.trimmingCharacters(in: .whitespaces))
    }

    /// Every scope, as a set — what a local stdio caller gets by default.
    public static var all: Set<MCPScope> { Set(allCases) }
}

/// A minted MCP bearer token, as persisted in `AppConfig.mcpTokens` (CROW-1004).
///
/// Stores a **hash**, never the token. The plaintext is returned exactly once by
/// `mcp-token-mint` and is unrecoverable afterwards, which is why `prefix` exists:
/// it is the first few characters of the token body, enough for a human to tell
/// two tokens apart in `crow mcp token list` without the secret being present.
///
/// ### Why SHA-256 and not PBKDF2 like `WebAuthConfig`
///
/// `webAuth` hashes a **human-chosen password**, which has little entropy, so it
/// needs a deliberately slow KDF (210 000 PBKDF2 iterations) to make offline
/// guessing expensive. An MCP token is 32 bytes from a CSPRNG that *we* generate:
/// guessing it is 2²⁵⁶ work regardless of how the hash is computed, so iteration
/// count buys nothing. It would, however, cost something — a web password is
/// verified once per login, but a token is verified on **every MCP request**, and
/// 210 000 iterations per call is a self-inflicted denial of service. Same
/// reasoning as a GitHub personal access token. Verification is still
/// constant-time.
///
/// No salt, for the same reason: a salt defeats precomputation against low-entropy
/// inputs, and there is nothing to precompute against a 256-bit random secret.
///
/// `lastUsedAt` is deliberately absent. Persisting it would mean a `config.json`
/// write — under `withConfigLock`, rewriting the whole file — on every MCP request.
public struct MCPTokenRecord: Codable, Sendable, Equatable, Identifiable {
    /// Stable handle, minted server-side. The address for `mcp-token-revoke`.
    public var id: UUID
    /// Operator-supplied label, e.g. `"grok-bot"`. Not unique — revoke by `id`
    /// when two tokens share a name.
    public var name: String
    /// First 8 characters of the token body, for display. Not a secret: 8 base64
    /// characters is 48 bits, far too little to reconstruct the remaining 208.
    public var prefix: String
    /// Base64 SHA-256 of the full token string, including the `crow_mcp_` prefix.
    public var hashB64: String
    /// Granted capabilities. An empty array grants nothing, which is why minting
    /// requires at least one.
    public var scopes: [MCPScope]
    public var createdAt: Date
    /// When the token stops working. `nil` means never — reachable only by typing
    /// `--no-expiry`, since the ticket's position is that an off-box token should
    /// expire and a default of "never" makes that rest on the operator remembering.
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        prefix: String,
        hashB64: String,
        scopes: [MCPScope],
        createdAt: Date = Date(),
        expiresAt: Date?
    ) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.hashB64 = hashB64
        self.scopes = scopes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Tolerant decode, matching `WebAuthConfig`: a partially-written record must
    /// not trap the whole config load. An unknown scope string is **dropped**
    /// rather than failing the decode — a config written by a newer Crow that
    /// knows a scope this build doesn't should degrade to fewer capabilities, not
    /// to an undecodable `config.json` that the next write would replace wholesale.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        hashB64 = try c.decodeIfPresent(String.self, forKey: .hashB64) ?? ""
        let rawScopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        scopes = rawScopes.compactMap(MCPScope.parse)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prefix, hashB64, scopes, createdAt, expiresAt
    }

    /// Whether this record has passed its expiry. A `nil` expiry never does.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// The capabilities this token confers right now: none once expired, and none
    /// if the stored hash is empty (a truncated record must never authorize).
    public func grantedScopes(now: Date = Date()) -> Set<MCPScope> {
        guard !hashB64.isEmpty, !isExpired(now: now) else { return [] }
        return Set(scopes)
    }
}
