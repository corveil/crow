import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

@Suite struct VersionUpdateHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-version-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func router(devRoot: String, service: VersionUpdateService) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil, versionUpdateService: service)
    }

    @MainActor
    private func call(
        _ method: String, _ params: [String: JSONValue] = [:],
        devRoot: String, service: VersionUpdateService
    ) async -> JSONRPCResponse {
        await router(devRoot: devRoot, service: service)
            .handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    @Test @MainActor func getReturnsDefaultsWhenNoConfigExists() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let service = VersionUpdateService(
            buildInfo: BuildInfo(version: "0.1.0", gitSha: "abc1234", buildDate: "2026-08-05"),
            devRoot: devRoot)
        let resp = await call("version-update-get", devRoot: devRoot, service: service)
        #expect(resp.result?["version_update"] == .object([
            "enabled": .bool(true), "interval_hours": .int(6),
        ]))
        #expect(resp.result?["status"] == .null)
    }

    @Test @MainActor func setPatchesOnlyProvidedFields() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.versionUpdate = VersionUpdateConfig(enabled: true, intervalHours: 12)
        try ConfigStore.saveConfig(seed, devRoot: devRoot)
        let service = VersionUpdateService(
            buildInfo: BuildInfo(version: "0.1.0", gitSha: "abc1234", buildDate: "2026-08-05"),
            devRoot: devRoot)

        let resp = await call(
            "version-update-set", ["enabled": .bool(false)], devRoot: devRoot, service: service)
        #expect(resp.result?["version_update"] == .object([
            "enabled": .bool(false), "interval_hours": .int(12),
        ]))
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.versionUpdate.enabled == false)
        #expect(onDisk.versionUpdate.intervalHours == 12)
    }

    @Test @MainActor func checkReturnsCachedStatus() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let service = VersionUpdateService(
            buildInfo: BuildInfo(version: "0.1.0", gitSha: "dev", buildDate: "2026-08-05"),
            devRoot: devRoot)
        let checked = await service.runCheck()
        let resp = await call("version-update-check", devRoot: devRoot, service: service)
        #expect(resp.result?["status"]?.objectValue?["state"]?.stringValue
            == checked.state.rawValue)
    }
}
