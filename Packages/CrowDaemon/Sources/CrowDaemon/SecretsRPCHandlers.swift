import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// Gateway and web-password secret surfaces (CROW-815). Local-only on `/rpc`.
///
/// Extracted from `makeCommandRouter`'s dictionary literal (CROW-1134).
func makeSecretsHandlers(devRoot: String) -> [String: CommandRouter.Handler] {
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134).
    let handlers: [String: CommandRouter.Handler] = [
        // Secret surfaces: the web-access password and the AI gateways. The
        // browser reaches these through the local-only, Origin-checked HTTP POSTs
        // in `SecretRoutes`; the methods below are the CLI's equivalent over the
        // Unix socket (CROW-815).
        //
        // A JSON-RPC method on this shared router is *also* reachable over the
        // possibly-remote `/rpc` WebSocket, which can't tell a local caller from
        // a logged-in remote one — so each of these is listed in
        // `RPCWebSocketHandler.localOnlyDenial` and refused for non-local peers.
        // Without that gate a remote client could change the very password that
        // gates remote access (CROW-593). Reads are gated too: `gateway-get`
        // with `reveal` returns header secrets. Any new method here that touches
        // `webAuth` or a gateway MUST be added to that switch.
        //
        // The same local-direct bar applies to `set-config` changes of
        // `defaults.binaries` — those absolute binary paths execute at the next
        // launch. Scheduled `jobs` are not gated (CROW-665).
        "gateway-get": { params in
            let target = try SecretsRPC.decodeTarget(params)
            // Fail safe: a caller that omits `reveal` gets redacted values.
            let reveal = params["reveal"]?.boolValue ?? false
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            switch target {
            case .manager:
                var result = SecretsRPC.gatewayJSON(config.managerGateway, reveal: reveal)
                result["target"] = .string("manager")
                return result
            case .workspace(let ref):
                let index = try SecretsRPC.resolveWorkspace(ref, in: config)
                let workspace = config.workspaces[index]
                var result = SecretsRPC.gatewayJSON(workspace.gateway, reveal: reveal)
                result["workspace_id"] = .string(workspace.id.uuidString)
                result["workspace_name"] = .string(workspace.name)
                return result
            }
        },
        // Set or clear a gateway. `clear: true` removes it; otherwise `base_url`
        // plus at least one `header_lines` entry is required (both-or-neither).
        // A blank header value keeps the currently-stored secret, so the CLI can
        // change a base URL without restating the key.
        //
        // Writes go through `mutateConfig`, which refuses to overwrite a
        // `config.json` that exists but won't decode (CROW-814) — otherwise a
        // corrupt file plus one `crow gateway set` would silently replace every
        // workspace, job and credential with defaults.
        "gateway-set": { params in
            let target = try SecretsRPC.decodeTarget(params)
            let clear = params["clear"]?.boolValue ?? false
            let headers = clear ? nil : try SecretsRPC.decodeHeaderLines(params["header_lines"])
            let body = SecretRoutes.GatewayBody(
                baseURL: params["base_url"]?.stringValue, headers: headers, clear: clear)
            let incoming: WorkspaceGateway?
            switch SecretRoutes.buildGateway(body) {
            case .failure(let error): throw DaemonRPCError.invalidParams(error.message)
            case .success(let gateway): incoming = gateway
            }
            return try mapGatewayError {
                try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                    switch target {
                    case .manager:
                        let merged = try SecretRoutes.mergingPreservedHeaders(
                            incoming: incoming, stored: config.managerGateway).get()
                        config.managerGateway = merged
                        return ["saved": .bool(true), "gateway_set": .bool(merged != nil),
                                "target": .string("manager")]
                    case .workspace(let ref):
                        let index = try SecretsRPC.resolveWorkspace(ref, in: config)
                        let merged = try SecretRoutes.mergingPreservedHeaders(
                            incoming: incoming, stored: config.workspaces[index].gateway).get()
                        config.workspaces[index].gateway = merged
                        return ["saved": .bool(true), "gateway_set": .bool(merged != nil),
                                "workspace_id": .string(config.workspaces[index].id.uuidString),
                                "workspace_name": .string(config.workspaces[index].name)]
                    }
                }
            }
        },
        // Whether a web-access password is set, and at what PBKDF2 cost. The
        // hash and salt are never returned.
        "web-password-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return [
                "password_set": .bool(config.webAuth != nil),
                "iterations": .int(config.webAuth?.iterations ?? 0),
            ]
        },
        // Set, change, or clear the web-access password. Changing does not
        // require the old password — matching the web UI, where the local-direct
        // gate is the control. The plaintext is hashed here and never persisted.
        "web-password-set": { params in
            let clear = params["clear"]?.boolValue ?? false
            let password = params["password"]?.stringValue ?? ""
            if !clear, password.isEmpty {
                throw DaemonRPCError.invalidParams("password must be a non-empty string (or clear: true)")
            }
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                config.webAuth = clear ? nil : PasswordHash.make(password: password)
                return ["saved": .bool(true), "password_set": .bool(config.webAuth != nil)]
            }
        },
    ]
    return handlers
}

/// `SecretRoutes` reports a bad gateway shape as `GatewayValidationError`
/// (the HTTP routes turn it into a 400); surface it as `invalidParams` here.
private func mapGatewayError<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as SecretRoutes.GatewayValidationError {
        throw DaemonRPCError.invalidParams(error.message)
    }
}
