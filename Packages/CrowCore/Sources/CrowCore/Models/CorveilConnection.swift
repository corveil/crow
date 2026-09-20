import Foundation

/// First-class Corveil integration connection state (CROW-1118; epic CROW-1117).
///
/// The source of truth for Crow's Corveil **Connect** (OAuth) integration. A
/// Connect button runs a Dynamic-Client-Registration + PKCE OAuth flow against
/// Corveil's own authorization server over a `127.0.0.1` loopback callback; the
/// result is stored here, and the existing per-workspace / Manager
/// ``WorkspaceGateway`` + logsync configs are **generated** from it (org picker →
/// gateway header + upload opt-in), so gateway resolution and the log collector
/// are unchanged. Absent (`nil`) means "not connected".
///
/// **Secret-safe transport.** Like ``WorkspaceGateway`` and ``JiraCredential``, the
/// whole block is authored only through the local-only Connect flow and its CLI
/// verbs (corveil/crow#1120), never `set-config`: `SettingsSecrets` blanks the
/// three OAuth token strings on the way to a browser and restores the stored
/// connection verbatim on the way back, so a web round-trip can neither read the
/// tokens nor clear the connection. The non-secret fields (base URL, client id,
/// connected user, per-org key metadata, token expiry) pass through for a
/// read-only display.
///
/// Decodes leniently (every field `decodeIfPresent … ?? default`) so a
/// partially-written block never traps the whole config load — the CROW-814 /
/// CROW-809 lesson.
public struct CorveilConnection: Codable, Sendable, Equatable {
    /// Corveil API base URL the OAuth flow and generated gateway resolve against.
    public var baseURL: String
    /// The OAuth client id Crow self-registered via Dynamic Client Registration.
    public var clientID: String
    /// The signed-in Corveil user this connection belongs to.
    public var connectedUser: CorveilConnectedUser
    /// Metadata (never key material) for the one auto-provisioned gateway key per
    /// Corveil org — org id/name, key id, display prefix, mint time. The
    /// `sk-citadel-…` value itself is **not** here; it lives in the sibling
    /// ``orgKeySecrets`` (a secret), from which the generated ``WorkspaceGateway``
    /// header is populated (corveil/crow#1124). Keeping the metadata free of key
    /// material means this array is safe to serialize to the read-only web view.
    public var orgKeys: [CorveilOrgKey]
    /// The `sk-citadel-…` gateway-key value for each provisioned org, keyed by
    /// Corveil org id — the **secret** half of ``orgKeys`` (CROW-1121). This is the
    /// source of truth `corveilConnection` holds so a key is minted once per org
    /// and reused across every workspace bound to it (the backend rotates the key
    /// on each `POST /api/keys`, so re-minting would silently invalidate bound
    /// gateways). Stripped for transport by `SettingsSecrets`, exactly like a
    /// gateway header value and the OAuth tokens; a generated ``WorkspaceGateway``
    /// (corveil/crow#1124) copies the value into its `x-citadel-api-key` header.
    public var orgKeySecrets: [String: String]
    /// OAuth token material — the secrets. Stripped for transport by
    /// `SettingsSecrets`.
    public var oauth: CorveilOAuthTokens
    /// Token-refresh health, owned by the background refresher (CROW-1125). Not a
    /// secret — it carries no token, only the *outcome* of the last refresh — so it
    /// passes through `SettingsSecrets` untouched and the read-only Integrations
    /// view can render a "Reconnect" state from it.
    public var health: CorveilConnectionHealth

