import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// End-to-end coverage of the CROW-2841 managed / design-partner workspace
/// creation defaults, through the real router against a temp `config.json`.
///
/// A new workspace on a managed install (a Corveil connection with one provisioned
/// org) defaults to that org's gateway + session log-sync, so the audit plane is
/// true by default; a self-hosted OSS install (no connection) keeps today's
/// opt-in-off behavior. Both creation surfaces are exercised: `workspace-add` (the
/// CLI path) and `set-config` (the web "Add workspace" path, which ships the whole
/// config). The pure resolution logic is pinned in
/// `CrowCoreTests.ManagedWorkspaceDefaultsTests`.
@Suite struct ManagedWorkspaceDefaultsHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-managed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func call(
        _ method: String, _ params: [String: JSONValue] = [:], devRoot: String
    ) async -> JSONRPCResponse {
        let router = makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
        return await router.handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    private func workspaces(_ devRoot: String) -> [WorkspaceInfo] {
        ConfigStore.loadConfig(devRoot: devRoot)?.workspaces ?? []
    }

    private func named(_ devRoot: String) -> [String: WorkspaceInfo] {
        Dictionary(uniqueKeysWithValues: workspaces(devRoot).map { ($0.name, $0) })
    }

    /// A managed install: connected to Corveil with a single provisioned org whose
    /// gateway derives to `https://gw.corveil.example` + `sk-citadel-AbCdEf`.
    private func managedConfig() -> AppConfig {
        var c = AppConfig()
        c.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example",
            clientID: "cid",
            orgKeys: [CorveilOrgKey(orgID: "org-1", orgName: "Acme")],
            orgKeySecrets: ["org-1": "sk-citadel-AbCdEf"],
            oauth: CorveilOAuthTokens(accessToken: "at"))
        return c
    }

    // MARK: - workspace-add (CLI path)

    @Test @MainActor func addOnManagedInstallBindsGatewayAndEnablesLogSync() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(managedConfig(), devRoot: devRoot)

        let resp = await call("workspace-add", ["name": .string("Acme")], devRoot: devRoot)
        #expect(resp.error == nil)
        // The response reports the binding without ever exposing the key.
        #expect(resp.result?["workspace"]?.objectValue?["gateway_set"] == .bool(true))
        #expect(resp.result?["workspace"]?.objectValue?["upload_session_logs"] == .bool(true))

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway?.baseURL == "https://gw.corveil.example")
        #expect(stored.gateway?.customHeaders == ["x-citadel-api-key": "sk-citadel-AbCdEf"])
        #expect(stored.uploadSessionLogs)
    }

    @Test @MainActor func addOnOSSInstallLeavesDefaultsOff() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // No config at all — the fresh OSS install.

        let resp = await call("workspace-add", ["name": .string("Acme")], devRoot: devRoot)
        #expect(resp.error == nil)

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway == nil)
        #expect(stored.uploadSessionLogs == false)
    }

    @Test @MainActor func addRespectsExplicitUploadOptOutButStillBindsGateway() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(managedConfig(), devRoot: devRoot)

        let resp = await call(
            "workspace-add",
            ["name": .string("Acme"), "upload_session_logs": .bool(false)],
            devRoot: devRoot)
        #expect(resp.error == nil)

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway?.customHeaders == ["x-citadel-api-key": "sk-citadel-AbCdEf"])
        #expect(stored.uploadSessionLogs == false)  // explicit --upload-session-logs false honored
    }

    @Test @MainActor func addWithMultipleProvisionedOrgsIsAmbiguousSoOff() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var config = managedConfig()
        config.corveilConnection?.orgKeys.append(CorveilOrgKey(orgID: "org-2", orgName: "Beta"))
        config.corveilConnection?.orgKeySecrets["org-2"] = "sk-citadel-Second"
        try ConfigStore.saveConfig(config, devRoot: devRoot)

        _ = await call("workspace-add", ["name": .string("Acme")], devRoot: devRoot)

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway == nil)
        #expect(stored.uploadSessionLogs == false)
    }

    // MARK: - set-config (web path)

    @Test @MainActor func setConfigDefaultsANewManagedWorkspaceOnly() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // Stored: a managed install with one existing workspace the operator has
        // deliberately not opted into anything.
        var stored = managedConfig()
        let existing = WorkspaceInfo(name: "Existing")
        stored.workspaces = [existing]
        try ConfigStore.saveConfig(stored, devRoot: devRoot)

        // Incoming, as a browser sends it: the existing workspace plus a brand-new
        // one, connection secrets stripped (restored server-side by preservingSecrets).
        var incoming = AppConfig()
        incoming.workspaces = [existing, WorkspaceInfo(name: "New")]
        let json = try #require(String(data: JSONEncoder().encode(incoming), encoding: .utf8))

        let resp = await call("set-config", ["config": .string(json)], devRoot: devRoot)
        #expect(resp.error == nil)

        let after = named(devRoot)
        // The genuinely-new workspace is bound + opted in.
        #expect(after["New"]?.gateway?.customHeaders == ["x-citadel-api-key": "sk-citadel-AbCdEf"])
        #expect(after["New"]?.uploadSessionLogs == true)
        // The pre-existing workspace is left exactly as the operator had it, so a
        // prior opt-out is never re-flipped.
        #expect(after["Existing"]?.gateway == nil)
        #expect(after["Existing"]?.uploadSessionLogs == false)
    }

    @Test @MainActor func setConfigOnOSSInstallLeavesNewWorkspaceOff() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        var incoming = AppConfig()
        incoming.workspaces = [WorkspaceInfo(name: "New")]
        let json = try #require(String(data: JSONEncoder().encode(incoming), encoding: .utf8))

        let resp = await call("set-config", ["config": .string(json)], devRoot: devRoot)
        #expect(resp.error == nil)

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway == nil)
        #expect(stored.uploadSessionLogs == false)
    }

    // MARK: - set-config, hostile blobs (CROW-2841 review)

    @Test @MainActor func setConfigOverwritesACraftedGatewayOnANewManagedWorkspace() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(managedConfig(), devRoot: devRoot)

        // A crafted blob plants a hostile gateway on a brand-new workspace id — the
        // web never authors one there, so `preservingSecrets` must not trust it and
        // the managed bind must win, or log-sync would redirect to the attacker.
        var incoming = AppConfig()
        var planted = WorkspaceInfo(name: "New")
        planted.gateway = WorkspaceGateway(
            baseURL: "https://evil.example", customHeaders: ["x-citadel-api-key": "sk-attacker"])
        incoming.workspaces = [planted]
        let json = try #require(String(data: JSONEncoder().encode(incoming), encoding: .utf8))

        let resp = await call("set-config", ["config": .string(json)], devRoot: devRoot)
        #expect(resp.error == nil)

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway?.baseURL == "https://gw.corveil.example")
        #expect(stored.gateway?.customHeaders == ["x-citadel-api-key": "sk-citadel-AbCdEf"])
        #expect(stored.uploadSessionLogs)
    }

    @Test @MainActor func setConfigDropsACraftedGatewayOnOSSSoNothingUploads() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // An OSS install with a stored (empty) config, so the `current != nil` merge
        // branch runs — the one that must nil a new id's gateway.
        try ConfigStore.saveConfig(AppConfig(), devRoot: devRoot)

        // Crafted: a planted gateway AND a pre-flipped log-sync flag on a new id.
        var incoming = AppConfig()
        var planted = WorkspaceInfo(name: "New")
        planted.gateway = WorkspaceGateway(
            baseURL: "https://evil.example", customHeaders: ["x-citadel-api-key": "sk-attacker"])
        planted.uploadSessionLogs = true
        incoming.workspaces = [planted]
        let json = try #require(String(data: JSONEncoder().encode(incoming), encoding: .utf8))

        let resp = await call("set-config", ["config": .string(json)], devRoot: devRoot)
        #expect(resp.error == nil)

        // The gateway is dropped, so the collector has no destination even though the
        // crafted flag persisted — the exfil target is gone.
        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.gateway == nil)
    }
}
