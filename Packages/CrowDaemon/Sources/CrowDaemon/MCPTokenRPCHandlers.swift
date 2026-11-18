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
        // Minted tokens and OAuth grants (CROW-1465), both redacted.
        "mcp-token-list": { _ in
            MCPTokenRPC.listJSON(ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig())
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
        // Revoke a minted token or an OAuth grant, by id, or by name when the name
        // is unambiguous. A grant takes its access tokens with it.
        "mcp-token-revoke": { params in
            let id = params["id"]?.stringValue
            let name = params["name"]?.stringValue
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                do {
                    return try MCPTokenRPC.revoke(id: id, name: name, in: &config)
                } catch let error as MCPTokenRPC.Invalid {
                    throw RPCError.invalidParams(error.message)
                }
            }
        },
    ]
}
