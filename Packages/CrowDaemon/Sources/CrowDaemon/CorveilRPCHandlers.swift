import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// The `corveil-*` verb group — Settings → Corveil CLI's **Verify** and
/// **Reinstall skill** (CROW-1011).
///
/// Own file (CROW-1134) so `makeCommandRouter` stays a thin assembler.
/// `scripts/check-cli-parity.sh` globs every `*RPCHandlers.swift` file.
///
/// Both are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``). The path they run is
/// `defaults.binaries["corveil"]` — an absolute path on the *daemon host* — and
/// that field is already local-only to **write** for exactly this reason. A
/// remote peer who could execute it would gain the arbitrary-execution half of
/// the thing the write gate withholds, from an ungated read of the same config.
/// `open-in-vscode` / `open-terminal` are gated on the same argument.
///
/// Neither writes config: `corveil-verify` runs `--version`, and
/// `corveil-reinstall-skill` writes the embedded skill files inside the devRoot.
/// What the reinstall *does* update is `AppState.corveilSkillInstallWarning` —
/// launch-time diagnostic — so a manual reinstall that succeeds clears the
/// stale warning and one that fails replaces it. That was the retired desktop
/// app's behaviour and it is the point: "is corveil broken?" stays
/// single-sourced instead of having a launch answer and a button answer.
func makeCorveilHandlers(
    appState: AppState, devRoot: String
) -> [String: CommandRouter.Handler] {
    [
        "corveil-verify": { params in
            let path = try corveilBinary(params, devRoot: devRoot)
            let outcome = await runCorveilAction { CorveilCLI.verify(path: path) }
            return [
                "ok": .bool(outcome.ok),
                "message": .string(outcome.message),
                "path": .string(outcome.path),
            ]
        },
        "corveil-reinstall-skill": { params in
            let path = try corveilBinary(params, devRoot: devRoot)
            let outcome = await runCorveilAction {
                CorveilCLI.reinstallSkill(path: path, devRoot: devRoot)
            }
            await MainActor.run {
                appState.corveilSkillInstallWarning = outcome.ok ? nil : outcome.message
            }
            return [
                "ok": .bool(outcome.ok),
                "message": .string(outcome.message),
                "path": .string(outcome.path),
                "skill_path": .string(CorveilCLI.commandsDir(devRoot: devRoot)),
            ]
        },
    ]
}