    /// Whether the connection has enough to be usable — a client id and an access
    /// token. An all-empty block (e.g. a partially-written record) reads as unset.
    public var isEmpty: Bool {
        clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && oauth.accessToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The connection's health as of `now` (CROW-1125), the single fact the
    /// Integrations tab and `crow corveil status` key their "Reconnect" affordance
    /// off. Derived, not stored: a background refresh that renews the token moves
    /// `accessTokenExpiresAt` into the future and flips this back to `.connected`
    /// with no extra write.
    ///
    /// `.revoked` wins over `.expired` — a definitively-rejected grant
    /// (`health.needsReconnect`, set when a refresh came back `invalid_grant`) is a
    /// stronger, sooner signal than the clock passing an expiry the refresher might
    /// still renew. An unknown expiry (`nil`) is treated as not-yet-expired, since a
    /// token with no stated lifetime is not evidence of a lapse.
    public func healthState(now: Date = Date()) -> CorveilConnectionState {
        if isEmpty { return .disconnected }
        if health.needsReconnect { return .revoked }
        if let expiry = oauth.accessTokenExpiresAt, expiry <= now { return .expired }
        return .connected
    }

    public init(
        baseURL: String = "",
        clientID: String = "",
        connectedUser: CorveilConnectedUser = CorveilConnectedUser(),
        orgKeys: [CorveilOrgKey] = [],
        orgKeySecrets: [String: String] = [:],
        oauth: CorveilOAuthTokens = CorveilOAuthTokens(),
        health: CorveilConnectionHealth = CorveilConnectionHealth()
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.connectedUser = connectedUser
        self.orgKeys = orgKeys
        self.orgKeySecrets = orgKeySecrets
        self.oauth = oauth
        self.health = health
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        connectedUser = try c.decodeIfPresent(CorveilConnectedUser.self, forKey: .connectedUser)
            ?? CorveilConnectedUser()
        orgKeys = try c.decodeIfPresent([CorveilOrgKey].self, forKey: .orgKeys) ?? []
        orgKeySecrets = try c.decodeIfPresent([String: String].self, forKey: .orgKeySecrets) ?? [:]
        oauth = try c.decodeIfPresent(CorveilOAuthTokens.self, forKey: .oauth) ?? CorveilOAuthTokens()
        health = try c.decodeIfPresent(CorveilConnectionHealth.self, forKey: .health)
            ?? CorveilConnectionHealth()
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, clientID, connectedUser, orgKeys, orgKeySecrets, oauth, health
    }
}

extension CorveilConnection {
    /// Header the AI gateway authenticates a provisioned org's `sk-citadel-…` key
    /// with — the one auth header a derived ``WorkspaceGateway`` carries.
    public static let gatewayAPIKeyHeader = "x-citadel-api-key"

    /// The AI gateway derived for a provisioned org (corveil/crow#1123): this
    /// connection's ``baseURL`` plus the org's stored `sk-citadel-…` key as the
    /// ``gatewayAPIKeyHeader``. The secret lives only in ``orgKeySecrets`` — it never
    /// leaves the daemon host — so the org picker can't build this itself; it POSTs
    /// the org id to the local-only gateway route, which derives the result here and
    /// stores it. ``GatewayResolver`` and the log collector then consume it as an
    /// ordinary ``WorkspaceGateway`` (corveil/crow#1124), no special-casing.
    ///
    /// Returns nil when the org has no stored key secret, or the base URL is blank —
    /// the two halves a `WorkspaceGateway` requires (its both-or-neither invariant).
    /// A nil result is the signal to reject the write with "select the org first",
    /// never to store a half-filled gateway.
    public func derivedGateway(orgID: String) -> WorkspaceGateway? {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        let secret = (orgKeySecrets[orgID] ?? "").trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !secret.isEmpty else { return nil }
        return WorkspaceGateway(
            baseURL: base, customHeaders: [Self.gatewayAPIKeyHeader: secret])
    }
}

/// The health of a ``CorveilConnection``'s access token, as one of four states
/// (CROW-1125). Drives the Integrations tab and `crow corveil status`: `.expired`
/// and `.revoked` are the two that ask the user to **Reconnect**.
public enum CorveilConnectionState: String, Codable, Sendable, Equatable, CaseIterable {
    /// No connection is stored.
    case disconnected
    /// A usable, non-expired access token — nothing to do.
    case connected
    /// The access token is past its expiry and the background refresh has not
    /// renewed it (offline too long, or refresh failing). Reconnect fixes it.
    case expired
    /// A refresh was definitively rejected (`invalid_grant`/`invalid_client`) — the
    /// stored grant is dead (the user or an admin revoked it, or the refresh token
    /// lapsed). Only reconnecting issues a fresh grant.
    case revoked

    /// Whether this state asks the user to reconnect.
    public var needsReconnect: Bool { self == .expired || self == .revoked }
}

/// The signed-in Corveil user identity behind a ``CorveilConnection`` (CROW-1118).
/// Not a secret — shown read-only in the Integrations UI. Empty strings mean "not
/// yet populated"; decodes tolerantly so a partial record never traps the config
/// load.
public struct CorveilConnectedUser: Codable, Sendable, Equatable {
    public var id: String
    public var email: String
    public var name: String

    public init(id: String = "", email: String = "", name: String = "") {
        self.id = id
        self.email = email
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, email, name }
}

/// Metadata for the one auto-provisioned gateway key Crow mints per Corveil org
/// (CROW-1118). Deliberately holds **no key material** — the `sk-citadel-…` value
/// is written into the generated ``WorkspaceGateway`` header (a separate secret
/// field), so this block is not a secret and needs no stripping. `keyID` is the
/// handle a disconnect revokes by; `keyPrefix` lets the UI tell keys apart.
/// Decodes tolerantly (missing field → empty / nil).
public struct CorveilOrgKey: Codable, Sendable, Equatable {
    /// Corveil organization id the key belongs to.
    public var orgID: String
    /// Human-readable org name, for the org dropdown.
    public var orgName: String
    /// Id of the auto-provisioned gateway key, used to revoke on disconnect.
    public var keyID: String
    /// Display prefix of the minted key (never the full `sk-citadel-…` value).
    public var keyPrefix: String
    /// When the key was provisioned. `nil` = unknown.
    public var createdAt: Date?

