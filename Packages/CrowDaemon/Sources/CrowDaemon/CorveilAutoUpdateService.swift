import CrowCore
import CrowEngine
import CrowPersistence
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Periodic download/verify/link of the host-platform `corveil` CLI from
/// `corveil/corveil-releases` (CROW-1210).
///
/// Failures never throw and never break startup: the last-good binary stays
/// linked and a warning is logged. An operator-set `binaries["corveil"]`
/// outside the managed dir is never overwritten.
actor CorveilAutoUpdateService {
    struct Hooks: Sendable {
        var verify: @Sendable (String) -> CorveilCLI.Outcome
        var reinstall: @Sendable (String, String) -> CorveilCLI.Outcome
        var sha256Hex: @Sendable (Data) -> String
        var clearQuarantine: @Sendable (String) -> Void
        var replaceSymlink: @Sendable (String, String, String) -> Bool
        var now: @Sendable () -> Date

        static var live: Hooks {
            Hooks(
                verify: { CorveilCLI.verify(path: $0) },
                reinstall: { CorveilCLI.reinstallSkill(path: $0, devRoot: $1) },
                sha256Hex: { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
                clearQuarantine: { CorveilAutoUpdate.clearQuarantine(at: $0) },
                replaceSymlink: { devRoot, name, target in
                    Scaffolder(devRoot: devRoot).replaceBinarySymlink(name: name, target: target)
                },
                now: Date.init)
        }
    }

    private let devRoot: String
    private let managedRoot: URL
    private let userAgent: String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let hooks: Hooks
    private let onSkillWarning: @Sendable (String?) async -> Void
    private var lastCheckAt: Date?
    var cachedStatus: CorveilAutoUpdateStatus?

    init(
        devRoot: String,
        managedRoot: URL,
        userAgent: String,
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        hooks: Hooks = .live,
        onSkillWarning: @escaping @Sendable (String?) async -> Void = { _ in }
    ) {
        self.devRoot = devRoot
        self.managedRoot = managedRoot
        self.userAgent = userAgent
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
        self.hooks = hooks
        self.onSkillWarning = onSkillWarning
    }

    /// Run when enabled and the interval has elapsed, or when `force`.
    func checkIfDue(enabled: Bool, intervalHours: Int, force: Bool = false) async -> CorveilAutoUpdateStatus {
        guard enabled else {
            let status = CorveilAutoUpdateStatus(
                state: .disabled,
                checkedAtMs: currentTimeMs())
            cachedStatus = status
            return status
        }
        if !force, let lastCheckAt {
            let interval = TimeInterval(max(VersionUpdateConfig.minimumIntervalHours, intervalHours) * 3600)
            if hooks.now().timeIntervalSince(lastCheckAt) < interval, let cachedStatus {
                return cachedStatus
            }
        }
        return await runCheck()
    }

    /// True until the first `runCheck` (success or fail). Used by the poll so
    /// turning auto-update on mid-sleep does not wait out the leftover interval.
    func hasCompletedACheck() -> Bool { lastCheckAt != nil }

    func runCheck() async -> CorveilAutoUpdateStatus {
        let status = await performCheck()
        cachedStatus = status
        lastCheckAt = hooks.now()
        return status
    }

    private func performCheck() async -> CorveilAutoUpdateStatus {
        let checkedAt = currentTimeMs()
        let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
        guard config.defaults.corveilAutoUpdate else {
            return CorveilAutoUpdateStatus(state: .disabled, checkedAtMs: checkedAt)
        }
        let configured = config.defaults.binaries["corveil"]
        guard CorveilAutoUpdate.shouldAutoManage(
            configuredPath: configured, managedRoot: managedRoot
        ) else {
            CrowLog.info("[CorveilAutoUpdate] skipped — binaries[\"corveil\"] is an operator override")
            return CorveilAutoUpdateStatus(
                state: .skippedOverride,
                path: configured,
                message: "Operator-set corveil path is left alone",
                checkedAtMs: checkedAt)
        }

        let release: CorveilReleaseClient.Release
        do {
            release = try await CorveilReleaseClient.fetchRelease(
                version: config.defaults.corveilVersion,
                userAgent: userAgent,
                transport: transport)
        } catch {
            return failed("Could not fetch corveil-releases: \(describe(error))", checkedAt: checkedAt)
        }

        let dest = CorveilAutoUpdate.binaryURL(tag: release.tag, managedRoot: managedRoot)
        if FileManager.default.isExecutableFile(atPath: dest.path),
           configured.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == dest.path {
            let outcome = hooks.verify(dest.path)
            if outcome.ok, CorveilAutoUpdate.verifyMessage(outcome.message, matchesTag: release.tag) {
                return CorveilAutoUpdateStatus(
                    state: .upToDate,
                    version: release.tag,
                    path: dest.path,
                    message: outcome.message,
                    checkedAtMs: checkedAt)
            }
        }

        let assetName = CorveilAutoUpdate.assetName()
        guard assetName.contains("darwin") || assetName.contains("linux"),
              !assetName.contains("unsupported") else {
            return failed("Unsupported platform for corveil auto-update (\(assetName))", checkedAt: checkedAt)
        }
        guard let binaryAsset = release.asset(named: assetName) else {
            return failed("Release \(release.tag) has no \(assetName) asset", checkedAt: checkedAt)
        }
        guard let checksumAsset = release.asset(named: CorveilAutoUpdate.checksumsAssetName) else {
            return failed("Release \(release.tag) has no checksums.txt", checkedAt: checkedAt)
        }
        if binaryAsset.size > CorveilAutoUpdate.maxAssetBytes {
            return failed(
                "\(assetName) is \(binaryAsset.size) bytes, over the \(CorveilAutoUpdate.maxAssetBytes) cap",
                checkedAt: checkedAt)
        }

        let checksumsData: Data
        let binaryData: Data
        do {
            checksumsData = try await CorveilReleaseClient.download(
                url: checksumAsset.downloadURL, userAgent: userAgent, transport: transport)
            binaryData = try await CorveilReleaseClient.download(
                url: binaryAsset.downloadURL, userAgent: userAgent, transport: transport)
        } catch {
            return failed("Download failed: \(describe(error))", checkedAt: checkedAt)
        }

        let table = CorveilAutoUpdate.parseChecksums(
            String(data: checksumsData, encoding: .utf8) ?? "")
        guard let expected = table[assetName] else {
            return failed("checksums.txt has no entry for \(assetName)", checkedAt: checkedAt)
        }
        let actual = hooks.sha256Hex(binaryData)
        guard actual == expected else {
            return failed(
                "Checksum mismatch for \(assetName): got \(actual), expected \(expected)",
                checkedAt: checkedAt)
        }

        let fm = FileManager.default
        let versionDir = CorveilAutoUpdate.versionDirectory(tag: release.tag, managedRoot: managedRoot)
        do {
            try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: versionDir.path)
        } catch {
            return failed("Could not create managed dir: \(error.localizedDescription)", checkedAt: checkedAt)
        }

        let partial = versionDir.appendingPathComponent("\(CorveilAutoUpdate.binaryFileName).partial")
        do {
            try binaryData.write(to: partial, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
        } catch {
            try? fm.removeItem(at: partial)
            return failed("Could not write download: \(error.localizedDescription)", checkedAt: checkedAt)
        }
        hooks.clearQuarantine(partial.path)

        let outcome = hooks.verify(partial.path)
        guard outcome.ok else {
            try? fm.removeItem(at: partial)
            return failed("Downloaded binary failed verify: \(outcome.message)", checkedAt: checkedAt)
        }
        guard CorveilAutoUpdate.verifyMessage(outcome.message, matchesTag: release.tag) else {
            try? fm.removeItem(at: partial)
            return failed(
                "Downloaded binary reported '\(outcome.message)', expected \(release.tag)",
                checkedAt: checkedAt)
        }

        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: partial, to: dest)
        } catch {
            try? fm.removeItem(at: partial)
            return failed("Could not install binary: \(error.localizedDescription)", checkedAt: checkedAt)
        }
        hooks.clearQuarantine(dest.path)

        do {
            try mutateConfig(devRoot: devRoot) { config in
                config.defaults.binaries["corveil"] = dest.path
            }
        } catch {
            return failed("Installed \(release.tag) but could not persist path: \(error.localizedDescription)",
                          version: release.tag, path: dest.path, checkedAt: checkedAt)
        }

        let linked = hooks.replaceSymlink(devRoot, "corveil", dest.path)
        if !linked {
            CrowLog.info("[CorveilAutoUpdate] symlink update failed; binaries[\"corveil\"] still points at \(dest.path)")
        }
        let skill = hooks.reinstall(dest.path, devRoot)
        await onSkillWarning(skill.ok ? nil : skill.message)

        CorveilAutoUpdate.pruneOldVersions(keeping: release.tag, managedRoot: managedRoot)
        CrowLog.info("[CorveilAutoUpdate] linked \(release.tag) at \(dest.path)")
        return CorveilAutoUpdateStatus(
            state: .updated,
            version: release.tag,
            path: dest.path,
            message: outcome.message,
            checkedAtMs: checkedAt)
    }

    private func failed(
        _ message: String,
        version: String? = nil,
        path: String? = nil,
        checkedAt: Int64
    ) -> CorveilAutoUpdateStatus {
        CrowLog.info("[CorveilAutoUpdate] \(message)")
        return CorveilAutoUpdateStatus(
            state: .failed, version: version, path: path, message: message, checkedAtMs: checkedAt)
    }

    private func describe(_ error: Error) -> String {
        if let fetch = error as? CorveilReleaseClient.FetchError {
            switch fetch {
            case .http(let code): return "HTTP \(code)"
            case .transport(let msg): return msg
            case .decode: return "Unexpected GitHub response"
            case .invalidURL: return "Invalid GitHub URL"
            case .assetMissing(let name): return "Missing asset \(name)"
            case .assetTooLarge(let n): return "Asset too large (\(n) bytes)"
            }
        }
        return error.localizedDescription
    }

    private func currentTimeMs() -> Int64 {
        Int64(hooks.now().timeIntervalSince1970 * 1000)
    }
}

