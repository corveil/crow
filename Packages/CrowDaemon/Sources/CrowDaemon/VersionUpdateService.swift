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
///
/// Single-flight like `ScorecardRebuilder`: overlapping callers await the
/// in-flight GitHub compare instead of spawning duplicate `gh auth token`
/// subprocesses.
@MainActor
final class VersionUpdateService {
    /// Minimum spacing between user-initiated forced checks ("Check now", CLI
    /// `--check`) so a remote `/rpc` peer can't burn the GitHub budget.
    static let minimumForcedSpacing: TimeInterval = 120

    private let shell: ShellRunner
    private let updateCommand: String
    private var buildInfo: BuildInfo
    private var lastCheckAt: Date?
    private var lastForcedCheckAt: Date?
    private var inFlight: Task<VersionUpdateStatus, Never>?

    var cachedStatus: VersionUpdateStatus?

    init(buildInfo: BuildInfo, shell: ShellRunner = ProcessShellRunner()) {
        self.buildInfo = buildInfo
        self.shell = shell
        self.updateCommand = "git -C <clone> pull && make install"
    }

    func replaceBuildInfo(_ info: BuildInfo) {
        buildInfo = info
    }

    /// Run a check when enabled and the interval has elapsed, or when `force`.
    func checkIfDue(enabled: Bool, intervalHours: Int, force: Bool = false) async -> VersionUpdateStatus? {
        guard enabled else { return cachedStatus }
        if !force, let lastCheckAt {
            let interval = TimeInterval(max(VersionUpdateConfig.minimumIntervalHours, intervalHours) * 3600)
            if Date().timeIntervalSince(lastCheckAt) < interval {
                return cachedStatus
            }
        }
        return await runCheck(force: force)
    }

    /// Force or schedule a compare. Overlapping callers coalesce onto one
    /// in-flight task; forced checks are throttled to `minimumForcedSpacing`.
    func runCheck(force: Bool = true) async -> VersionUpdateStatus {
        if let inFlight {
            return await inFlight.value
        }
        if force,
           let lastForcedCheckAt,
           Date().timeIntervalSince(lastForcedCheckAt) < Self.minimumForcedSpacing,
           let cachedStatus {
            return cachedStatus
        }

        let task = Task { @MainActor [self] in
            defer { self.inFlight = nil }
            let token = await Self.githubAuthToken(shell: shell)
            let status = await VersionUpdateClient.check(
                build: buildInfo,
                updateCommand: updateCommand,
                authToken: token
            )
            cachedStatus = status
            lastCheckAt = Date()
            if force { lastForcedCheckAt = Date() }
            return status
        }
        inFlight = task
        return await task.value
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
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: initialDelaySeconds * 1_000_000_000)
        while !Task.isCancelled {
            let config = ConfigStore.loadConfig(devRoot: devRoot)?.versionUpdate
                ?? VersionUpdateConfig()
            let before = service.cachedStatus
            let after = await service.checkIfDue(
                enabled: config.enabled, intervalHours: config.intervalHours)
            if after != before {
                await eventHub.broadcast()
            }
            let hours = max(VersionUpdateConfig.minimumIntervalHours, config.intervalHours)
            // Wake hourly so a lowered interval takes effect without waiting out
            // a long prior sleep.
            var remaining = hours * 3600
            while remaining > 0, !Task.isCancelled {
                let chunk = min(remaining, 3600)
                try? await Task.sleep(nanoseconds: UInt64(chunk) * 1_000_000_000)
                remaining -= chunk
                let refreshed = ConfigStore.loadConfig(devRoot: devRoot)?.versionUpdate
                    ?? VersionUpdateConfig()
                let refreshedHours = max(
                    VersionUpdateConfig.minimumIntervalHours, refreshed.intervalHours)
                let refreshedRemaining = refreshedHours * 3600
                if refreshedRemaining < remaining {
                    remaining = refreshedRemaining
                }
            }
        }
    }
}
