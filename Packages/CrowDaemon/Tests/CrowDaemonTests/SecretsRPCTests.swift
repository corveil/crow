import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import Foundation
import Testing

@testable import CrowDaemon

/// The `gateway-*` / `web-password-*` RPC methods the CLI drives (CROW-815).
///
/// These go through the real router and read back from disk, so they cover the
/// handler, the `SecretRoutes` validators it reuses, and `AppConfig`'s
/// both-or-neither decode invariant in one pass.
@Suite struct SecretsRPCTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-secrets-rpc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func router(devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    private func call(
        _ router: CommandRouter, _ method: String, _ params: [String: JSONValue] = [:]
    ) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    // MARK: - Manager gateway

    @Test @MainActor func managerGatewaySetGetClearRoundTrip() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        // Nothing set yet.
        let empty = await call(router, "gateway-get", ["target": .string("manager")])
        #expect(empty.result?["gateway_set"] == .bool(false))

        let set = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-test-1")]),
        ])
        #expect(set.error == nil)
        #expect(set.result?["gateway_set"] == .bool(true))

        // It reached disk, not just memory.
        let stored = ConfigStore.loadConfig(devRoot: devRoot)
        #expect(stored?.managerGateway?.baseURL == "https://gw.example.com")
        #expect(stored?.managerGateway?.customHeaders["X-Api-Key"] == "sk-test-1")

        // Default read redacts the value but keeps the key.
        let redacted = await call(router, "gateway-get", ["target": .string("manager")])
        #expect(redacted.result?["base_url"] == .string("https://gw.example.com"))
        #expect(redacted.result?["headers"] == .object(["X-Api-Key": .string("")]))

        let revealed = await call(router, "gateway-get", [
            "target": .string("manager"), "reveal": .bool(true),
        ])
        #expect(revealed.result?["headers"] == .object(["X-Api-Key": .string("sk-test-1")]))

        let cleared = await call(router, "gateway-set", [
            "target": .string("manager"), "clear": .bool(true),
        ])
        #expect(cleared.result?["gateway_set"] == .bool(false))
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.managerGateway == nil)
    }

    @Test @MainActor func omittedRevealRedacts() async throws {
        // Fail safe: a caller that never sends `reveal` must not get secrets.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        _ = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-secret")]),
        ])
        let response = await call(router, "gateway-get", ["target": .string("manager")])
        #expect(response.result?["headers"] == .object(["X-Api-Key": .string("")]))
    }

    @Test @MainActor func blankHeaderValueKeepsStoredSecret() async throws {
        // The documented way to change a base URL without restating credentials.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        _ = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-test-1")]),
        ])
        let updated = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw2.example.com"),
            "header_lines": .array([.string("X-Api-Key:")]),
        ])
        #expect(updated.error == nil)

        let stored = ConfigStore.loadConfig(devRoot: devRoot)
        #expect(stored?.managerGateway?.baseURL == "https://gw2.example.com")
        #expect(stored?.managerGateway?.customHeaders["X-Api-Key"] == "sk-test-1")
    }

    @Test @MainActor func blankHeaderWithNoStoredSecretIsRejected() async throws {
        // Persisting {baseURL, no headers} would make the next loadConfig return
        // nil and wipe the file on the following write — SecretRoutes guards it.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let response = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key:")]),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.managerGateway == nil)
    }

    @Test @MainActor func baseURLWithoutHeadersIsRejected() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let response = await call(router(devRoot: devRoot), "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([]),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
    }

    @Test @MainActor func malformedHeaderLineIsRejected() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let response = await call(router(devRoot: devRoot), "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("no-colon-here")]),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
    }

    // MARK: - Workspace gateway

    @Test @MainActor func workspaceGatewayResolvesByNameAndUUID() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let workspace = WorkspaceInfo(name: "Corveil")
        try ConfigStore.saveConfig(AppConfig(workspaces: [workspace]), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        // By name, case-insensitively.
        let set = await call(router, "gateway-set", [
            "workspace": .string("corveil"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-ws")]),
        ])
        #expect(set.error == nil)
        #expect(set.result?["workspace_id"] == .string(workspace.id.uuidString))
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?
            .workspaces[0].gateway?.customHeaders["X-Api-Key"] == "sk-ws")

        // By UUID.
        let get = await call(router, "gateway-get", [
            "workspace": .string(workspace.id.uuidString), "reveal": .bool(true),
        ])
        #expect(get.result?["workspace_name"] == .string("Corveil"))
        #expect(get.result?["headers"] == .object(["X-Api-Key": .string("sk-ws")]))
    }

    @Test @MainActor func unknownWorkspaceIsRejected() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let response = await call(router(devRoot: devRoot), "gateway-get", [
            "workspace": .string("nope"),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
    }

    @Test @MainActor func managerGatewayAndWorkspaceGatewayAreIndependent() async throws {
        // Clearing the Manager gateway must not disturb a workspace's.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(
            AppConfig(workspaces: [WorkspaceInfo(name: "Corveil")]), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        _ = await call(router, "gateway-set", [
            "workspace": .string("Corveil"),
            "base_url": .string("https://ws.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-ws")]),
        ])
        _ = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://mgr.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-mgr")]),
        ])
        _ = await call(router, "gateway-set", ["target": .string("manager"), "clear": .bool(true)])

        let stored = ConfigStore.loadConfig(devRoot: devRoot)
        #expect(stored?.managerGateway == nil)
        #expect(stored?.workspaces[0].gateway?.customHeaders["X-Api-Key"] == "sk-ws")
    }

    // MARK: - Corrupt config

    @Test @MainActor func secretWritesRefuseToOverwriteAnUndecodableConfig() async throws {
        // `ConfigStore.loadConfig` returns nil for both "missing" and "malformed",
        // so a `?? AppConfig()` fallback here would let one `crow gateway set` on a
        // corrupt file silently replace every workspace, job and credential with
        // defaults. Both writers share `mutateConfig`'s refusal (CROW-814); this is
        // the secrets-side parallel to
        // `SettingsHandlerTests.writeRefusesToOverwriteAnUndecodableConfig`.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            atPath: claudeDir, withIntermediateDirectories: true)
        let configPath = (claudeDir as NSString).appendingPathComponent("config.json")
        let corrupt = #"{"workspaces": "not-an-array"}"#
        try corrupt.write(toFile: configPath, atomically: true, encoding: .utf8)
        let router = router(devRoot: devRoot)

        let gateway = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-test-1")]),
        ])
        #expect(gateway.error?.code == RPCErrorCode.applicationError)

        let password = await call(router, "web-password-set", ["password": .string("hunter2")])
        #expect(password.error?.code == RPCErrorCode.applicationError)

        // The bad file is left exactly as it was, not replaced with defaults.
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == corrupt)
    }

    // MARK: - Target selector

    @Test @MainActor func targetSelectorRejectsBothAndNeither() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let both = await call(router, "gateway-get", [
            "target": .string("manager"), "workspace": .string("Corveil"),
        ])
        #expect(both.error?.code == RPCErrorCode.invalidParams)

        let neither = await call(router, "gateway-get")
        #expect(neither.error?.code == RPCErrorCode.invalidParams)
    }

    // MARK: - Web password

    /// Set → status → change → clear in one test on purpose: each
    /// `web-password-set` runs real 210k-iteration PBKDF2, which is seconds per
    /// call in a debug build, so the stages share one setup rather than paying
    /// it again per test. The cheap crypto properties (verify rejects a wrong
    /// password, salts differ between records) are already pinned at
    /// `iterations: 2000` in `DaemonSecurityTests` — only the integration
    /// properties are asserted here.
    @Test @MainActor func webPasswordSetStatusChangeClearRoundTrip() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let before = await call(router, "web-password-get")
        #expect(before.result?["password_set"] == .bool(false))

        let set = await call(router, "web-password-set", ["password": .string("hunter2")])
        #expect(set.result?["password_set"] == .bool(true))

        // Hashed, not stored in plaintext — and it hashed the password we sent.
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.webAuth)
        #expect(stored.hashB64 != "hunter2")
        #expect(!stored.saltB64.isEmpty)
        #expect(PasswordHash.verify(password: "hunter2", record: stored))

        let status = await call(router, "web-password-get")
        #expect(status.result?["password_set"] == .bool(true))
        #expect(status.result?["iterations"] == .int(PasswordHash.defaultIterations))
        // The status read must never hand back the hash or salt.
        #expect(status.result?["hash_b64"] == nil)
        #expect(status.result?["salt_b64"] == nil)

        // Changing needs no old password, and re-salts rather than reusing.
        _ = await call(router, "web-password-set", ["password": .string("hunter3")])
        let changed = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.webAuth)
        #expect(changed.saltB64 != stored.saltB64)
        #expect(changed.hashB64 != stored.hashB64)

        let cleared = await call(router, "web-password-set", ["clear": .bool(true)])
        #expect(cleared.result?["password_set"] == .bool(false))
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.webAuth == nil)
    }

    @Test @MainActor func emptyPasswordIsRejected() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let response = await call(router, "web-password-set", ["password": .string("")])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.webAuth == nil)
    }

    @Test @MainActor func settingAPasswordLeavesGatewaysIntact() async throws {
        // Both surfaces read-modify-write the whole AppConfig; neither may drop
        // the other's field.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        _ = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-test-1")]),
        ])
        _ = await call(router, "web-password-set", ["password": .string("hunter2")])

        let stored = ConfigStore.loadConfig(devRoot: devRoot)
        #expect(stored?.managerGateway?.customHeaders["X-Api-Key"] == "sk-test-1")
        #expect(stored?.webAuth != nil)
    }

    /// The RPC path is gated by `SecretRoutes.buildGateway`, which the handler
    /// funnels every decoded header into (CROW-969). Asserting the *stored* config
    /// is untouched is the part that matters: a rejection that still wrote would
    /// be worse than no rejection.
    @Test @MainActor func gatewaySetRejectsQuoteWrappedHeaderEndToEnd() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        _ = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: sk-good")]),
        ])

        let response = await call(router, "gateway-set", [
            "target": .string("manager"),
            "base_url": .string("https://gw.example.com"),
            "header_lines": .array([.string("X-Api-Key: \"sk-quoted\"")]),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
        // The good value survives the rejected write.
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?
            .managerGateway?.customHeaders["X-Api-Key"] == "sk-good")
    }
}

