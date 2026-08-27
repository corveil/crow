import CrowCore
import CrowPersistence
import Foundation

/// The three moving parts that sit *around* ``CorveilOAuthClient`` for the
/// Connect flow (CROW-1119): the in-flight-authorization store that ties a
/// browser callback back to its PKCE verifier, the local-only config write that
/// persists the resulting tokens, and the load→refresh→store helper that renews
/// an access token.
///
/// The client itself is pure HTTP; everything here is Crow-side state.

// MARK: - In-flight authorization

/// One pending authorization, created when Connect opens the browser and consumed
/// (once) when the loopback callback arrives. Carries the PKCE `codeVerifier` and
/// the `state` that the callback is validated against, plus the context the token
/// exchange and the config write need.
struct CorveilPendingAuthorization: Sendable, Equatable {
    let state: String
    let codeVerifier: String
    let clientID: String
    let redirectURI: String
    let baseURL: String
    let registrationAccessToken: String
    let scope: String
    let createdAt: Date
}

/// Holds pending authorizations keyed by `state` between the Connect POST and the
/// loopback callback. Single-use (``consume(state:now:)`` removes the entry) and
/// TTL-bounded, so a state can't be replayed and abandoned flows don't accumulate.
///
/// `state` is the OAuth anti-forgery value **and** the lookup key: a callback whose
/// `state` isn't present (never issued, already consumed, or expired) is rejected,
/// which is exactly the PKCE/`state` validation the ticket calls for. Lock-guarded
/// so the concurrent HTTP handlers can share one instance.
final class CorveilPendingAuthStore: @unchecked Sendable {
    /// How long a browser has to complete consent before the pending state expires.
    static let defaultTTL: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var byState: [String: CorveilPendingAuthorization] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = defaultTTL) { self.ttl = ttl }

    /// Record a freshly-started authorization.
    func put(_ pending: CorveilPendingAuthorization) {
        lock.lock(); defer { lock.unlock() }
        byState[pending.state] = pending
    }

    /// Remove and return the authorization for `state`, or nil if it was never
    /// issued, already consumed, or has expired. Single-use by construction.
    func consume(state: String, now: Date = Date()) -> CorveilPendingAuthorization? {
        lock.lock(); defer { lock.unlock() }
        guard let pending = byState.removeValue(forKey: state) else { return nil }
        guard now.timeIntervalSince(pending.createdAt) <= ttl else { return nil }
        return pending
    }

    /// Drop expired entries (called periodically by the daemon so long-abandoned
    /// flows don't leak memory).
    func prune(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        byState = byState.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
    }

    /// Current count — for tests.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return byState.count
    }
}

// MARK: - Persistence (the local-only write door)

/// Writes the Corveil connection into `config.json`.
///
/// This IS the local-only door the callback stores tokens through: it is reachable
/// only from ``CorveilIntegrationRoutes`` handlers that have already passed the
/// local-direct gate, and it writes the OAuth token strings that
/// `SettingsSecrets.strippedForTransport` blanks — so a browser can neither read
/// nor set them (corveil/crow#1118). `SettingsSecrets` names the OAuth flow as a
/// legitimate author of `corveilConnection`; the CLI verbs are a second author
/// (corveil/crow#1120), which is why the read-modify-write goes through
/// `ConfigStore.withConfigLock`, shared with every other config writer.
enum CorveilConnectionPersistence {
    /// Store the tokens from a fresh connect, merging into any existing connection
    /// (a reconnect) so the connected user and per-org key metadata a later step
    /// populated (corveil/crow#1121) survive a token refresh-by-reconnect. Base URL,
    /// client id, and the whole OAuth block are overwritten.
    static func store(
        devRoot: String,
        baseURL: String,
        clientID: String,
        tokens: CorveilOAuthTokens
    ) throws {
        try ConfigStore.withConfigLock {
            var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            var connection = config.corveilConnection ?? CorveilConnection()
            connection.baseURL = baseURL
            connection.clientID = clientID
            connection.oauth = tokens
            // Fresh tokens make any prior refresh observation stale: a reconnect
            // after a revocation must clear `needsReconnect`, or the UI would keep
            // asking the user to reconnect a connection that just succeeded
            // (CROW-1125). The refresher re-populates health on its next tick.
            connection.health = CorveilConnectionHealth()
            config.corveilConnection = connection
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        }
    }

