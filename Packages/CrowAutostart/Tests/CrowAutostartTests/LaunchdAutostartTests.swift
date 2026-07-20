import Testing
import Foundation
@testable import CrowAutostart

// MARK: - Harness

/// Records every `launchctl` invocation and replays canned results, so the
/// install/uninstall/status logic is exercised without touching the real
/// `~/Library/LaunchAgents` or spawning launchd.
final class FakeLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    /// Exit status per subcommand (`bootout`, `bootstrap`, `kickstart`, `print`).
    var statuses: [String: Int32] = ["bootout": 0, "bootstrap": 0, "kickstart": 0, "print": 0]

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var subcommands: [String] { calls.compactMap(\.first) }

    func runner() -> CommandRunner {
        { [self] _, arguments in
            lock.lock()
            _calls.append(arguments)
            lock.unlock()
            let status = statuses[arguments.first ?? ""] ?? 0
            return CommandResult(status: status, output: status == 0 ? "" : "no such process")
        }
    }
}

/// A LaunchdAutostart rooted in a temp directory.
private func makeService(
    root: URL,
    launchctl: FakeLaunchctl,
    running: Bool = false
) -> LaunchdAutostart {
    LaunchdAutostart(
        launchAgentsDirectory: root.appendingPathComponent("LaunchAgents"),
        logDirectory: root.appendingPathComponent("Logs/crow"),
        uid: 501,
        runner: launchctl.runner(),
        isDaemonRunning: { _ in running }
    )
}

/// A service whose probe reports "running" only for one specific socket path,
/// and records the paths it was asked about.
private final class SocketProbeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String?] = []
    let liveSocket: String?

    init(liveSocket: String?) { self.liveSocket = liveSocket }

    var asked: [String?] { lock.lock(); defer { lock.unlock() }; return _asked }

    func service(root: URL, launchctl: FakeLaunchctl) -> LaunchdAutostart {
        LaunchdAutostart(
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents"),
            logDirectory: root.appendingPathComponent("Logs/crow"),
            uid: 501,
            runner: launchctl.runner(),
            isDaemonRunning: { [self] socket in
                lock.lock(); _asked.append(socket); lock.unlock()
                return socket == liveSocket
            }
        )
    }
}

/// A file that passes the "executable file" check, standing in for `crowd`.
private func makeFakeBinary(in directory: URL, named name: String = "crowd") throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crow-autostart-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readPlist(_ service: LaunchdAutostart) throws -> [String: Any] {
    let data = try #require(FileManager.default.contents(atPath: service.plistURL.path))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(plist as? [String: Any])
}

// MARK: - Spec

@Test func specBuildsProgramArgumentsFromDaemonFlags() {
    let spec = AutostartSpec(
        binaryPath: "/usr/local/bin/crowd",
        host: "127.0.0.1",
        httpPort: 8787,
        devRoot: "/Users/jane/Dev",
        socketPath: "/tmp/crow.sock")
    #expect(spec.programArguments == [
        "/usr/local/bin/crowd",
        "--host", "127.0.0.1",
        "--http-port", "8787",
        "--dev-root", "/Users/jane/Dev",
        "--socket", "/tmp/crow.sock",
    ])
}

@Test func specOmitsUnsetFlags() {
    let spec = AutostartSpec(binaryPath: "/usr/local/bin/crowd")
    #expect(spec.programArguments == ["/usr/local/bin/crowd"])
}

// MARK: - Plist contents

@Test func installWritesPlistWithExpectedKeys() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    let service = makeService(root: root, launchctl: launchctl)

    _ = try service.install(AutostartSpec(binaryPath: binary, host: "127.0.0.1", httpPort: 8787))

    let plist = try readPlist(service)
    #expect(plist["Label"] as? String == "com.corveil.crowd")
    #expect(plist["ProgramArguments"] as? [String] == [binary, "--host", "127.0.0.1", "--http-port", "8787"])
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["ProcessType"] as? String == "Background")
    #expect(plist["StandardOutPath"] as? String == service.logURL.path)
    #expect(plist["StandardErrorPath"] as? String == service.logURL.path)
    // The PATH launchd hands an agent is too bare for git/gh/tmux.
    let path = try #require((plist["EnvironmentVariables"] as? [String: String])?["PATH"])
    #expect(path.contains("/usr/bin"))
}

