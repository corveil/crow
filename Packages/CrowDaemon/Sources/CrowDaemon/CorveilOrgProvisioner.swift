import CrowCore
import CrowPersistence
import Foundation

/// Org listing + one-key-per-org provisioning (CROW-1121) — the coordinator that
/// sits between the pure HTTP ``CorveilAPIClient`` and the local-only
/// ``CorveilConnection`` config, plus the small in-memory cache the org dropdown
/// reads through.
///
/// This is the "on org selection, mint/reuse exactly one gateway key per org"
/// half of the epic (corveil/crow#1117). The invariants it enforces:
///   - **one key per org, reused** — a select for an org that already has a stored
///     key returns it without a network call, so every workspace bound to the org
///     shares the one `sk-citadel-…` value. This matters because the backend
///     deactivates the prior key on each `POST /api/keys`
///     (RadiusMethod/corveil#2706), so re-minting would silently break bound
///     gateways.
///   - **rotate = one POST** — `force: true` re-mints; the backend revokes the old
///     key as part of the mint, so the coordinator just replaces the stored record.
///   - **deselect = revoke + forget** — `DELETE /api/keys/{id}` (404 tolerated),
///     then drop the metadata and secret. No dangling local key.
///
/// The UI that decides *when* to select/deselect is a sibling ticket
/// (corveil/crow#1123); the `WorkspaceGateway` generated from the stored secret is
/// another (corveil/crow#1124). This ticket is only the mechanism, exposed through
/// the `corveil-list-orgs` / `corveil-select-org` / `corveil-deselect-org` RPCs.
enum CorveilOrgProvisioner {

    /// How long before an access token's expiry we proactively refresh, so a call
    /// doesn't race the boundary.
    static let refreshSkew: TimeInterval = 60

    /// Name attached to a minted key. The backend accepts any name and defaults an
    /// empty one; a fixed, recognizable value keeps the Corveil dashboard legible
    /// about who minted the key.
    static let keyName = "Crow gateway"

    /// Everything that can stop a provisioning call before it reaches the network.
    enum ProvisionError: Error, CustomStringConvertible, Equatable {
        /// No usable connection: none stored, or one lacking an access token / base
        /// URL. The caller should run the Connect flow first.
        case notConnected
        /// The named org is not one of the user's Corveil memberships.
        case unknownOrg(String)

        var description: String {
            switch self {
            case .notConnected:
                return "no usable Corveil connection — connect to Corveil first"
            case .unknownOrg(let id):
                return "organization \(id) is not one of your Corveil memberships"
            }
        }
    }

    /// The result of a select: the stored key metadata, and whether it was reused
    /// (no mint) or freshly provisioned.
    struct SelectOutcome: Sendable, Equatable {
        let orgKey: CorveilOrgKey
        let reused: Bool
    }

    // MARK: - List

    /// The user's Corveil orgs, served from `cache` when fresh and re-fetched
    /// otherwise. `forceRefresh` bypasses the cache (the UI's explicit refresh).
    static func listOrganizations(
        devRoot: String,
        cache: CorveilOrgListCache,
        apiClient: CorveilAPIClient = .live,
        oauthClient: CorveilOAuthClient = .live,
        now: Date = Date(),
        forceRefresh: Bool = false
    ) async throws -> [CorveilAPIClient.Organization] {
        let (connection, token) = try await validAccessToken(
            devRoot: devRoot, oauthClient: oauthClient, now: now)
        return try await cachedOrganizations(
            connection: connection, token: token, cache: cache,
            apiClient: apiClient, now: now, forceRefresh: forceRefresh)
    }

    /// Serve the org list through the cache given an already-resolved
    /// connection + token. Shared by `listOrganizations` and the mint path's name
    /// resolution so both hit one cache under one key.
    private static func cachedOrganizations(
        connection: CorveilConnection,
        token: String,
        cache: CorveilOrgListCache,
        apiClient: CorveilAPIClient,
        now: Date,
        forceRefresh: Bool
    ) async throws -> [CorveilAPIClient.Organization] {
        let key = Self.cacheKey(connection)
        if !forceRefresh, let cached = cache.get(key: key, now: now) {
            return cached
        }
        let orgs = try await apiClient.listOrganizations(baseURL: connection.baseURL, accessToken: token)
        cache.set(orgs, key: key, now: now)
        return orgs
    }

