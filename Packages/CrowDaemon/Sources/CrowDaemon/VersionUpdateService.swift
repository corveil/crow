import CrowCore
import CrowEngine
import CrowPersistence
import Foundation

/// Loads `version.json` from the daemon bundle or a live `--web-dir`.
enum BuildInfoLoader {
    static func load(webDir: String?) -> BuildInfo? {
        if let webDir {
            let url = URL(fileURLWithPath: webDir).appendingPathComponent("version.json")
            if let data = try? Data(contentsOf: url), let info = decode(data) { return info }
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "version", withExtension: "json", subdirectory: "web"),
           let data = try? Data(contentsOf: url), let info = decode(data) {
            return info
        }
        #endif
        return nil
    }

    private static func decode(_ data: Data) -> BuildInfo? {
        try? JSONDecoder().decode(BuildInfo.self, from: data)
    }
}

/// Periodic upstream version check owned by `crowd` (CROW-938).
@MainActor
final class VersionUpdateService {
    private let shell: ShellRunner
    private let updateCommand: String
    private var buildInfo: BuildInfo
    private var lastCheckAt: Date?
    private var inFlight = false

    var cachedStatus: VersionUpdateStatus?

    init(buildInfo: BuildInfo, devRoot: String, shell: ShellRunner = ProcessShellRunner()) {
        self.buildInfo = buildInfo
        self.shell = shell
        self.updateCommand = "git -C <clone> pull && make install"
        _ = devRoot // reserved for a future smarter clone hint
    }

    func replaceBuildInfo(_ info: BuildInfo) {
        buildInfo = info
    }

    /// Run a check when enabled and the interval has elapsed, or when `force`.
    func checkIfDue(enabled: Bool, intervalHours: Int, force: Bool = false) async -> VersionUpdateStatus? {
        guard enabled else {
            cachedStatus = nil
            return nil
        }
        if !force, let lastCheckAt {
            let interval = TimeInterval(max(VersionUpdateConfig.minimumIntervalHours, intervalHours) * 3600)
            if Date().timeIntervalSince(lastCheckAt) < interval {
                return cachedStatus
            }
        }
        return await runCheck()
    }

    func runCheck() async -> VersionUpdateStatus {
        if inFlight, let cachedStatus { return cachedStatus }
        inFlight = true
        defer { inFlight = false }

        let token = await Self.githubAuthToken(shell: shell)
        let status = await VersionUpdateClient.check(
            build: buildInfo,
            updateCommand: updateCommand,
            authToken: token
        )
        cachedStatus = status
        lastCheckAt = Date()
        return status
    }

    private static func githubAuthToken(shell: ShellRunner) async -> String? {
        guard let output = try? await shell.run("gh", "auth", "token") else { return nil }
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

/// Drive `VersionUpdateService.checkIfDue` on an explicit async loop.
func startVersionUpdatePoll(
    service: VersionUpdateService,
    devRoot: String,
    eventHub: EventHub,
    initialDelaySeconds: UInt64 = 5
) {
    Task {
        try? await Task.sleep(nanoseconds: initialDelaySeconds * 1_000_000_000)
        while !Task.isCancelled {
            let config = ConfigStore.loadConfig(devRoot: devRoot)?.versionUpdate ?? VersionUpdateConfig()
            let before = await service.cachedStatus
            let after = await service.checkIfDue(
                enabled: config.enabled, intervalHours: config.intervalHours)
            if after != before {
                await eventHub.broadcast()
            }
            let hours = max(VersionUpdateConfig.minimumIntervalHours, config.intervalHours)
            try? await Task.sleep(nanoseconds: UInt64(hours) * 3_600 * 1_000_000_000)
        }
    }
}