/// crowd exits(1) — a *clean* exit — when another instance holds the socket or
/// store lock. `SuccessfulExit: false` would respawn it forever; `Crashed`
/// restarts only on an actual crash.
@Test func keepAliveRestartsOnCrashOnly() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let service = makeService(root: root, launchctl: FakeLaunchctl())

    _ = try service.install(AutostartSpec(binaryPath: binary))

    let keepAlive = try #require(try readPlist(service)["KeepAlive"] as? [String: Bool])
    #expect(keepAlive == ["Crashed": true])
}

@Test func installWritesXMLPlistSoItStaysReadable() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let service = makeService(root: root, launchctl: FakeLaunchctl())

    _ = try service.install(AutostartSpec(binaryPath: binary))

    let data = try #require(FileManager.default.contents(atPath: service.plistURL.path))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.hasPrefix("<?xml"))
    #expect(text.contains("com.corveil.crowd"))
}

// MARK: - Install behavior

@Test func installBootstrapsAndStartsWhenNoDaemonIsRunning() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    let service = makeService(root: root, launchctl: launchctl, running: false)

    let status = try service.install(AutostartSpec(binaryPath: binary))

    #expect(launchctl.subcommands.contains("bootout"))
    #expect(launchctl.subcommands.contains("bootstrap"))
    #expect(launchctl.subcommands.contains("kickstart"))
    #expect(status.enabled)
    #expect(status.message.contains("crowd started"))
}

/// Bootstrapping alongside a running daemon would spawn a duplicate that
/// immediately refuses to start (single-instance + store-writer locks), and
/// booting out would kill a daemon that's currently serving. Write the plist
/// and let the next login pick it up.
@Test func installLeavesLaunchdAloneWhenDaemonIsAlreadyRunning() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    let service = makeService(root: root, launchctl: launchctl, running: true)

    let status = try service.install(AutostartSpec(binaryPath: binary))

    #expect(!launchctl.subcommands.contains("bootstrap"))
    #expect(!launchctl.subcommands.contains("bootout"))
    #expect(!launchctl.subcommands.contains("kickstart"))
    #expect(status.enabled)
    #expect(status.message.contains("next login"))
}

@Test func installIsIdempotent() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    let service = makeService(root: root, launchctl: launchctl)
    let spec = AutostartSpec(binaryPath: binary)

    _ = try service.install(spec)
    let first = try readPlist(service)
    let status = try service.install(spec)
    let second = try readPlist(service)

    #expect(first["ProgramArguments"] as? [String] == second["ProgramArguments"] as? [String])
    #expect(status.enabled)
    #expect(!status.stale)
}

/// A previous registration that fails to boot out ("not loaded") is the normal
/// first-install case — it must not abort the install.
@Test func installToleratesBootoutFailure() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    launchctl.statuses["bootout"] = 3
    let service = makeService(root: root, launchctl: launchctl)

    let status = try service.install(AutostartSpec(binaryPath: binary))

    #expect(status.enabled)
}

@Test func installThrowsWhenBootstrapFailsAndServiceIsNotLoaded() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    launchctl.statuses["bootstrap"] = 5
    launchctl.statuses["print"] = 113
    let service = makeService(root: root, launchctl: launchctl)

    #expect(throws: AutostartError.self) {
        _ = try service.install(AutostartSpec(binaryPath: binary))
    }
}

@Test func installRejectsAMissingBinary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, launchctl: FakeLaunchctl())

    #expect(throws: AutostartError.self) {
        _ = try service.install(AutostartSpec(binaryPath: root.appendingPathComponent("nope").path))
    }
}

/// An upgrade must re-point the plist rather than leave it aimed at the old
/// binary — the "no stale plist" acceptance criterion.
@Test func reinstallRepointsAtTheNewBinary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldBinary = try makeFakeBinary(in: root.appendingPathComponent("old"))
    let newBinary = try makeFakeBinary(in: root.appendingPathComponent("new"))
    let service = makeService(root: root, launchctl: FakeLaunchctl())

    _ = try service.install(AutostartSpec(binaryPath: oldBinary))
    let status = try service.install(AutostartSpec(binaryPath: newBinary))

    #expect(status.installedPath == newBinary)
    #expect(!status.stale)
}

