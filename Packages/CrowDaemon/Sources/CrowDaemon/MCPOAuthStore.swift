import CrowCore
import CrowIPC
import CrowPersistence
import Foundation

/// The in-memory half of Crow's OAuth authorization server (CROW-1465):
/// dynamic registrations not yet approved, open consent pages, and authorization
/// codes.
///
/// ### Why none of this is on disk
///
/// Registration is unauthenticated, so anything it stored on disk would let a
/// stranger grow `config.json` (and take the config lock) at will. A client is
/// written to disk only inside the grant the operator approves; until then it is
/// a bounded, expiring entry here. Losing these on a daemon restart costs a
/// client one re-registration, which Claude does on every fresh connection anyway.
///
/// Codes are stored by SHA-256 hash, like every other credential, and are
/// single-use: `redeem` removes the code before anything else happens, and a code
/// presented again is reported as a replay so the token endpoint can revoke the
/// grant it produced (RFC 6749 §4.1.2).
final class MCPOAuthState: @unchecked Sendable {

    struct IssuedCode: Sendable {
        let request: MCPOAuth.AuthorizationRequest
        let scopes: [MCPScope]
        let expiresAt: Date
    }

    enum Redemption: Sendable {
        case valid(IssuedCode)
        /// Presented before. Carries the grant it produced, if one was created.
        case replayed(grantID: UUID?)
        /// Unknown or expired.
        case invalid
    }

    private struct PendingClient { let client: MCPOAuth.Client; let registeredAt: Date }
    private struct PendingConsent { let request: MCPOAuth.AuthorizationRequest; let openedAt: Date }
    private struct Redeemed { var grantID: UUID?; let forgetAt: Date }

    private let lock = NSLock()
    private var clients: [String: PendingClient] = [:]
    private var consents: [String: PendingConsent] = [:]
    private var codes: [String: IssuedCode] = [:]
    private var redeemed: [String: Redeemed] = [:]

    /// Most codes outstanding at once; each needs an approved consent, so this is
    /// a backstop rather than a limit anyone should meet.
    static let maxCodes = 200

    // MARK: Clients

    /// Register a client, evicting the oldest unapproved registration when full.
    func register(_ registration: MCPOAuth.Registration, now: Date = Date()) -> MCPOAuth.Client {
        let client = MCPOAuth.Client(
            clientID: MCPTokenStore.randomToken(prefix: MCPOAuth.clientIDPrefix),
            clientName: registration.clientName,
            redirectURIs: registration.redirectURIs)
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now)
        while clients.count >= MCPOAuth.maxPendingClients,
              let oldest = clients.min(by: { $0.value.registeredAt < $1.value.registeredAt })?.key {
            clients[oldest] = nil
        }
        clients[client.clientID] = PendingClient(client: client, registeredAt: now)
        return client
    }

    func client(_ clientID: String, now: Date = Date()) -> MCPOAuth.Client? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = clients[clientID],
              now.timeIntervalSince(entry.registeredAt) < MCPOAuth.pendingClientLifetime
        else { return nil }
        return entry.client
    }

    // MARK: Consent

    /// Hold a validated request while the operator decides. The returned id is
    /// the only thing the consent form posts back, so the request's parameters
    /// cannot be edited between the page and the approval.
    func openConsent(_ request: MCPOAuth.AuthorizationRequest, now: Date = Date()) -> String {
        let id = MCPTokenStore.randomToken()
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now)
        while consents.count >= MCPOAuth.maxPendingConsents,
              let oldest = consents.min(by: { $0.value.openedAt < $1.value.openedAt })?.key {
            consents[oldest] = nil
        }
        consents[id] = PendingConsent(request: request, openedAt: now)
        return id
    }

    func consent(_ id: String, now: Date = Date()) -> MCPOAuth.AuthorizationRequest? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = consents[id],
              now.timeIntervalSince(entry.openedAt) < MCPOAuth.consentLifetime
        else { return nil }
        return entry.request
    }

    func closeConsent(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        consents[id] = nil
    }

    // MARK: Codes

    /// Issue a single-use code for an approved request. Returns the plaintext;
    /// only its hash is kept.
    func issueCode(
        for request: MCPOAuth.AuthorizationRequest,
        scopes: [MCPScope],
        now: Date = Date()
    ) -> String {
        let code = MCPTokenStore.randomToken()
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now)
        while codes.count >= Self.maxCodes,
              let soonest = codes.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            codes[soonest] = nil
        }
        codes[MCPTokenStore.hash(code)] = IssuedCode(
            request: request, scopes: scopes,
            expiresAt: now.addingTimeInterval(MCPOAuth.authorizationCodeLifetime))
        return code
    }

    /// Consume a code. Whatever the outcome, the code cannot be redeemed again.
    func redeem(_ code: String, now: Date = Date()) -> Redemption {
        let key = MCPTokenStore.hash(code)
        lock.lock(); defer { lock.unlock() }
        if let issued = codes.removeValue(forKey: key) {
            // Remember it for as long as it would have been valid, plus the same
            // again, so a replay inside that window is caught.
            redeemed[key] = Redeemed(
                grantID: nil,
                forgetAt: issued.expiresAt.addingTimeInterval(MCPOAuth.authorizationCodeLifetime))
            return issued.expiresAt > now ? .valid(issued) : .invalid
        }
        if let previous = redeemed[key], previous.forgetAt > now {
            return .replayed(grantID: previous.grantID)
        }
        return .invalid
    }

    /// Link a redeemed code to the grant it produced, so a replay can revoke it.
    func recordGrant(_ grantID: UUID, forCode code: String) {
        let key = MCPTokenStore.hash(code)
        lock.lock(); defer { lock.unlock() }
        redeemed[key]?.grantID = grantID
    }

    // MARK: Housekeeping

    func prune(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now)
    }

    private func pruneLocked(now: Date) {
        clients = clients.filter { now.timeIntervalSince($0.value.registeredAt) < MCPOAuth.pendingClientLifetime }
        consents = consents.filter { now.timeIntervalSince($0.value.openedAt) < MCPOAuth.consentLifetime }
        codes = codes.filter { $0.value.expiresAt > now }
        redeemed = redeemed.filter { $0.value.forgetAt > now }
    }
}

