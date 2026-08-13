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

    /// Pick the single token a revoke request addresses.
    ///
    /// An ambiguous name is refused rather than resolved by position: deleting the
    /// wrong credential is not something to be helpful about, and the caller has an
    /// unambiguous handle available in `--id`.
    static func tokenToRevoke(
        id: String?,
        name: String?,
        in tokens: [MCPTokenRecord]
    ) throws -> MCPTokenRecord {
        let id = id?.trimmingCharacters(in: .whitespaces)
        let name = name?.trimmingCharacters(in: .whitespaces)
        let hasID = !(id?.isEmpty ?? true)
        let hasName = !(name?.isEmpty ?? true)
        guard hasID != hasName else {
            throw Invalid("exactly one of id or name is required")
        }
        if hasID, let id, UUID(uuidString: id) == nil {
            throw Invalid("id must be a UUID (from `crow mcp token list`)")
        }

        let matches = tokens.filter { token in
            if hasID, let id { return token.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
            return token.name.caseInsensitiveCompare(name ?? "") == .orderedSame
        }
        guard let first = matches.first else {
            throw Invalid("No MCP token matches that id or name")
        }
        guard matches.count == 1 else {
            throw Invalid("\(matches.count) tokens are named '\(name ?? "")' — revoke by id instead")
        }
        return first
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
