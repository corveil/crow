import CrowCore
import CrowPersistence
import Foundation

/// The background half of Corveil token health (CROW-1125): a daemon-lifetime loop
/// that renews the stored access token **before** it expires, and records the
/// outcome as connection health so the Integrations tab and `crow corveil status`
/// can surface a clear "Reconnect" state.
///
/// This is the scheduler the reusable ``CorveilConnectionRefresher`` primitive was
/// built for (corveil/crow#1119 left "when to call it" to this ticket). Each
/// ``tick(devRoot:client:now:)`` is one self-contained pass — load the connection,
/// decide whether a refresh is due, refresh, and persist tokens + health — so it is
/// driven from an ordinary `while` loop in ``CrowDaemon`` (like the pending-auth
/// prune) and unit-tested directly against a stub transport, no timer involved.
///
/// It never throws: a refresh that fails leaves the previous token in place and is
/// retried next tick. The distinction that matters is *why* it failed — a
/// definitively-rejected grant (`invalid_grant`/`invalid_client`) latches
/// `needsReconnect`, while a transient network error only records a diagnostic and
/// tries again — because only the former is the user's to fix by reconnecting.
enum CorveilTokenRefreshWatcher {
    /// How often the loop wakes. Matches the neighboring prune cadence; small
    /// relative to `refreshMargin` so a due token is always caught before it lapses.
    static let tickInterval: TimeInterval = 300  // 5 minutes

    /// Refresh once the access token is within this window of expiring. Larger than
    /// `tickInterval`, so at least one tick lands inside the window before expiry —
    /// the "refresh before expiry" the ticket requires. An already-expired token is
    /// (still) due, so a daemon that was down through an expiry catches up on boot.
    static let refreshMargin: TimeInterval = 600  // 10 minutes

    /// What one ``tick`` did — for logging and tests.
    enum Outcome: Equatable {
        /// No connection stored, or it has no access token.
        case noConnection
        /// A connection exists but can't be refreshed here (no refresh token, or no
        /// usable base URL). If it is also past expiry, `healthState` still reports
        /// `.expired`; the watcher simply has nothing to do.
        case notRefreshable
        /// The token is not yet within the refresh window (or its expiry is unknown,
        /// which can't be scheduled against) — nothing to do this tick.
        case notDue
        /// The token was refreshed and persisted; health reset to connected.
        case refreshed
        /// A refresh was attempted and failed. `needsReconnect` is true only for a
        /// definitive grant rejection (the connection is now `.revoked`).
        case failed(needsReconnect: Bool)
    }

    /// Whether a stored connection is due for a proactive refresh at `now`: it has a
    /// known expiry that is within `margin` of now (or already past). An unknown
    /// expiry is never "due" — a token with no stated lifetime is not scheduled
    /// against, and refreshing it blindly every tick would be wasteful.
    static func isDue(
        _ connection: CorveilConnection, now: Date, margin: TimeInterval = refreshMargin
    ) -> Bool {
        guard let expiry = connection.oauth.accessTokenExpiresAt else { return false }
        return expiry.timeIntervalSince(now) <= margin
    }

    /// One refresh pass. Never throws — a failure is recorded as health and retried
    /// on the next tick.
    @discardableResult
    static func tick(
        devRoot: String,
        client: CorveilOAuthClient = .live,
        now: Date = Date()
    ) async -> Outcome {
        guard let connection = ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection,
              !connection.isEmpty
        else { return .noConnection }

        let refreshToken = connection.oauth.refreshToken.trimmingCharacters(in: .whitespaces)
        guard !refreshToken.isEmpty,
              let endpoints = CorveilOAuthClient.Endpoints(baseURL: connection.baseURL)
        else { return .notRefreshable }

        guard isDue(connection, now: now) else { return .notDue }

        do {
            let response = try await client.refresh(
                endpoints: endpoints, clientID: connection.clientID, refreshToken: refreshToken)
            let tokens = CorveilConnectionRefresher.mergedTokens(
                existing: connection.oauth, response: response, now: now)
            try CorveilConnectionPersistence.recordRefreshSuccess(
                devRoot: devRoot, tokens: tokens, now: now)
            return .refreshed
        } catch {
            let revoked = isGrantRejection(error)
            _ = try? CorveilConnectionPersistence.recordRefreshFailure(
                devRoot: devRoot, error: describe(error), needsReconnect: revoked)
            return .failed(needsReconnect: revoked)
        }
    }

    /// Whether an error from the token endpoint means the stored grant is dead — the
    /// user must reconnect — as opposed to a transient failure worth retrying.
    ///
    /// Only the two OAuth error codes that name a bad grant qualify (RFC 6749 §5.2):
    /// `invalid_grant` (the refresh token is expired, revoked, or was already
    /// rotated away) and `invalid_client` (the registered client is gone). Every
    /// other OAuth error, and every transport/HTTP/parse failure, is treated as
    /// transient — a 5xx or a dropped connection must not push a working connection
    /// into a "Reconnect" state.
    static func isGrantRejection(_ error: Error) -> Bool {
        guard case let CorveilOAuthClient.Failure.oauth(code, _) = error else { return false }
        switch code.lowercased() {
        case "invalid_grant", "invalid_client": return true
        default: return false
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? CorveilOAuthClient.Failure)?.description ?? error.localizedDescription
    }
}