/// The `corveil-connect` / `corveil-status` / `corveil-disconnect` /
/// `corveil-orgs` verb group — the local-only write path for the Corveil
/// connection (CROW-1120), the "door" from the epic (corveil/crow#1117) that the
/// OAuth client (corveil/crow#1119) and org provisioning (corveil/crow#1121)
/// persist a ``CorveilConnection`` through, never through `set-config`, because
/// the block holds OAuth tokens.
///
/// Own file (CROW-1134) so `makeCommandRouter` stays a thin assembler.
/// `scripts/check-cli-parity.sh` globs every `*RPCHandlers.swift` file.
///
/// All four are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``). `corveil-connect`
/// writes OAuth tokens and `corveil-disconnect` clears the connection — both
/// author a credential, like `gateway-set`. The two reads carry no secret but are
/// gated alongside the writes, so the entire connection is one local-only surface
/// — the choice `mcp-token-list` makes beside the mint/revoke it lists. Not
/// MCP-exported: the surface is a credential store, and the MCP server is
/// read-only over `MCPToolCatalog`'s allowlist.
///
/// Decoding, the secret-safe merge, and the response shapes live in
/// ``CorveilConnectionRPC`` so this and the browser's
/// `POST /config/corveil-connection` (``SecretRoutes``) cannot drift.
func makeCorveilConnectionHandlers(
    cache: CorveilOrgListCache, devRoot: String
) -> [String: CommandRouter.Handler] {
    [
        // Store or update the connection. A blank/absent field keeps the stored
        // value — an access-token refresh need not restate the refresh token — and
        // the merged result must have at least a client id and an access token.
        // `orgKeys` are preserved (provisioned by corveil/crow#1121).
        "corveil-connect": { params in
            let input: CorveilConnectionRPC.Input
            do {
                input = try CorveilConnectionRPC.decodeInput(params)
            } catch let error as CorveilConnectionRPC.Invalid {
                throw DaemonRPCError.invalidParams(error.message)
            }
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                let merged: CorveilConnection
                do {
                    merged = try CorveilConnectionRPC.merge(input, into: config.corveilConnection)
                } catch let error as CorveilConnectionRPC.Invalid {
                    throw RPCError.invalidParams(error.message)
                }
                config.corveilConnection = merged
                var result = CorveilConnectionRPC.statusJSON(merged)
                result["saved"] = .bool(true)
                return result
            }
        },
        // Connection health — no secret. See `CorveilConnectionRPC.statusJSON`.
        "corveil-status": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return CorveilConnectionRPC.statusJSON(config.corveilConnection)
        },
        // Clear the whole connection. The cascade key-revocation on the Corveil
        // side is a separate concern (corveil/crow#1121, backend); this removes the
        // local block so gateway resolution and the log collector stop using it.
        // Invalidate the org-list cache too, so a reconnect as a different account
        // never sees the prior user's memberships before the entry ages out (the
        // cache is also keyed on the fresh-per-connect client id, which is the
        // guarantee for the HTTP disconnect path that can't reach this cache).
        "corveil-disconnect": { _ in
            let result = try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                let wasConnected = !(config.corveilConnection?.isEmpty ?? true)
                config.corveilConnection = nil
                return ["saved": .bool(true), "was_connected": .bool(wasConnected)]
            }
            cache.invalidate()
            return result
        },
        // The per-org gateway-key metadata (never key material). See
        // `CorveilConnectionRPC.orgsJSON`.
        "corveil-orgs": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return CorveilConnectionRPC.orgsJSON(config.corveilConnection)
        },
    ]
}

/// The `corveil-list-orgs` / `corveil-select-org` / `corveil-deselect-org` verb
/// group — org listing + one-key-per-org provisioning (CROW-1121).
///
/// These reach the network with the stored OAuth bearer: `corveil-list-orgs`
/// reads the user's Corveil memberships (served through a shared TTL cache), and
/// the two writes mint/reuse and revoke the one per-org gateway key via
/// ``CorveilOrgProvisioner``. All three are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial``): they act with a credential the
/// browser must never drive, exactly like the connection verbs beside them. The
/// cache is passed in (constructed once in ``makeCommandRouter``) so it survives
/// across calls.
///
/// Own file (CROW-1134) so `makeCommandRouter` stays a thin assembler.
/// `scripts/check-cli-parity.sh` globs every `*RPCHandlers.swift` file.
func makeCorveilProvisioningHandlers(
    cache: CorveilOrgListCache, devRoot: String
) -> [String: CommandRouter.Handler] {
    [
        // List the user's Corveil orgs (cached). Each row is annotated with whether
        // it currently has a provisioned key, so the dropdown can mark selections
        // without a second call.
        "corveil-list-orgs": { params in
            let forceRefresh = params["refresh"]?.boolValue ?? false
            let orgs = try await corveilMapErrors {
                try await CorveilOrgProvisioner.listOrganizations(
                    devRoot: devRoot, cache: cache, forceRefresh: forceRefresh)
            }
            let provisioned = Set(
                (ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?.orgKeys ?? [])
                    .map(\.orgID))
            let rows = orgs.map { org -> JSONValue in
                .object([
                    "org_id": .string(org.id),
                    "org_name": .string(org.name),
                    "role": .string(org.role),
                    "is_active": .bool(org.isActive),
                    "provisioned": .bool(provisioned.contains(org.id)),
                ])
            }
            return ["orgs": .array(rows), "count": .int(rows.count)]
        },
        // Select an org: mint or reuse its one gateway key. `rotate` re-mints
        // (the backend revokes the prior key as part of the mint).
        "corveil-select-org": { params in
            guard let orgID = params["org_id"]?.stringValue?.trimmingCharacters(in: .whitespaces),
                  !orgID.isEmpty
            else { throw DaemonRPCError.invalidParams("org_id is required") }
            let rotate = params["rotate"]?.boolValue ?? false
            let explicitName =
                params["org_name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            let outcome = try await corveilMapErrors {
                // `orgName` nil → the provisioner looks it up (and validates the org
                // is a real membership) only when it actually mints; a reuse skips
                // that lookup entirely.
                try await CorveilOrgProvisioner.provision(
                    devRoot: devRoot, orgID: orgID,
                    orgName: explicitName.isEmpty ? nil : explicitName,
                    cache: cache, force: rotate)
            }
            let formatter = ISO8601DateFormatter()
            return [
                "saved": .bool(true),
                "reused": .bool(outcome.reused),
                "org": .object([
                    "org_id": .string(outcome.orgKey.orgID),
                    "org_name": .string(outcome.orgKey.orgName),
                    "key_id": .string(outcome.orgKey.keyID),
                    "key_prefix": .string(outcome.orgKey.keyPrefix),
                    "created_at": outcome.orgKey.createdAt
                        .map { .string(formatter.string(from: $0)) } ?? .null,
                ]),
            ]
        },
        // Deselect an org: revoke its key server-side and drop the local record.
        "corveil-deselect-org": { params in
            guard let orgID = params["org_id"]?.stringValue?.trimmingCharacters(in: .whitespaces),
                  !orgID.isEmpty
            else { throw DaemonRPCError.invalidParams("org_id is required") }
            let removed = try await corveilMapErrors {
                try await CorveilOrgProvisioner.deprovision(devRoot: devRoot, orgID: orgID)
            }
            return ["saved": .bool(true), "removed": .bool(removed)]
        },
    ]
}

