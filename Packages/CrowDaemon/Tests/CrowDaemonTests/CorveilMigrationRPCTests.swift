import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import Foundation
import Testing

@testable import CrowDaemon

/// The `corveil-link-gateway` handler's workspace targeting (CROW-1126 review):
/// it resolves `--workspace` through the shared `SecretsRPC.resolveWorkspace`, so a
/// UUID or a unique name both work and an unknown/ambiguous ref errors — the same
/// contract `crow gateway` has. Goes through the real router and reads back from
/// disk, so it also covers the offline adopt write end to end.
@Suite struct CorveilMigrationRPCTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-corveil-mig-\(UUID().uuidString)")
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

    /// A connection at `gw.corveil.example` plus one workspace whose gateway carries
    /// a manual `x-citadel-api-key` on that same host (so it is linkable).
    private func seededConfig(workspaceID: UUID) -> AppConfig {
        var config = AppConfig()
        config.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example", clientID: "cid",
            oauth: CorveilOAuthTokens(accessToken: "at"))
        config.workspaces = [
            WorkspaceInfo(
                id: workspaceID, name: "Acme",
                gateway: WorkspaceGateway(
                    baseURL: "https://gw.corveil.example",
                    customHeaders: ["x-citadel-api-key": "sk-citadel-Adopted"])),
        ]
        return config
    }

    @Test @MainActor func linkGatewayResolvesWorkspaceByUUID() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let workspaceID = UUID()
        try ConfigStore.saveConfig(seededConfig(workspaceID: workspaceID), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        // `--workspace <uuid>` — the shape name-only lookup would have rejected.
        let linked = await call(router, "corveil-link-gateway", [
            "workspace": .string(workspaceID.uuidString),
            "org_id": .string("org-9"),
        ])
        #expect(linked.error == nil)
        #expect(linked.result?["linked"] == .bool(true))
        // Response echoes the canonical name, not the raw ref.
        #expect(linked.result?["target_name"] == .string("Acme"))

        // The adopted key landed in the connection.
        let stored = ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection
        #expect(stored?.orgKeySecrets["org-9"] == "sk-citadel-Adopted")
    }

    @Test @MainActor func linkGatewayResolvesWorkspaceByName() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(seededConfig(workspaceID: UUID()), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        // Case-insensitive name still works, via the same resolver.
        let linked = await call(router, "corveil-link-gateway", [
            "workspace": .string("acme"),
            "org_id": .string("org-9"),
        ])
        #expect(linked.error == nil)
        #expect(linked.result?["target_name"] == .string("Acme"))
    }

    @Test @MainActor func linkGatewayRejectsUnknownWorkspace() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(seededConfig(workspaceID: UUID()), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        let linked = await call(router, "corveil-link-gateway", [
            "workspace": .string("does-not-exist"),
            "org_id": .string("org-9"),
        ])
        #expect(linked.error != nil)  // "Unknown workspace 'does-not-exist'"
    }

    @Test @MainActor func linkGatewayManagerTarget() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var config = seededConfig(workspaceID: UUID())
        config.managerGateway = WorkspaceGateway(
            baseURL: "https://gw.corveil.example",
            customHeaders: ["x-citadel-api-key": "sk-citadel-Mgr"])
        try ConfigStore.saveConfig(config, devRoot: devRoot)
        let router = router(devRoot: devRoot)

        let linked = await call(router, "corveil-link-gateway", [
            "target": .string("manager"),
            "org_id": .string("org-m"),
        ])
        #expect(linked.error == nil)
        #expect(linked.result?["target_name"] == .string("Manager"))
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?
            .orgKeySecrets["org-m"] == "sk-citadel-Mgr")
    }
}