    /// Replace only the OAuth token block (after a refresh), keeping base URL,
    /// client id, connected user, and org-key metadata. Returns false when there is
    /// no stored connection to update.
    @discardableResult
    static func updateTokens(devRoot: String, tokens: CorveilOAuthTokens) throws -> Bool {
        try ConfigStore.withConfigLock {
            var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard var connection = config.corveilConnection else { return false }
            connection.oauth = tokens
            config.corveilConnection = connection
            try ConfigStore.saveConfig(config, devRoot: devRoot)
            return true
        }
    }

    /// Persist a successful background refresh (CROW-1125): replace the OAuth block
    /// and stamp the connection **healthy** — `lastRefreshAt = now`, no error, no
    /// pending reconnect.
    ///
    /// Reloads inside the config lock and writes only if the stored grant is still
    /// the one this refresh presented (`expectedRefreshToken` == the stored refresh
    /// token). A disconnect (connection now nil) or a **reconnect** that landed
    /// while the token HTTP call was in flight therefore wins — returns false rather
    /// than clobbering the fresh grant with tokens minted from the old refresh
    /// token. Reconnect-wins, the sibling of disconnect-wins.
    @discardableResult
    static func recordRefreshSuccess(
        devRoot: String, expectedRefreshToken: String, tokens: CorveilOAuthTokens, now: Date
    ) throws -> Bool {
        try ConfigStore.withConfigLock {
            var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard var connection = config.corveilConnection,
                  connection.oauth.refreshToken == expectedRefreshToken
            else { return false }
            connection.oauth = tokens
            connection.health = CorveilConnectionHealth(
                lastRefreshAt: now, lastRefreshError: nil, needsReconnect: false)
            config.corveilConnection = connection
            try ConfigStore.saveConfig(config, devRoot: devRoot)
            return true
        }
    }

    /// Persist a failed background refresh (CROW-1125): record `error`, and — only
    /// for a definitive grant rejection — latch `needsReconnect`. The tokens and
    /// `lastRefreshAt` are left untouched (a transient failure must not erase a
    /// still-valid token), and `needsReconnect` is never *cleared* here — only a
    /// success or a reconnect clears it.
    ///
    /// Same reconnect-wins guard as `recordRefreshSuccess`: writes only if the
    /// stored grant is still the one this refresh presented. Without it, an
    /// `invalid_grant` on the *old* refresh token would mark a connection the user
    /// just reconnected as revoked.
    @discardableResult
    static func recordRefreshFailure(
        devRoot: String, expectedRefreshToken: String, error: String, needsReconnect: Bool
    ) throws -> Bool {
        try ConfigStore.withConfigLock {
            var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard var connection = config.corveilConnection,
                  connection.oauth.refreshToken == expectedRefreshToken
            else { return false }
            connection.health.lastRefreshError = error
            if needsReconnect { connection.health.needsReconnect = true }
            config.corveilConnection = connection
            try ConfigStore.saveConfig(config, devRoot: devRoot)
            return true
        }
    }

    /// Store (or replace) the one provisioned gateway key for an org: its metadata
    /// in `orgKeys` and its `sk-citadel-…` value in the secret `orgKeySecrets`
    /// (corveil/crow#1121). Read-modify-write under the shared config lock, merging
    /// into whatever is stored now — so a token refresh that landed between the
    /// mint and this write is preserved, and re-selecting an org replaces its key
    /// in place rather than appending a duplicate.
    ///
    /// A **rotate** (a fresh secret over an existing one) also propagates the new key
    /// into every gateway derived from the old value — the Manager gateway and each
    /// workspace gateway embed the `sk-citadel-…` inline, and the log upload reuses
    /// that same header — so they don't strand on the revoked key (corveil/crow#1124).
    /// Done in this one locked write for atomicity; a no-op on a first mint or a reuse.
    ///
    /// Returns whether the key was written. **Reconnect-wins** (mirrors
    /// ``recordRefreshSuccess``): the write is refused unless the stored connection
    /// is still the same grant that minted — its `clientID` must equal
    /// `expectedClientID`. `select-org` and `connect`/`disconnect` sit in different
    /// `/rpc` lanes (and browser Connect is HTTP, un-laned), so they overlap; if a
    /// disconnect cleared the block or a reconnect — even as a **different account**,
    /// which gets a fresh DCR client id — replaced it while this mint was in flight,
    /// writing here would attach a spendable `sk-citadel-…` to a connection that
    /// didn't make it (`isEmpty` can't catch that; a different live connection is not
    /// empty). Using the client id, not the refresh token, means a concurrent token
    /// refresh (same client id) still lands. The caller
    /// (``CorveilOrgProvisioner/provision``) revokes the now-orphaned key when this
    /// returns false.
    @discardableResult
    static func upsertOrgKey(
        devRoot: String, expectedClientID: String, orgKey: CorveilOrgKey, secret: String
    ) throws -> Bool {
        try ConfigStore.withConfigLock {
            var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard var connection = config.corveilConnection,
                  connection.clientID == expectedClientID
            else { return false }
            // Capture the outgoing key BEFORE replacing it: a rotate (`force: true`)
            // mints a fresh secret over an existing one, and the gateways derived from
            // the old value must be carried forward to the new one (corveil/crow#1124).
            let previousSecret = connection.orgKeySecrets[orgKey.orgID] ?? ""
            connection.orgKeys.removeAll { $0.orgID == orgKey.orgID }
            connection.orgKeys.append(orgKey)
            connection.orgKeySecrets[orgKey.orgID] = secret
            config.corveilConnection = connection
            // Rotation propagation, in the SAME locked write as the key replacement so
            // there is no window where the connection holds the new key while a bound
            // gateway (Manager or workspace) still carries the revoked one. A no-op on
            // a first mint (previousSecret blank) or a reuse that didn't change it.
            config.propagateCorveilKeyRotation(from: previousSecret, to: secret)
            try ConfigStore.saveConfig(config, devRoot: devRoot)
            return true
        }
    }