    // MARK: - Provision (select / rotate)

    /// Mint or reuse the one gateway key for `orgID`.
    ///
    /// With `force == false` (a plain select), an org that already has a stored key
    /// and secret is returned untouched — **no network call at all**, not even the
    /// membership lookup: a stored key is already known-good, and a reuse must not
    /// fail on a transient outage or a token that only breaks on refresh. With
    /// `force == true` (rotate), a fresh key is minted; the backend deactivates the
    /// prior one as part of the mint, so the stored record is simply replaced.
    ///
    /// `orgName` is the display name to store. `nil` (or empty) means "look it up
    /// from the user's memberships" — done lazily on the mint path only, which also
    /// validates `orgID` is a real membership. A caller that already knows the name
    /// (the UI) passes it to skip that lookup.
    static func provision(
        devRoot: String,
        orgID: String,
        orgName: String?,
        cache: CorveilOrgListCache,
        apiClient: CorveilAPIClient = .live,
        oauthClient: CorveilOAuthClient = .live,
        now: Date = Date(),
        force: Bool = false
    ) async throws -> SelectOutcome {
        let (connection, token) = try await validAccessToken(
            devRoot: devRoot, oauthClient: oauthClient, now: now)

        // Reuse: a stored key with a non-empty id and secret is the shared per-org
        // key. Re-minting would rotate it server-side and orphan bound gateways.
        // Returns before ANY network call — no mint, and no name lookup.
        if !force,
           let existing = connection.orgKeys.first(where: { $0.orgID == orgID }),
           !existing.keyID.isEmpty,
           let secret = connection.orgKeySecrets[orgID], !secret.isEmpty {
            return SelectOutcome(orgKey: existing, reused: true)
        }

        // Mint path. Resolve the display name now — from `orgName` if the caller
        // supplied one, else from the membership list (which also validates that
        // `orgID` is an org the user actually belongs to).
        let resolvedName = try await resolvedOrgName(
            explicit: orgName, orgID: orgID, connection: connection, token: token,
            cache: cache, apiClient: apiClient, now: now)
        let key = try await apiClient.provisionKey(
            baseURL: connection.baseURL, accessToken: token, orgID: orgID, name: keyName)
        let orgKey = CorveilOrgKey(
            orgID: orgID,
            orgName: resolvedName,
            keyID: key.id,
            keyPrefix: key.prefix,
            createdAt: key.createdAt ?? now)
        try CorveilConnectionPersistence.upsertOrgKey(
            devRoot: devRoot, orgKey: orgKey, secret: key.value)
        return SelectOutcome(orgKey: orgKey, reused: false)
    }

