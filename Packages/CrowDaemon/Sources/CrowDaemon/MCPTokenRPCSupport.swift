import CrowCore
import CrowIPC
import Foundation

/// Shared decision logic for the MCP token surfaces (CROW-1004).
///
/// There are two doors to this room, exactly as there are for the web password:
/// the `mcp-token-*` JSON-RPC methods that `crow mcp token` calls over the Unix
/// socket, and the `POST /config/mcp-tokens` HTTP route the browser's Settings tab
/// calls. Both are local-only — the RPCs through
/// ``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``, the route through
/// ``SecretRoutes/gateOK(_:_:boundHost:)``.
///
/// Two doors must not mean two implementations. Validation, expiry resolution and
/// revocation matching live here so the CLI and the browser cannot drift on what
/// `--expires-in` means or which token an ambiguous name selects; the callers
/// differ only in how they persist and how they report errors.
///
/// Mirrors `SecretsRPCSupport`, which does the same job for gateways.
enum MCPTokenRPC {

    /// A rejected request, with the message both callers surface verbatim.
    struct Invalid: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Validate a mint request and produce the token. Does **not** persist — the
    /// caller appends `record` under its own config lock.
    static func mint(
        name: String,
        rawScopes: [String],
        noExpiry: Bool,
        expiresInSeconds: Int?,
        now: Date = Date()
    ) throws -> MCPTokenStore.Minted {
        if let problem = MCPTokenWire.validate(name: name) {
            throw Invalid(problem)
        }
        let scopes: [MCPScope]
        switch MCPTokenWire.parseScopes(rawScopes) {
        case .failure(let error): throw Invalid(error.message)
        case .success(let parsed): scopes = parsed
        }
        if noExpiry, expiresInSeconds != nil {
            throw Invalid("no_expiry and expires_in_seconds are mutually exclusive")
        }
        if let expiresInSeconds,
           expiresInSeconds < 1 || expiresInSeconds > MCPTokenWire.maxExpirySeconds {
            throw Invalid("expires_in_seconds must be between 1 and \(MCPTokenWire.maxExpirySeconds)")
        }
        // Omitting both takes the 90-day default rather than "never", so a forgotten
        // token stops working. "Never" has to be asked for explicitly.
        let expiresAt: Date? = noExpiry
            ? nil
            : now.addingTimeInterval(
                TimeInterval(expiresInSeconds ?? MCPTokenWire.defaultExpirySeconds))

        return MCPTokenStore.mint(name: name, scopes: scopes, expiresAt: expiresAt, now: now)
    }

    /// What a revoke request addresses: a minted token, or an OAuth grant
    /// (CROW-1465).
    enum RevocationTarget: Equatable {
        case token(MCPTokenRecord)
        case grant(MCPOAuthGrant)

        var id: UUID {
            switch self {
            case .token(let token): return token.id
            case .grant(let grant): return grant.id
            }
        }

        var name: String {
            switch self {
            case .token(let token): return token.name
            case .grant(let grant): return grant.clientName
            }
        }
    }

    /// Pick the single token or grant a revoke request addresses.
    ///
    /// An ambiguous name is refused rather than resolved by position: deleting the
    /// wrong credential is not something to be helpful about, and the caller has an
    /// unambiguous handle available in `--id`. A grant's name is its client name.
    ///
    /// An id may also be an OAuth **access token's** id. That resolves to its
    /// grant: revoking only the access token would leave the refresh token able to
    /// mint the next one an hour later.
    static func revocationTarget(
        id: String?,
        name: String?,
        tokens: [MCPTokenRecord],
        grants: [MCPOAuthGrant]
    ) throws -> RevocationTarget {
        let id = id?.trimmingCharacters(in: .whitespaces)
        let name = name?.trimmingCharacters(in: .whitespaces)
        let hasID = !(id?.isEmpty ?? true)
        let hasName = !(name?.isEmpty ?? true)
        guard hasID != hasName else {
            throw Invalid("exactly one of id or name is required")
        }

        var matches: [RevocationTarget] = []
        if hasID, let id {
            guard let uuid = UUID(uuidString: id) else {
                throw Invalid("id must be a UUID (from `crow mcp token list`)")
            }
            if let grant = grants.first(where: { $0.id == uuid }) {
                matches.append(.grant(grant))
            } else if let token = tokens.first(where: { $0.id == uuid }) {
                if let grantID = token.grantID, let grant = grants.first(where: { $0.id == grantID }) {
                    matches.append(.grant(grant))
                } else {
                    matches.append(.token(token))
                }
            }
        } else if let name {
            // OAuth access tokens are named after their client; they are reached
            // through their grant, so only minted tokens match by name here.
            matches += tokens
                .filter { $0.grantID == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                .map(RevocationTarget.token)
            matches += grants
                .filter { $0.clientName.caseInsensitiveCompare(name) == .orderedSame }
                .map(RevocationTarget.grant)
        }

        guard let first = matches.first else {
            throw Invalid("No MCP token or OAuth grant matches that id or name")
        }
        guard matches.count == 1 else {
            throw Invalid("\(matches.count) tokens or grants are named '\(name ?? "")' — revoke by id instead")
        }
        return first
    }

    /// Apply a revoke to `config` and return the payload both doors report.
    /// Revoking a grant removes it and every access token issued under it.
    static func revoke(id: String?, name: String?, in config: inout AppConfig) throws -> [String: JSONValue] {
        let target = try revocationTarget(
            id: id, name: name, tokens: config.mcpTokens, grants: config.mcpOAuthGrants)
        switch target {
        case .token(let token):
            config.mcpTokens.removeAll { $0.id == token.id }
        case .grant(let grant):
            MCPOAuthGrants.remove(grantID: grant.id, from: &config)
        }
        return [
            "revoked": .bool(true),
            "kind": .string(target.kindName),
            "id": .string(target.id.uuidString),
            "name": .string(target.name),
            "remaining": .int(config.mcpTokens.filter { $0.grantID == nil }.count),
            "remaining_grants": .int(config.mcpOAuthGrants.count),
        ]
    }

    /// The `mcp-token-list` payload: minted tokens and OAuth grants, redacted.
    /// OAuth access tokens are not listed individually — they rotate hourly — but
    /// each grant reports how many are live.
    static func listJSON(_ config: AppConfig, now: Date = Date()) -> [String: JSONValue] {
        let minted = config.mcpTokens.filter { $0.grantID == nil }
        return [
            "tokens": .array(minted.map { .object($0.publicJSON(now: now)) }),
            "count": .int(minted.count),
            "grants": .array(config.mcpOAuthGrants.map { grant in
                let live = config.mcpTokens.filter { $0.grantID == grant.id && !$0.isExpired(now: now) }.count
                return .object(grant.publicJSON(now: now, activeAccessTokens: live))
            }),
            "grant_count": .int(config.mcpOAuthGrants.count),
        ]
    }

    /// The `mcp-token-mint` success payload, shared so the CLI and the browser
    /// report the same fields — including the warning, which is the only notice a
    /// user gets that the token is unrecoverable.
    static func mintedJSON(_ minted: MCPTokenStore.Minted, now: Date = Date()) -> [String: JSONValue] {
        [
            "saved": .bool(true),
            "token": .string(minted.plaintext),
            "warning": .string("This token is shown once and cannot be recovered."),
            "record": .object(minted.record.publicJSON(now: now)),
        ]
    }
}

extension MCPTokenRPC.RevocationTarget {
    var kindName: String {
        switch self {
        case .token: return "token"
        case .grant: return "oauth"
        }
    }
}