/// The persisted half (CROW-1465): grants in `AppConfig.mcpOAuthGrants` and their
/// access tokens in `AppConfig.mcpTokens`. Every write goes through
/// `mutateConfig`, under the config lock, and refuses to overwrite a config that
/// does not decode.
enum MCPOAuthGrants {

    struct Issued {
        let grant: MCPOAuthGrant
        let accessToken: String
        let refreshToken: String
        let scopes: [MCPScope]
    }

    /// A client persisted on a grant, so a connected app can re-authorize after a
    /// daemon restart without re-registering.
    static func persistedClient(_ clientID: String, in config: AppConfig) -> MCPOAuth.Client? {
        guard let grant = config.mcpOAuthGrants.last(where: { $0.clientID == clientID }) else { return nil }
        return MCPOAuth.Client(
            clientID: grant.clientID, clientName: grant.clientName, redirectURIs: grant.redirectURIs)
    }

    /// Create a grant for an approved, PKCE-verified code, with its first access
    /// and refresh tokens.
    static func create(
        devRoot: String,
        request: MCPOAuth.AuthorizationRequest,
        scopes: [MCPScope],
        now: Date = Date()
    ) throws -> Issued {
        try mutateConfig(devRoot: devRoot) { config -> Issued in
            prune(&config, now: now)
            // A client re-authorizing (say, to change scopes) replaces its earlier
            // grant rather than stacking a second one beside it. Matched on the
            // issued client id, never the self-asserted name.
            for previous in config.mcpOAuthGrants where previous.clientID == request.client.clientID {
                remove(grantID: previous.id, from: &config)
            }
            guard config.mcpOAuthGrants.count < MCPOAuth.maxGrants else {
                throw MCPOAuth.Failure(
                    "invalid_grant",
                    "Crow already has \(MCPOAuth.maxGrants) connected apps; revoke one with `crow mcp token revoke`")
            }
            let refresh = MCPTokenStore.randomToken(prefix: MCPOAuth.refreshTokenPrefix)
            let grant = MCPOAuthGrant(
                clientID: request.client.clientID,
                clientName: request.client.clientName,
                redirectURIs: request.client.redirectURIs,
                scopes: scopes.sorted(),
                resource: request.resource,
                createdAt: now,
                refreshTokenHashB64: MCPTokenStore.hash(refresh),
                refreshExpiresAt: now.addingTimeInterval(MCPOAuth.refreshTokenLifetime))
            let access = accessToken(for: grant, scopes: scopes, now: now)
            config.mcpOAuthGrants.append(grant)
            config.mcpTokens.append(access.record)
            return Issued(grant: grant, accessToken: access.plaintext, refreshToken: refresh, scopes: scopes.sorted())
        }
    }