/// Drive `CorveilAutoUpdateService.checkIfDue` on the same interval as the
/// Crow self-update check (`versionUpdate.intervalHours`).
func startCorveilAutoUpdatePoll(
    service: CorveilAutoUpdateService,
    devRoot: String,
    eventHub: EventHub,
    initialDelaySeconds: UInt64 = 5
) {
    Task {
        try? await Task.sleep(nanoseconds: initialDelaySeconds * 1_000_000_000)
        while !Task.isCancelled {
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let before = await service.cachedStatus
            let after = await service.checkIfDue(
                enabled: config.defaults.corveilAutoUpdate,
                intervalHours: config.versionUpdate.intervalHours)
            if after != before {
                await eventHub.broadcast()
            }
            let hours = max(VersionUpdateConfig.minimumIntervalHours, config.versionUpdate.intervalHours)
            var remaining = hours * 3600
            while remaining > 0, !Task.isCancelled {
                let chunk = min(remaining, 60)
                try? await Task.sleep(nanoseconds: UInt64(chunk) * 1_000_000_000)
                remaining -= chunk
                let refreshed = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                if refreshed.defaults.corveilAutoUpdate, !(await service.hasCompletedACheck()) {
                    remaining = 0
                    break
                }
                let refreshedHours = max(
                    VersionUpdateConfig.minimumIntervalHours, refreshed.versionUpdate.intervalHours)
                let refreshedRemaining = refreshedHours * 3600
                if refreshedRemaining < remaining {
                    remaining = refreshedRemaining
                }
            }
        }
    }
}