    public init(
        orgID: String = "",
        orgName: String = "",
        keyID: String = "",
        keyPrefix: String = "",
        createdAt: Date? = nil
    ) {
        self.orgID = orgID
        self.orgName = orgName
        self.keyID = keyID
        self.keyPrefix = keyPrefix
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orgID = try c.decodeIfPresent(String.self, forKey: .orgID) ?? ""
        orgName = try c.decodeIfPresent(String.self, forKey: .orgName) ?? ""
        keyID = try c.decodeIfPresent(String.self, forKey: .keyID) ?? ""
        keyPrefix = try c.decodeIfPresent(String.self, forKey: .keyPrefix) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case orgID, orgName, keyID, keyPrefix, createdAt
    }
}

/// OAuth token material for a ``CorveilConnection`` — the secrets (CROW-1118).
///
/// All three token strings are blanked by `SettingsSecrets.strippedForTransport`
/// before the config reaches a browser and restored from the stored config on the
/// way back, exactly like a gateway header value: they never leave the machine via
/// `get-config`/`set-config`, and a web round-trip can't clear them. Written only
/// by the local-only Corveil OAuth client (corveil/crow#1120).
/// `accessTokenExpiresAt` is not itself a secret but rides with the tokens as one
/// unit. Decodes tolerantly so a partial record never traps the config load.
public struct CorveilOAuthTokens: Codable, Sendable, Equatable {
    /// User-scoped, cross-org OAuth access token (secret).
    public var accessToken: String
    /// OAuth refresh token used to renew `accessToken` (secret).
    public var refreshToken: String
    /// RFC 7592 registration access token — lets Crow manage (rotate/delete) its
    /// own Dynamic Client Registration (secret).
    public var registrationAccessToken: String
    /// When `accessToken` expires; drives refresh. `nil` = unknown.
    public var accessTokenExpiresAt: Date?

    public init(
        accessToken: String = "",
        refreshToken: String = "",
        registrationAccessToken: String = "",
        accessTokenExpiresAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.registrationAccessToken = registrationAccessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        registrationAccessToken = try c.decodeIfPresent(String.self, forKey: .registrationAccessToken) ?? ""
        accessTokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .accessTokenExpiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, registrationAccessToken, accessTokenExpiresAt
    }
}

/// Token-refresh health for a ``CorveilConnection`` (CROW-1125) — the outcome of
/// the background refresher's most recent attempt. Not a secret (no token, just
/// booleans/timestamps/a message), so it is **not** stripped for transport and the
/// read-only Integrations view can render it.
///
/// Owned by the refresher, not the user: `store`/`connect` reset it to a fresh
/// healthy default whenever new tokens land (replacing the tokens invalidates any
/// prior observation), and the refresher updates it in place — success clears it
/// and stamps `lastRefreshAt`; a definitive rejection sets `needsReconnect`; a
/// transient failure records only `lastRefreshError`. Decodes tolerantly so a
/// connection written before this field existed loads as healthy.
public struct CorveilConnectionHealth: Codable, Sendable, Equatable {
    /// When a background refresh last succeeded. `nil` = none has run since the
    /// tokens were (re)connected.
    public var lastRefreshAt: Date?
    /// Why the last refresh attempt failed, or `nil` when the last attempt
    /// succeeded (or none has run). Diagnostic only — cleared on the next success.
    public var lastRefreshError: String?
    /// Set when a refresh was rejected in a way that means the stored grant is dead
    /// (`invalid_grant`/`invalid_client`), so the user must reconnect. A transient
    /// network failure leaves this alone; a success clears it.
    public var needsReconnect: Bool

    public init(
        lastRefreshAt: Date? = nil,
        lastRefreshError: String? = nil,
        needsReconnect: Bool = false
    ) {
        self.lastRefreshAt = lastRefreshAt
        self.lastRefreshError = lastRefreshError
        self.needsReconnect = needsReconnect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastRefreshAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        lastRefreshError = try c.decodeIfPresent(String.self, forKey: .lastRefreshError)
        needsReconnect = try c.decodeIfPresent(Bool.self, forKey: .needsReconnect) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case lastRefreshAt, lastRefreshError, needsReconnect
    }
}