/// The install-time probe must check the socket the login item targets, not
/// the well-known default — otherwise a daemon on a custom `--socket` is missed
/// and needlessly bootstrapped/restarted (review Yellow #1).
@Test func installProbesTheSpecSocketNotTheDefault() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    let spy = SocketProbeSpy(liveSocket: "/tmp/custom.sock")
    let service = spy.service(root: root, launchctl: launchctl)

    let status = try service.install(AutostartSpec(binaryPath: binary, socketPath: "/tmp/custom.sock"))

    // Probed the custom socket, saw the daemon, and left launchd alone.
    #expect(spy.asked.contains("/tmp/custom.sock"))
    #expect(!launchctl.subcommands.contains("bootstrap"))
    #expect(status.message.contains("next login"))
}

/// Status must probe the socket the installed plist registered, so a
/// launchd-started daemon on a custom socket reads as running.
@Test func statusProbesTheInstalledSocket() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let spy = SocketProbeSpy(liveSocket: "/tmp/custom.sock")
    let service = spy.service(root: root, launchctl: FakeLaunchctl())
    _ = try service.install(AutostartSpec(binaryPath: binary, socketPath: "/tmp/custom.sock"))

    let status = try service.status(expected: nil)

    #expect(status.running)
    #expect(spy.asked.contains("/tmp/custom.sock"))
    #expect(service.installedSocketPath() == "/tmp/custom.sock")
}

/// A socket-only status probe (empty binaryPath) is "no expectation" — it must
/// not read as a stale plist just because the path differs from "".
@Test func socketOnlyStatusIsNotStale() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let service = makeService(root: root, launchctl: FakeLaunchctl())
    _ = try service.install(AutostartSpec(binaryPath: binary))

    let status = try service.status(expected: AutostartSpec(binaryPath: "", socketPath: "/tmp/x.sock"))

    #expect(!status.stale)
    #expect(status.expectedPath == nil)
}

// MARK: - Status

@Test func statusReportsDisabledWithNoPlist() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, launchctl: FakeLaunchctl())

    let status = try service.status(expected: nil)

    #expect(!status.enabled)
    #expect(!status.stale)
    #expect(status.supported)
    #expect(status.platform == "macos")
    #expect(status.installedPath == nil)
}

@Test func statusFlagsAPlistPointingAtAnotherBinary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldBinary = try makeFakeBinary(in: root.appendingPathComponent("old"))
    let newBinary = try makeFakeBinary(in: root.appendingPathComponent("new"))
    let service = makeService(root: root, launchctl: FakeLaunchctl())
    _ = try service.install(AutostartSpec(binaryPath: oldBinary))

    let status = try service.status(expected: AutostartSpec(binaryPath: newBinary))

    #expect(status.enabled)
    #expect(status.stale)
    #expect(status.installedPath == oldBinary)
    #expect(status.message.contains("Re-run"))
}

@Test func statusReportsRunningIndependentlyOfEnabled() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, launchctl: FakeLaunchctl(), running: true)

    let status = try service.status(expected: nil)

    #expect(status.running)
    #expect(!status.enabled)
    #expect(status.message.contains("reboot"))
}

@Test func statusEncodesToJSONForTheCLIAndWebUI() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, launchctl: FakeLaunchctl())

    let data = try JSONEncoder().encode(try service.status(expected: nil))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["enabled"] as? Bool == false)
    #expect(json["label"] as? String == "com.corveil.crowd")
    #expect(json["supported"] as? Bool == true)
}

// MARK: - Uninstall

@Test func uninstallRemovesThePlistAndBootsOut() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let launchctl = FakeLaunchctl()
    let service = makeService(root: root, launchctl: launchctl)
    _ = try service.install(AutostartSpec(binaryPath: binary))

    let status = try service.uninstall()

    #expect(!FileManager.default.fileExists(atPath: service.plistURL.path))
    #expect(launchctl.subcommands.contains("bootout"))
    #expect(!status.enabled)
    #expect(status.message.contains("removed"))
}

@Test func uninstallIsANoOpWhenNotInstalled() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchctl = FakeLaunchctl()
    launchctl.statuses["bootout"] = 3
    let service = makeService(root: root, launchctl: launchctl)

    let status = try service.uninstall()

    #expect(!status.enabled)
    #expect(status.message.contains("nothing to remove"))
}
