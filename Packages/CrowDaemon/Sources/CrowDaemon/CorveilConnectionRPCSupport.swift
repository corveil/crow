import CrowCore
import CrowIPC
import Foundation

/// Param decoding, secret-safe merge, and response encoding for the
/// `corveil-connect` / `corveil-status` / `corveil-disconnect` / `corveil-orgs`
/// RPC methods (CROW-1120) — the CLI-facing analog of the
/// `POST /config/corveil-connection` HTTP body in ``SecretRoutes``.
///
/// This is the local-only **write path** the epic (corveil/crow#1117) calls "the
/// door": the Corveil OAuth client (corveil/crow#1119) and the org-provisioning
/// flow (corveil/crow#1121) persist a ``CorveilConnection`` *through* here, never
/// through `set-config`, because the block holds OAuth tokens. Mirrors
/// ``SecretsRPC`` (gateways) and ``MCPTokenRPC`` (bearer tokens): two doors — the
/// RPC over the Unix socket and the HTTP POST for the browser — share this one
/// implementation, so the CLI and the Settings UI cannot drift on what a blank
/// field means or when a connection is rejected.
///
/// All four methods are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``). The two writes author
/// a credential; the two reads carry no secret but are gated alongside them, so
/// the whole connection is one local-only surface — the same choice `mcp-token-list`
/// makes beside the mint/revoke it lists. The non-secret fields a remote browser
/// needs for a read-only Integrations view still reach it through the stripped
/// `get-config` (``SettingsSecrets``), so nothing web breaks.
enum CorveilConnectionRPC {

    /// A rejected request, surfaced verbatim by both doors.
    struct Invalid: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// The fields a `corveil-connect` (or the HTTP set) carries. Every field is
    /// optional: an absent or blank one keeps whatever is stored, so the OAuth
    /// client can refresh just the access token + expiry without restating the
    /// refresh/registration tokens — the same "a blank value keeps the stored
    /// secret" contract a gateway header value has.
    struct Input {
        var baseURL: String?
        var clientID: String?
        var userID: String?
        var userEmail: String?
        var userName: String?
        var accessToken: String?
        var refreshToken: String?
        var registrationAccessToken: String?
        /// Already parsed to a `Date` by whichever door decoded it (ISO-8601 over
        /// the wire). `nil` keeps the stored expiry.
        var accessTokenExpiresAt: Date?

        init(
            baseURL: String? = nil,
            clientID: String? = nil,
            userID: String? = nil,
            userEmail: String? = nil,
            userName: String? = nil,
            accessToken: String? = nil,
            refreshToken: String? = nil,
            registrationAccessToken: String? = nil,
            accessTokenExpiresAt: Date? = nil
        ) {
            self.baseURL = baseURL
            self.clientID = clientID
            self.userID = userID
            self.userEmail = userEmail
            self.userName = userName
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.registrationAccessToken = registrationAccessToken
            self.accessTokenExpiresAt = accessTokenExpiresAt
        }
    }

    /// Build the connection to persist by merging `input` over `stored`.
    ///
    /// Non-blank fields overwrite; blank or absent fields keep the stored value
    /// (or empty when nothing is stored). `orgKeys` are always carried over
    /// untouched — they are provisioned by a separate flow (corveil/crow#1121),
    /// and a token refresh through this door must not drop them.
    ///
    /// Rejects a merged result that lacks a client id **or** an access token. This
    /// is deliberately stricter than `CorveilConnection.isEmpty`, which is an AND
    /// (blank client id *and* blank token) and so would accept a half-filled
    /// connection — a client-id-only connect would be stored as a live connection
    /// that `statusJSON` reports as `connected: true` with `has_access_token:
    /// false`. Both fields are the documented contract, here and in the CLI and
    /// the reference. A caller that means to remove the connection uses disconnect,
    /// not an all-blank connect.
    static func merge(_ input: Input, into stored: CorveilConnection?) throws -> CorveilConnection {
        func pick(_ incoming: String?, _ current: String) -> String {
            let trimmed = incoming?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? current : trimmed
        }
        let base = stored ?? CorveilConnection()
        let result = CorveilConnection(
            baseURL: pick(input.baseURL, base.baseURL),
            clientID: pick(input.clientID, base.clientID),
            connectedUser: CorveilConnectedUser(
                id: pick(input.userID, base.connectedUser.id),
                email: pick(input.userEmail, base.connectedUser.email),
                name: pick(input.userName, base.connectedUser.name)),
            orgKeys: base.orgKeys,
            oauth: CorveilOAuthTokens(
                accessToken: pick(input.accessToken, base.oauth.accessToken),
                refreshToken: pick(input.refreshToken, base.oauth.refreshToken),
                registrationAccessToken: pick(
                    input.registrationAccessToken, base.oauth.registrationAccessToken),
                accessTokenExpiresAt: input.accessTokenExpiresAt ?? base.oauth.accessTokenExpiresAt),
            // Reset health explicitly (CROW-1125): a (re)connect through this door is
            // a fresh grant, so any prior `needsReconnect`/error observation is stale
            // — carrying `base.health` over would leave a just-reconnected connection
            // showing "Reconnect". The refresher re-populates it on its next tick.
            health: CorveilConnectionHealth())
        let hasClientID = !result.clientID.trimmingCharacters(in: .whitespaces).isEmpty
        let hasAccessToken = !result.oauth.accessToken.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasClientID, hasAccessToken else {
            throw Invalid("a Corveil connection needs at least a client id and an access token")
        }
        return result
    }

