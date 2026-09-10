import CrowCore
import CrowEngine
import CrowPersistence
import Foundation
import Testing
@testable import CrowDaemon
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct CorveilAutoUpdateServiceTests {
    private let fakeHash = String(repeating: "ab", count: 32)

    private final class HitBox: @unchecked Sendable {
        var value: String?
    }
    private final class HitCount: @unchecked Sendable {
        var value = 0
    }

    private func tempDir(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        _ = data
        return fakeHash
    }

    private func assetName() -> String { CorveilAutoUpdate.assetName() }

    private func transport(binary: Data, checksums: String, tag: String = "v0.4.32")
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
    {
        let release: [String: Any] = [
            "tag_name": tag,
            "assets": [
                [
                    "name": assetName(),
                    "browser_download_url": "https://example.test/\(assetName())",
                    "size": binary.count,
                ],
                [
                    "name": "checksums.txt",
                    "browser_download_url": "https://example.test/checksums.txt",
                    "size": checksums.utf8.count,
                ],
            ],
        ]
        let releaseData = try! JSONSerialization.data(withJSONObject: release)
        return { request in
            let url = request.url?.absoluteString ?? ""
            let body: Data
            if url.contains("/releases/") {
                body = releaseData
            } else if url.contains("checksums.txt") {
                body = Data(checksums.utf8)
            } else {
                body = binary
            }
            return (body, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func hooks(
        verifyMessage: String = "corveil 0.4.32",
        verifyOK: Bool = true
    ) -> CorveilAutoUpdateService.Hooks {
        CorveilAutoUpdateService.Hooks(
            verify: { path in
                CorveilCLI.Outcome(ok: verifyOK, message: verifyMessage, path: path)
            },
            reinstall: { path, _ in
                CorveilCLI.Outcome(ok: true, message: "Skills reinstalled", path: path)
            },
            sha256Hex: sha256Hex,
            clearQuarantine: { _ in },
            replaceSymlink: { _, _, _ in true },
            now: Date.init)
    }

    @Test func skippedWhenOperatorOverrideIsSet() async throws {
        let devRoot = try tempDir("crowd-corveil-dev")
        let managed = try tempDir("crowd-corveil-bin")
        defer {
            try? FileManager.default.removeItem(at: devRoot)
            try? FileManager.default.removeItem(at: managed)
        }
        var config = AppConfig()
        #expect(config.defaults.corveilAutoUpdate)
        config.defaults.binaries["corveil"] = "/Users/jane/dev/corveil/out/corveil"
        try ConfigStore.saveConfig(config, devRoot: devRoot.path)

        let service = CorveilAutoUpdateService(
            devRoot: devRoot.path,
            managedRoot: managed,
            userAgent: "Crow/test",
            transport: transport(binary: Data("bin".utf8), checksums: ""),
            hooks: hooks())
        let status = await service.runCheck()
        #expect(status.state == .skippedOverride)
        #expect(ConfigStore.loadConfig(devRoot: devRoot.path)?.defaults.binaries["corveil"]
                == "/Users/jane/dev/corveil/out/corveil")
    }

    @Test func checksumMismatchKeepsLastGood() async throws {
        let devRoot = try tempDir("crowd-corveil-dev")
        let managed = try tempDir("crowd-corveil-bin")
        defer {
            try? FileManager.default.removeItem(at: devRoot)
            try? FileManager.default.removeItem(at: managed)
        }
        var config = AppConfig()
        config.defaults.corveilAutoUpdate = true
        try ConfigStore.saveConfig(config, devRoot: devRoot.path)

        let lastGood = CorveilAutoUpdate.binaryURL(tag: "v0.4.31", managedRoot: managed)
        try FileManager.default.createDirectory(
            at: lastGood.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: lastGood)

        let binary = Data("new-bytes".utf8)
        let checksums = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  \(assetName())\n"
        let service = CorveilAutoUpdateService(
            devRoot: devRoot.path,
            managedRoot: managed,
            userAgent: "Crow/test",
            transport: transport(binary: binary, checksums: checksums),
            hooks: hooks())
        let status = await service.runCheck()
        #expect(status.state == .failed)
        #expect(status.message?.contains("Checksum mismatch") == true)
        #expect(FileManager.default.fileExists(atPath: lastGood.path))
        #expect(ConfigStore.loadConfig(devRoot: devRoot.path)?.defaults.binaries["corveil"] == nil)
    }

    @Test func successfulDownloadLinksManagedBinary() async throws {
        let devRoot = try tempDir("crowd-corveil-dev")
        let managed = try tempDir("crowd-corveil-bin")
        defer {
            try? FileManager.default.removeItem(at: devRoot)
            try? FileManager.default.removeItem(at: managed)
        }
        var config = AppConfig()
        config.defaults.corveilAutoUpdate = true
        try ConfigStore.saveConfig(config, devRoot: devRoot.path)

        let binary = Data("corveil-fixture".utf8)
        let checksums = "\(fakeHash)  \(assetName())\n"
        let linked = HitBox()
        var hooks = hooks()
        hooks.replaceSymlink = { _, _, target in
            linked.value = target
            return true
        }
        let service = CorveilAutoUpdateService(
            devRoot: devRoot.path,
            managedRoot: managed,
            userAgent: "Crow/test",
            transport: transport(binary: binary, checksums: checksums),
            hooks: hooks)
        let status = await service.runCheck()
        #expect(status.state == .updated)
        #expect(status.version == "v0.4.32")
        let dest = CorveilAutoUpdate.binaryURL(tag: "v0.4.32", managedRoot: managed)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == binary)
        #expect(linked.value == dest.path)
        #expect(ConfigStore.loadConfig(devRoot: devRoot.path)?.defaults.binaries["corveil"]
                == dest.path)
    }

    @Test func disabledDoesNotFetch() async throws {
        let devRoot = try tempDir("crowd-corveil-dev")
        let managed = try tempDir("crowd-corveil-bin")
        defer {
            try? FileManager.default.removeItem(at: devRoot)
            try? FileManager.default.removeItem(at: managed)
        }
        let hits = HitCount()
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            hits.value += 1
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let service = CorveilAutoUpdateService(
            devRoot: devRoot.path,
            managedRoot: managed,
            userAgent: "Crow/test",
            transport: transport,
            hooks: hooks())
        let status = await service.checkIfDue(enabled: false, intervalHours: 1)
        #expect(status.state == .disabled)
        #expect(hits.value == 0)
    }

    @Test func explicitFalseInConfigDoesNotFetch() async throws {
        let devRoot = try tempDir("crowd-corveil-dev")
        let managed = try tempDir("crowd-corveil-bin")
        defer {
            try? FileManager.default.removeItem(at: devRoot)
            try? FileManager.default.removeItem(at: managed)
        }
        var config = AppConfig()
        config.defaults.corveilAutoUpdate = false
        try ConfigStore.saveConfig(config, devRoot: devRoot.path)

        let hits = HitCount()
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            hits.value += 1
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let service = CorveilAutoUpdateService(
            devRoot: devRoot.path,
            managedRoot: managed,
            userAgent: "Crow/test",
            transport: transport,
            hooks: hooks())
        let status = await service.runCheck()
        #expect(status.state == .disabled)
        #expect(hits.value == 0)
    }
}