    /// Drop an org's provisioned key metadata and secret (a deselect). Returns
    /// whether anything was actually removed, so the caller can distinguish "cleared
    /// a key" from "nothing was there". Leaves the rest of the connection intact.
    @discardableResult
    static func removeOrg(devRoot: String, orgID: String) throws -> Bool {
        try ConfigStore.withConfigLock {
            var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard var connection = config.corveilConnection else { return false }
            let hadKey = connection.orgKeys.contains { $0.orgID == orgID }
            let hadSecret = connection.orgKeySecrets[orgID] != nil
            guard hadKey || hadSecret else { return false }
            connection.orgKeys.removeAll { $0.orgID == orgID }
            connection.orgKeySecrets[orgID] = nil
            config.corveilConnection = connection
            try ConfigStore.saveConfig(config, devRoot: devRoot)
            return true
        }
    }
}

// MARK: - Refresh

/// Renews a stored connection's access token (RFC 6749 §6). This is the reusable
/// refresh primitive the ticket requires ("access-token refresh works"); the
/// scheduling/health/reconnect UX that decides *when* to call it is a later step
/// (corveil/crow#1125).
enum CorveilConnectionRefresher {
    enum RefreshError: Error, CustomStringConvertible {
        case noConnection
        case notRefreshable  // no refresh token, or no usable base URL

        var description: String {
            switch self {
            case .noConnection: return "no Corveil connection is stored"
            case .notRefreshable: return "the stored connection has no refresh token or base URL"
            }
        }
    }

    /// Load the stored connection, exchange its refresh token for a new token pair,
    /// merge in the rotated refresh token, persist, and return the new tokens.
    @discardableResult
    static func refresh(
        devRoot: String,
        client: CorveilOAuthClient = .live,
        now: Date = Date()
    ) async throws -> CorveilOAuthTokens {
        guard let connection = ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection else {
            throw RefreshError.noConnection
        }
        let refreshToken = connection.oauth.refreshToken.trimmingCharacters(in: .whitespaces)
        guard !refreshToken.isEmpty, let endpoints = CorveilOAuthClient.Endpoints(baseURL: connection.baseURL) else {
            throw RefreshError.notRefreshable
        }

        let response = try await client.refresh(
            endpoints: endpoints, clientID: connection.clientID, refreshToken: refreshToken)
        let tokens = mergedTokens(existing: connection.oauth, response: response, now: now)
        try CorveilConnectionPersistence.updateTokens(devRoot: devRoot, tokens: tokens)
        return tokens
    }

    /// Fold a token response into the stored OAuth block: the new access token and
    /// its fresh expiry always win; the refresh token is replaced only when the
    /// server actually rotated it (a response may omit it), and the registration
    /// access token — not part of a refresh — is carried through untouched.
    static func mergedTokens(
        existing: CorveilOAuthTokens,
        response: CorveilOAuthClient.TokenResponse,
        now: Date
    ) -> CorveilOAuthTokens {
        CorveilOAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken.isEmpty ? existing.refreshToken : response.refreshToken,
            registrationAccessToken: existing.registrationAccessToken,
            accessTokenExpiresAt: response.expiresAt(now: now))
    }
}