    /// Decode `corveil-connect` params into an ``Input``.
    ///
    /// `access_token_expires_at` is an ISO-8601 string — the shape `corveil-status`
    /// emits — parsed by ``parseExpiry(_:)``; a present-but-unparseable value is
    /// rejected rather than silently dropped, since a caller who bothered to send
    /// an expiry meant something by it.
    static func decodeInput(_ params: [String: JSONValue]) throws -> Input {
        var input = Input()
        input.baseURL = params["base_url"]?.stringValue
        input.clientID = params["client_id"]?.stringValue
        input.userID = params["user_id"]?.stringValue
        input.userEmail = params["user_email"]?.stringValue
        input.userName = params["user_name"]?.stringValue
        input.accessToken = params["access_token"]?.stringValue
        input.refreshToken = params["refresh_token"]?.stringValue
        input.registrationAccessToken = params["registration_access_token"]?.stringValue
        input.accessTokenExpiresAt = try parseExpiry(params["access_token_expires_at"]?.stringValue)
        return input
    }

    /// Parse an optional ISO-8601 access-token expiry, shared by both doors (the
    /// CLI RPC and the HTTP POST) so a later format change can't drift the two
    /// parsers. A nil or blank value is "not provided" — keep whatever is stored;
    /// a present value that won't parse is rejected rather than silently dropped.
    ///
    /// Accepts both the plain `2026-01-01T00:00:00Z` shape `statusJSON` emits and
    /// the fractional-seconds shape a browser's `Date.toISOString()` produces
    /// (`…00.000Z`). A single `ISO8601DateFormatter` accepts only one of the two,
    /// so try both (CROW-1120 review).
    static func parseExpiry(_ raw: String?) throws -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        guard let date = parseISO8601(trimmed) else {
            throw Invalid(
                "the access-token expiry must be an ISO-8601 timestamp (e.g. 2026-01-01T00:00:00Z)")
        }
        return date
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    /// The `corveil-status` payload: connection health, no secrets. Whether a
    /// connection exists, its base URL / client id / connected user / org count /
    /// access-token expiry, and *presence* booleans for the tokens — never a
    /// token value. Safe to paste into a ticket, like `gateway-get` without
    /// `reveal`.
    ///
    /// Since CROW-1125 it also reports token health: `state` is one of
    /// `disconnected` / `connected` / `expired` / `revoked`, `needs_reconnect` is
    /// the derived "the user must click Reconnect" flag (true for `expired` and
    /// `revoked`), and `last_refresh_at` / `last_refresh_error` expose the
    /// background refresher's most recent outcome. `now` is injectable so the
    /// expiry→state derivation is deterministic in tests.
    static func statusJSON(_ connection: CorveilConnection?, now: Date = Date()) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        let state = connection?.healthState(now: now) ?? .disconnected
        guard let connection, !connection.isEmpty else {
            return [
                "connected": .bool(false),
                "state": .string(state.rawValue),
                "needs_reconnect": .bool(state.needsReconnect),
            ]
        }
        let user = connection.connectedUser
        let health = connection.health
        return [
            "connected": .bool(true),
            "state": .string(state.rawValue),
            "needs_reconnect": .bool(state.needsReconnect),
            "base_url": .string(connection.baseURL),
            "client_id": .string(connection.clientID),
            "connected_user": .object([
                "id": .string(user.id),
                "email": .string(user.email),
                "name": .string(user.name),
            ]),
            "org_count": .int(connection.orgKeys.count),
            "has_access_token": .bool(!connection.oauth.accessToken.isEmpty),
            "has_refresh_token": .bool(!connection.oauth.refreshToken.isEmpty),
            "has_registration_access_token": .bool(!connection.oauth.registrationAccessToken.isEmpty),
            "access_token_expires_at": connection.oauth.accessTokenExpiresAt
                .map { .string(formatter.string(from: $0)) } ?? .null,
            "last_refresh_at": health.lastRefreshAt
                .map { .string(formatter.string(from: $0)) } ?? .null,
            "last_refresh_error": health.lastRefreshError.map { .string($0) } ?? .null,
        ]
    }

    /// The `corveil-orgs` payload: the per-org gateway-key metadata (never key
    /// material — the `sk-citadel-…` value lives in the generated
    /// ``WorkspaceGateway`` header, not here). Empty when nothing is connected or
    /// no org has been provisioned yet (corveil/crow#1121).
    static func orgsJSON(_ connection: CorveilConnection?) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        let orgs = (connection?.orgKeys ?? []).map { key -> JSONValue in
            .object([
                "org_id": .string(key.orgID),
                "org_name": .string(key.orgName),
                "key_id": .string(key.keyID),
                "key_prefix": .string(key.keyPrefix),
                "created_at": key.createdAt.map { .string(formatter.string(from: $0)) } ?? .null,
            ])
        }
        return ["orgs": .array(orgs), "count": .int(orgs.count)]
    }
}