    /// Exchange a refresh token: rotate it and issue a new access token.
    ///
    /// Throws `MCPOAuth.Failure` (and writes nothing) for a token that is unknown,
    /// rotated, revoked, lapsed, or presented by another client.
    static func refresh(
        devRoot: String,
        refreshToken: String,
        clientID: String,
        requestedScopes: Set<MCPScope>,
        resource: String?,
        now: Date = Date()
    ) throws -> Issued {
        try mutateConfig(devRoot: devRoot) { config -> Issued in
            let invalid = MCPOAuth.Failure(
                "invalid_grant", "the refresh token is invalid, expired, already used, or revoked")
            // Compare against every grant, so timing does not reveal a position.
            let candidate = Array(MCPTokenStore.hash(refreshToken).utf8)
            var matched: Int?
            for (index, grant) in config.mcpOAuthGrants.enumerated()
            where PasswordHash.constantTimeEqual(candidate, Array(grant.refreshTokenHashB64.utf8)) {
                matched = index
            }
            guard let index = matched else { throw invalid }
            var grant = config.mcpOAuthGrants[index]
            guard grant.isRefreshable(now: now), grant.clientID == clientID else { throw invalid }
            if let resource, !MCPOAuth.resourceMatches(resource, expected: grant.resource) {
                throw MCPOAuth.Failure("invalid_target", "this grant is for \(grant.resource)")
            }
            let granted = Set(grant.scopes)
            guard requestedScopes.isSubset(of: granted) else {
                throw MCPOAuth.Failure(
                    "invalid_scope", "a refresh cannot widen the grant beyond \(MCPOAuth.scopeString(granted))")
            }
            let scopes = (requestedScopes.isEmpty ? granted : requestedScopes).sorted()

            let refresh = MCPTokenStore.randomToken(prefix: MCPOAuth.refreshTokenPrefix)
            grant.refreshTokenHashB64 = MCPTokenStore.hash(refresh)
            grant.refreshExpiresAt = now.addingTimeInterval(MCPOAuth.refreshTokenLifetime)
            grant.lastRefreshedAt = now
            config.mcpOAuthGrants[index] = grant

            // Keep the newest still-valid access token alongside the new one, so a
            // request already in flight with it does not fail mid-refresh; drop the
            // rest, so a grant holds at most two.
            let previous = config.mcpTokens
                .filter { $0.grantID == grant.id && !$0.isExpired(now: now) }
                .max(by: { $0.createdAt < $1.createdAt })
            config.mcpTokens.removeAll { $0.grantID == grant.id && $0.id != previous?.id }
            let access = accessToken(for: grant, scopes: scopes, now: now)
            config.mcpTokens.append(access.record)
            prune(&config, now: now)
            return Issued(grant: grant, accessToken: access.plaintext, refreshToken: refresh, scopes: scopes)
        }
    }

    /// Revoke a grant and every access token issued under it.
    @discardableResult
    static func revoke(devRoot: String, grantID: UUID) throws -> Bool {
        try mutateConfig(devRoot: devRoot) { config -> Bool in
            let before = config.mcpOAuthGrants.count
            remove(grantID: grantID, from: &config)
            return config.mcpOAuthGrants.count != before
        }
    }

    /// Remove a grant and its access tokens from `config` in place.
    static func remove(grantID: UUID, from config: inout AppConfig) {
        config.mcpOAuthGrants.removeAll { $0.id == grantID }
        config.mcpTokens.removeAll { $0.grantID == grantID }
    }

    /// Drop lapsed grants, expired OAuth access tokens, and access tokens whose
    /// grant is gone. Minted tokens are never touched: their expiry is the
    /// operator's to see in `crow mcp token list`.
    static func prune(_ config: inout AppConfig, now: Date = Date()) {
        config.mcpOAuthGrants.removeAll { $0.isRefreshExpired(now: now) }
        let live = Set(config.mcpOAuthGrants.map(\.id))
        config.mcpTokens.removeAll { token in
            guard let grantID = token.grantID else { return false }
            return token.isExpired(now: now) || !live.contains(grantID)
        }
    }

    private static func accessToken(
        for grant: MCPOAuthGrant,
        scopes: [MCPScope],
        now: Date
    ) -> MCPTokenStore.Minted {
        let minted = MCPTokenStore.mint(
            name: grant.clientName,
            scopes: scopes,
            expiresAt: now.addingTimeInterval(MCPOAuth.accessTokenLifetime),
            now: now)
        var record = minted.record
        record.grantID = grant.id
        return MCPTokenStore.Minted(record: record, plaintext: minted.plaintext)
    }
}

