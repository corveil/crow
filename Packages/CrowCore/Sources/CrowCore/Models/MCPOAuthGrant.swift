import Foundation

/// An OAuth grant to an MCP client, as persisted in `AppConfig.mcpOAuthGrants`
/// (CROW-1465).
///
/// This is the third way to reach `POST /mcp`, after `crow mcp serve` (stdio,
/// trusted by locality) and a minted `crow_mcp_…` bearer token. Claude's
/// connectors — claude.ai, Claude Desktop and the mobile apps — call from
/// Anthropic's cloud and can only authenticate with OAuth, so Crow is its own
/// authorization server: a client registers dynamically, the operator approves it
/// on a consent page **that requires the web password**, and the client exchanges
/// the code (with PKCE) for a short-lived access token and a refresh token.
///
/// ### What is stored, and what is not
///
/// - The **refresh token** is stored as a SHA-256 hash only, exactly like an
///   `MCPTokenRecord`, and rotates on every use: the old hash is replaced, so a
///   refresh token works once.
/// - **Access tokens** are not stored here at all. They are ordinary
///   `MCPTokenRecord`s in `AppConfig.mcpTokens` carrying this grant's `id` in
///   `grantID`, so `/mcp` validates them with the code it already had.
/// - The **client registration** lives here too (`clientID`, `clientName`,
///   `redirectURIs`). Dynamic registration is unauthenticated, so the daemon keeps
///   fresh registrations in memory only and writes a client to disk the first time
///   the operator approves it. An unauthenticated peer can therefore never grow
///   `config.json`.
///
/// Revoking a grant (`crow mcp token revoke --id <grant id>`, or Settings → Web
/// access) removes the grant and every access token that carries its id, so both
/// the refresh token and any live access token stop working on the next request.
public struct MCPOAuthGrant: Codable, Sendable, Equatable, Identifiable {
    /// Stable handle, minted server-side. The address for `mcp-token-revoke`.
    public var id: UUID
    /// The `client_id` the daemon issued at dynamic registration.
    public var clientID: String
    /// The `client_name` the client registered with — what the consent page and
    /// `crow mcp token list` show. Self-asserted by the client, so it is a label,
    /// not an identity; the redirect URI is what the operator should check.
    public var clientName: String
    /// The registered redirect URIs. A code is only ever sent to one of these.
    public var redirectURIs: [String]
    /// The scopes the operator ticked at consent. A refresh can narrow these but
    /// never widen them.
    public var scopes: [MCPScope]
    /// The protected resource the grant is for — the public `…/mcp` URL the
    /// client named in its `resource` parameter (RFC 8707).
    public var resource: String
    public var createdAt: Date
    /// Base64 SHA-256 of the current refresh token. Replaced on every refresh.
    public var refreshTokenHashB64: String
    /// When the current refresh token stops working. Each refresh moves it forward,
    /// so a client in regular use stays connected and an abandoned one lapses.
    public var refreshExpiresAt: Date
    /// When the refresh token last rotated, for the listing. `nil` until the first
    /// refresh.
    public var lastRefreshedAt: Date?

    public init(
        id: UUID = UUID(),
        clientID: String,
        clientName: String,
        redirectURIs: [String],
        scopes: [MCPScope],
        resource: String,
        createdAt: Date = Date(),
        refreshTokenHashB64: String,
        refreshExpiresAt: Date,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.clientID = clientID
        self.clientName = clientName
        self.redirectURIs = redirectURIs
        self.scopes = scopes
        self.resource = resource
        self.createdAt = createdAt
        self.refreshTokenHashB64 = refreshTokenHashB64
        self.refreshExpiresAt = refreshExpiresAt
        self.lastRefreshedAt = lastRefreshedAt
    }

    /// Tolerant decode, matching `MCPTokenRecord`: a partially written record must
    /// not trap the whole config load, and an unknown scope string is dropped
    /// rather than failing the decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? ""
        redirectURIs = try c.decodeIfPresent([String].self, forKey: .redirectURIs) ?? []
        let rawScopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        scopes = rawScopes.compactMap(MCPScope.parse)
        resource = try c.decodeIfPresent(String.self, forKey: .resource) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        refreshTokenHashB64 = try c.decodeIfPresent(String.self, forKey: .refreshTokenHashB64) ?? ""
        // A record missing its expiry is treated as already lapsed, never as
        // "forever": the failure mode of a truncated record must be less access.
        refreshExpiresAt = try c.decodeIfPresent(Date.self, forKey: .refreshExpiresAt)
            ?? Date(timeIntervalSince1970: 0)
        lastRefreshedAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, clientID, clientName, redirectURIs, scopes, resource, createdAt
        case refreshTokenHashB64, refreshExpiresAt, lastRefreshedAt
    }

    /// Whether the current refresh token has lapsed.
    public func isRefreshExpired(now: Date = Date()) -> Bool {
        refreshExpiresAt <= now
    }

    /// Whether the refresh token can still be exchanged: present, unexpired, and
    /// granting at least one scope. A truncated record never refreshes.
    public func isRefreshable(now: Date = Date()) -> Bool {
        !refreshTokenHashB64.isEmpty && !scopes.isEmpty && !isRefreshExpired(now: now)
    }
}