/// The `corveil-detect-gateways` / `corveil-link-gateway` verb group — the
/// migration from manual `x-citadel-api-key` gateways to the first-class
/// connection (CROW-1126), the finale of the epic (corveil/crow#1117).
///
/// `corveil-detect-gateways` reads the config and reports every gateway (Manager +
/// each workspace) carrying the `x-citadel-api-key` header, classified against the
/// stored connection (``CorveilGatewayMigration``). `corveil-link-gateway` adopts a
/// detected gateway's existing plaintext key into the connection as a named org's
/// key — a pure, offline config write (no re-mint; the Corveil backend has no
/// key→org lookup, so the org is user-supplied).
///
/// Both are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``): the detect read reports
/// redacted key prefixes and the link write authors a credential into the
/// connection, so the whole migration surface is gated alongside the other
/// `corveil-*` connection verbs. Own file group so `makeCommandRouter` stays a thin
/// assembler and `scripts/check-cli-parity.sh` globs the `"method": { params in`
/// key lines.
func makeCorveilMigrationHandlers(devRoot: String) -> [String: CommandRouter.Handler] {
    [
        // Report manual x-citadel-api-key gateways, classified against the
        // connection. No secret leaves — only redacted key prefixes.
        "corveil-detect-gateways": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let candidates = CorveilGatewayMigration.detect(config: config)
            let connected = !(config.corveilConnection?.isEmpty ?? true)
            return [
                "gateways": .array(candidates.map(corveilCandidateJSON)),
                "count": .int(candidates.count),
                "connected": .bool(connected),
            ]
        },
        // Adopt a detected gateway's existing plaintext key into the connection as
        // the named org's key. Pure config write.
        "corveil-link-gateway": { params in
            let targetKind =
                params["target"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            let orgID = params["org_id"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !orgID.isEmpty else { throw DaemonRPCError.invalidParams("org_id is required") }

            let target: CorveilGatewayMigration.Target
            let targetName: String
            switch targetKind {
            case "manager":
                target = .manager
                targetName = "Manager"
            case "workspace":
                guard let workspace =
                    params["workspace"]?.stringValue?.trimmingCharacters(in: .whitespaces),
                    !workspace.isEmpty
                else {
                    throw DaemonRPCError.invalidParams(
                        "workspace is required when target is 'workspace'")
                }
                target = .workspace(workspace)
                targetName = workspace
            default:
                throw DaemonRPCError.invalidParams("target must be 'manager' or 'workspace'")
            }
            let orgName = params["org_name"]?.stringValue
            let force = params["force"]?.boolValue ?? false

            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                let orgKey: CorveilOrgKey
                do {
                    orgKey = try CorveilGatewayMigration.link(
                        config: &config, target: target, orgID: orgID,
                        orgName: orgName, force: force)
                } catch let error as CorveilGatewayMigration.LinkError {
                    throw RPCError.invalidParams(error.description)
                }
                let formatter = ISO8601DateFormatter()
                return [
                    "saved": .bool(true),
                    "linked": .bool(true),
                    "target": .string(target.kind),
                    "target_name": .string(targetName),
                    "org": .object([
                        "org_id": .string(orgKey.orgID),
                        "org_name": .string(orgKey.orgName),
                        "key_prefix": .string(orgKey.keyPrefix),
                        "created_at": orgKey.createdAt
                            .map { .string(formatter.string(from: $0)) } ?? .null,
                    ]),
                ]
            }
        },
    ]
}

