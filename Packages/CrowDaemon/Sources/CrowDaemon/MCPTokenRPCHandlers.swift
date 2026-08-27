import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// The `mcp-token-*` verb group (CROW-1004).
///
/// Own file (CROW-1134) so `makeCommandRouter` stays a thin assembler and
/// Swift's type-checker solver budget isn't spent on one giant literal.
/// `scripts/check-cli-parity.sh` globs every `*RPCHandlers.swift` file.
///
/// All three are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``): `mcp-token-mint` returns
/// the plaintext token exactly once, so a remote peer able to call it would be
/// minting itself the credential that gates remote MCP access. `mcp-token-list`
/// carries no secret but is gated alongside them, matching `web-password-get`.
///
/// These are **not** MCP-exported. The MCP surface is read-only and reaches only
/// `MCPToolCatalog`'s allowlist; `MCPLedgerExportTests` asserts that the exported
/// set and `ParityLedger.localOnlyRPCMethods` are disjoint.
func makeMCPTokenHandlers(devRoot: String) -> [String: CommandRouter.Handler] {
    [
        "mcp-token-list": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let now = Date()
            return [
                "tokens": .array(config.mcpTokens.map { .object($0.publicJSON(now: now)) }),
                "count": .int(config.mcpTokens.count),
            ]
        },
        // Mint a token. The plaintext is in the response and nowhere else — not in
        // config.json, not in the daemon log. A caller that loses it mints another.
        // Validation and expiry resolution live in `MCPTokenRPC` so this and the
        // browser's `POST /config/mcp-tokens` cannot drift.
        "mcp-token-mint": { params in
            let minted: MCPTokenStore.Minted
            do {
                minted = try MCPTokenRPC.mint(
                    name: params["name"]?.stringValue ?? "",
                    rawScopes: (params["scopes"]?.arrayValue ?? []).compactMap(\.stringValue),
                    noExpiry: params["no_expiry"]?.boolValue ?? false,
                    expiresInSeconds: params["expires_in_seconds"]?.intValue)
            } catch let error as MCPTokenRPC.Invalid {
                throw DaemonRPCError.invalidParams(error.message)
            }
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                config.mcpTokens.append(minted.record)
                return MCPTokenRPC.mintedJSON(minted)
            }
        },
        // Revoke by id, or by name when the name is unambiguous.
        "mcp-token-revoke": { params in
            let id = params["id"]?.stringValue
            let name = params["name"]?.stringValue
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                let removed: MCPTokenRecord
                do {
                    removed = try MCPTokenRPC.tokenToRevoke(id: id, name: name, in: config.mcpTokens)
                } catch let error as MCPTokenRPC.Invalid {
                    throw RPCError.invalidParams(error.message)
                }
                config.mcpTokens.removeAll { $0.id == removed.id }
                return [
                    "revoked": .bool(true),
                    "id": .string(removed.id.uuidString),
                    "name": .string(removed.name),
                    "remaining": .int(config.mcpTokens.count),
                ]
            }
        },
    ]
}