    /// The display name to store for a mint: the caller-supplied one wins; otherwise
    /// look it up in the user's memberships (cached), which also validates that
    /// `orgID` is one the user belongs to (else `.unknownOrg`).
    private static func resolvedOrgName(
        explicit: String?,
        orgID: String,
        connection: CorveilConnection,
        token: String,
        cache: CorveilOrgListCache,
        apiClient: CorveilAPIClient,
        now: Date
    ) async throws -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespaces).isEmpty {
            return explicit.trimmingCharacters(in: .whitespaces)
        }
        let orgs = try await cachedOrganizations(
            connection: connection, token: token, cache: cache,
            apiClient: apiClient, now: now, forceRefresh: false)
        guard let match = orgs.first(where: { $0.id == orgID }) else {
            throw ProvisionError.unknownOrg(orgID)
        }
        return match.name
    }

    // MARK: - Deprovision (deselect)

    /// Revoke `orgID`'s key server-side and drop its local metadata + secret.
    /// Returns whether anything was removed. A revoke `404` is treated as success
    /// (the key is already gone), so a deselect always converges on "no key".
    @discardableResult
    static func deprovision(
        devRoot: String,
        orgID: String,
        apiClient: CorveilAPIClient = .live,
        oauthClient: CorveilOAuthClient = .live,
        now: Date = Date()
    ) async throws -> Bool {
        let (connection, token) = try await validAccessToken(
            devRoot: devRoot, oauthClient: oauthClient, now: now)

        let keyID = connection.orgKeys.first(where: { $0.orgID == orgID })?.keyID ?? ""
        if !keyID.isEmpty {
            try await apiClient.revokeKey(baseURL: connection.baseURL, accessToken: token, keyID: keyID)
        }
        return try CorveilConnectionPersistence.removeOrg(devRoot: devRoot, orgID: orgID)
    }

    // MARK: - Token freshness

    /// Load the stored connection and return it with a usable access token,
    /// refreshing proactively when the token is at/near expiry and a refresh token
    /// is available. A refresh failure is swallowed — the (possibly stale) token is
    /// still tried, and a genuinely dead token surfaces as `.unauthorized` from the
    /// API call, which is the signal the reconnect UX (corveil/crow#1125) acts on.
    private static func validAccessToken(
        devRoot: String,
        oauthClient: CorveilOAuthClient,
        now: Date
    ) async throws -> (connection: CorveilConnection, token: String) {
        guard var connection = ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection,
              !connection.isEmpty
        else { throw ProvisionError.notConnected }

        let expired = connection.oauth.accessTokenExpiresAt
            .map { $0 <= now.addingTimeInterval(refreshSkew) } ?? false
        let refreshable = !connection.oauth.refreshToken.trimmingCharacters(in: .whitespaces).isEmpty
            && CorveilOAuthClient.Endpoints(baseURL: connection.baseURL) != nil
        if expired && refreshable {
            _ = try? await CorveilConnectionRefresher.refresh(
                devRoot: devRoot, client: oauthClient, now: now)
            if let reloaded = ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection {
                connection = reloaded
            }
        }

        let token = connection.oauth.accessToken.trimmingCharacters(in: .whitespaces)
        let baseURL = connection.baseURL.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !baseURL.isEmpty else { throw ProvisionError.notConnected }
        return (connection, token)
    }

    /// Cache identity — the org list belongs to one connection, identified by its
    /// OAuth **client id**. The browser Connect flow self-registers a fresh client
    /// per connect (DCR issues a new `client_id` each time), so a disconnect +
    /// reconnect — even as the same user, certainly as a different one — changes
    /// this key and misses the cache. This is the cross-path guarantee against
    /// serving a previous account's memberships: it holds no matter which disconnect
    /// path (RPC or the HTTP `POST /config/corveil-connection` clear) ran, and does
    /// not depend on `connectedUser.id`, which the Connect persist path leaves empty.
    /// `baseURL` is folded in as defensive disambiguation.
    private static func cacheKey(_ connection: CorveilConnection) -> String {
        "\(connection.baseURL)\u{1}\(connection.clientID)"
    }
}

/// A tiny TTL cache for one user's Corveil org list (CROW-1121). Lock-guarded so
/// the concurrent `/rpc` handlers share one instance; keyed on (base URL, user) so
/// a reconnect as a different user is a miss rather than a leak. Holds only the
/// membership list — the "which org is provisioned" flag is derived live from the
/// stored connection, never cached.
final class CorveilOrgListCache: @unchecked Sendable {
    /// Long enough that opening the dropdown twice doesn't re-hit the API, short
    /// enough that a newly-added org membership shows up on its own before long.
    static let defaultTTL: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var key: String?
    private var orgs: [CorveilAPIClient.Organization] = []
    private var fetchedAt = Date.distantPast
    private let ttl: TimeInterval

    init(ttl: TimeInterval = defaultTTL) { self.ttl = ttl }

    /// The cached orgs when the key matches and the entry is within its TTL, else
    /// nil (a miss the caller re-fetches on).
    func get(key: String, now: Date = Date()) -> [CorveilAPIClient.Organization]? {
        lock.lock(); defer { lock.unlock() }
        guard self.key == key, now.timeIntervalSince(fetchedAt) <= ttl else { return nil }
        return orgs
    }

    func set(_ orgs: [CorveilAPIClient.Organization], key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        self.key = key
        self.orgs = orgs
        self.fetchedAt = now
    }

    /// Drop the entry — used when the connection is cleared, so the next list
    /// re-fetches rather than serving a disconnected user's orgs.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        key = nil
        orgs = []
        fetchedAt = .distantPast
    }
}
