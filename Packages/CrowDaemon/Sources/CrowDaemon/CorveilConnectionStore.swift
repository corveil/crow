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