/// Encode one detected gateway candidate for the `corveil-detect-gateways`
/// response. `org_id`/`org_name` are present only for a `managed` row; `reason`
/// only for a `manual` row.
private func corveilCandidateJSON(_ candidate: CorveilGatewayMigration.Candidate) -> JSONValue {
    var object: [String: JSONValue] = [
        "target": .string(candidate.target.kind),
        "target_name": .string(candidate.targetName),
        "base_url": .string(candidate.baseURL),
        "value_kind": .string(candidate.valueKind.rawValue),
        "key_prefix": .string(candidate.keyPrefix),
        "classification": .string(candidate.classification.kind),
    ]
    switch candidate.classification {
    case .managed(let orgID, let orgName):
        object["org_id"] = .string(orgID)
        object["org_name"] = .string(orgName)
    case .manual(let reason):
        object["reason"] = .string(reason)
    case .linkable:
        break
    }
    return .object(object)
}

/// Map provisioning + Corveil API failures to `DaemonRPCError` so a CLI/web caller
/// gets a clear message. All are operational (network, auth, not-connected), not
/// bad params, so they surface as `applicationError`.
private func corveilMapErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as CorveilOrgProvisioner.ProvisionError {
        throw DaemonRPCError.applicationError(error.description)
    } catch let error as CorveilAPIClient.Failure {
        throw DaemonRPCError.applicationError(error.description)
    }
}

/// The binary a `corveil-*` call should act on: the caller's `path`, else the
/// configured one. Throws rather than defaulting to something, because "verify
/// nothing" has no useful answer.
///
/// File-scope rather than a local function inside `makeCorveilHandlers`: the
/// handlers are `@Sendable` closures, and a captured local function is not.
private func corveilBinary(_ params: [String: JSONValue], devRoot: String) throws -> String {
    let configured = ConfigStore.loadConfig(devRoot: devRoot)?.defaults.binaries["corveil"]
    guard let path = CorveilCLI.resolvePath(
        explicit: params["path"]?.stringValue, configured: configured)
    else {
        throw DaemonRPCError.invalidParams(
            "No corveil binary configured — pass --path, or set one in Settings → General → Corveil CLI.")
    }
    return path
}

/// Run one `CorveilCLI` action off the cooperative pool.
///
/// Both actions block on `Process.waitUntilExit` for up to `CorveilCLI.timeout`
/// seconds. The daemon serves every other session from the cooperative pool, so
/// a hung corveil binary must not be able to hold one of its threads for five
/// seconds — `Task.detached` gives the wait a thread of its own.
private func runCorveilAction(
    _ work: @escaping @Sendable () -> CorveilCLI.Outcome
) async -> CorveilCLI.Outcome {
    await Task.detached(priority: .userInitiated, operation: work).value
}