/// Unit coverage for the param decode/encode helpers behind those handlers.
@Suite struct SecretsRPCSupportTests {
    @Test func decodeTargetAcceptsManagerAndWorkspace() throws {
        #expect(try SecretsRPC.decodeTarget(["target": .string("manager")]) == .manager)
        #expect(try SecretsRPC.decodeTarget(["workspace": .string("Corveil")])
            == .workspace("Corveil"))
    }

    @Test func decodeTargetRejectsUnknownTargetBothAndNeither() {
        #expect(throws: (any Error).self) {
            _ = try SecretsRPC.decodeTarget(["target": .string("workspace")])
        }
        #expect(throws: (any Error).self) {
            _ = try SecretsRPC.decodeTarget([
                "target": .string("manager"), "workspace": .string("Corveil"),
            ])
        }
        #expect(throws: (any Error).self) { _ = try SecretsRPC.decodeTarget([:]) }
    }

    @Test func decodeHeaderLinesSplitsOnFirstColon() throws {
        let headers = try SecretsRPC.decodeHeaderLines(.array([
            .string("X-Api-Key: sk-test-1"),
            .string("Authorization: Bearer a:b:c"),
        ]))
        #expect(headers == ["X-Api-Key": "sk-test-1", "Authorization": "Bearer a:b:c"])
    }

    /// Not "quoted values are fine" — ownership of that rule lives in
    /// `SecretRoutes.buildGateway`, which every entry decoded here flows into
    /// (CROW-969). Duplicating it here would shadow that message, so the CLI and
    /// the browser would report different text for the same mistake. The
    /// newline/colon checks stay because they are *line-shape* rules that must
    /// run before `parseHeaderLines` collapses lines into a map.
    @Test func decodeHeaderLinesLeavesQuoteRuleToBuildGateway() throws {
        let headers = try SecretsRPC.decodeHeaderLines(.array([
            .string("X-Api-Key: \"sk-quoted\""),
        ]))
        #expect(headers == ["X-Api-Key": "\"sk-quoted\""])
    }

    @Test func decodeHeaderLinesKeepsBlankValues() throws {
        // A blank value is the "keep the stored secret" signal — it must survive
        // decoding rather than being dropped as noise.
        #expect(try SecretsRPC.decodeHeaderLines(.array([.string("X-Api-Key:")]))
            == ["X-Api-Key": ""])
    }

    @Test func decodeHeaderLinesRejectsMalformedLines() {
        for line in ["no-colon", "  ", ": orphan-value"] {
            #expect(throws: (any Error).self, "expected '\(line)' to be rejected") {
                _ = try SecretsRPC.decodeHeaderLines(.array([.string(line)]))
            }
        }
    }

    @Test func decodeHeaderLinesRejectsEmbeddedNewlines() {
        // One entry must mean one header. Parsing splits on newlines, so an
        // embedded \n would smuggle a second header past the per-entry check.
        for line in ["X-Api-Key: sk-1\nX-Smuggled: evil", "X-Api-Key: sk-1\r\nX-Smuggled: evil"] {
            #expect(throws: (any Error).self, "expected an embedded newline to be rejected") {
                _ = try SecretsRPC.decodeHeaderLines(.array([.string(line)]))
            }
        }
    }

    @Test func decodeHeaderLinesDefaultsToEmpty() throws {
        #expect(try SecretsRPC.decodeHeaderLines(nil).isEmpty)
    }

    @Test func gatewayJSONBlanksValuesUnlessRevealing() {
        let gateway = WorkspaceGateway(
            baseURL: "https://gw.example.com", customHeaders: ["X-Api-Key": "sk-test-1"])

        let redacted = SecretsRPC.gatewayJSON(gateway, reveal: false)
        #expect(redacted["gateway_set"] == .bool(true))
        #expect(redacted["base_url"] == .string("https://gw.example.com"))
        #expect(redacted["headers"] == .object(["X-Api-Key": .string("")]))

        let revealed = SecretsRPC.gatewayJSON(gateway, reveal: true)
        #expect(revealed["headers"] == .object(["X-Api-Key": .string("sk-test-1")]))
    }

    @Test func gatewayJSONReportsAbsentGateway() {
        let json = SecretsRPC.gatewayJSON(nil, reveal: true)
        #expect(json["gateway_set"] == .bool(false))
        #expect(json["base_url"] == .string(""))
        #expect(json["headers"] == .object([:]))
    }

    @Test func resolveWorkspacePrefersUUIDThenName() throws {
        let first = WorkspaceInfo(name: "Corveil")
        let second = WorkspaceInfo(name: "Personal")
        let config = AppConfig(workspaces: [first, second])

        #expect(try SecretsRPC.resolveWorkspace(second.id.uuidString, in: config) == 1)
        #expect(try SecretsRPC.resolveWorkspace("PERSONAL", in: config) == 1)
        #expect(throws: (any Error).self) {
            _ = try SecretsRPC.resolveWorkspace("missing", in: config)
        }
    }

    @Test func resolveWorkspaceRejectsAmbiguousNames() {
        // Impossible through the UI (names are unique) but reachable in a
        // hand-edited config — better an error than a coin flip.
        let config = AppConfig(workspaces: [
            WorkspaceInfo(name: "Corveil"), WorkspaceInfo(name: "corveil"),
        ])
        #expect(throws: (any Error).self) {
            _ = try SecretsRPC.resolveWorkspace("Corveil", in: config)
        }
    }
}
