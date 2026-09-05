import Testing
import Foundation
@testable import CrowAutostart

// MARK: - Harness

/// Records every `systemctl` invocation and replays canned results, so the
/// install/uninstall/status logic is exercised without touching the real
/// `~/.config/systemd/user` or spawning systemd.
final class FakeSystemctl: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    /// Exit status per verb (`daemon-reload`, `enable`, `disable`, `start`, `is-enabled`).
    var statuses: [String: Int32] = [
        "daemon-reload": 0, "enable": 0, "disable": 0, "start": 0, "is-enabled": 0,
    ]

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var verbs: [String] { calls.compactMap(Self.verb(in:)) }

    func runner() -> CommandRunner {
        { [self] _, arguments in
            lock.lock()
            _calls.append(arguments)
            lock.unlock()
            let status = statuses[Self.verb(in: arguments) ?? ""] ?? 0
            return CommandResult(status: status, output: status == 0 ? "" : "Failed")
        }
    }

    private static func verb(in arguments: [String]) -> String? {
        let known = ["daemon-reload", "enable", "disable", "start", "stop", "is-enabled"]
        return arguments.first { known.contains($0) }
    }
}

/// A SystemdAutostart rooted in a temp directory.
private func makeService(
    root: URL,
    systemctl: FakeSystemctl,
    running: Bool = false
) -> SystemdAutostart {
    SystemdAutostart(
        unitsDirectory: root.appendingPathComponent("systemd/user"),
        logDirectory: root.appendingPathComponent("state/crow"),
        runner: systemctl.runner(),
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

    func service(root: URL, systemctl: FakeSystemctl) -> SystemdAutostart {
        SystemdAutostart(
            unitsDirectory: root.appendingPathComponent("systemd/user"),
            logDirectory: root.appendingPathComponent("state/crow"),
            runner: systemctl.runner(),
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
        .appendingPathComponent("crow-systemd-autostart-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readUnit(_ service: SystemdAutostart) throws -> String {
    let data = try #require(FileManager.default.contents(atPath: service.unitURL.path))
    return try #require(String(data: data, encoding: .utf8))
}

// MARK: - XDG paths

@Suite("SystemdAutostart")
struct SystemdAutostartTests {

@Test func defaultLogDirectoryHonorsXDGStateHome() {
    let home = URL(fileURLWithPath: "/home/jane")
    let fromXDG = SystemdAutostart.defaultLogDirectory(
        home: home, environment: ["XDG_STATE_HOME": "/var/lib/xdg"])
    #expect(fromXDG.path == "/var/lib/xdg/crow")

    let fallback = SystemdAutostart.defaultLogDirectory(
        home: home, environment: [:])
    #expect(fallback.path == "/home/jane/.local/state/crow")

    let emptyIsUnset = SystemdAutostart.defaultLogDirectory(
        home: home, environment: ["XDG_STATE_HOME": ""])
    #expect(emptyIsUnset.path == "/home/jane/.local/state/crow")
}

@Test func defaultUnitsDirectoryHonorsXDGConfigHome() {
    let home = URL(fileURLWithPath: "/home/jane")
    let fromXDG = SystemdAutostart.defaultUnitsDirectory(
        home: home, environment: ["XDG_CONFIG_HOME": "/etc/xdg"])
    #expect(fromXDG.path == "/etc/xdg/systemd/user")

    let fallback = SystemdAutostart.defaultUnitsDirectory(
        home: home, environment: [:])
    #expect(fallback.path == "/home/jane/.config/systemd/user")

    let emptyIsUnset = SystemdAutostart.defaultUnitsDirectory(
        home: home, environment: ["XDG_CONFIG_HOME": ""])
    #expect(emptyIsUnset.path == "/home/jane/.config/systemd/user")
}

// MARK: - Unit contents

@Test func installWritesUnitWithExpectedKeys() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    let service = makeService(root: root, systemctl: systemctl)

    _ = try service.install(AutostartSpec(binaryPath: binary, host: "127.0.0.1", httpPort: 8787))

    let unit = try readUnit(service)
    #expect(unit.contains("[Unit]"))
    #expect(unit.contains("[Service]"))
    #expect(unit.contains("[Install]"))
    #expect(unit.contains("WantedBy=default.target"))
    #expect(unit.contains("Type=simple"))
    #expect(unit.contains(SystemdAutostart.quote(binary)))
    #expect(unit.contains(SystemdAutostart.quote("--host")))
    #expect(unit.contains(SystemdAutostart.quote("127.0.0.1")))
    #expect(unit.contains(SystemdAutostart.quote("--http-port")))
    #expect(unit.contains(SystemdAutostart.quote("8787")))
    // Capture stays on crowd.log; CrowLog reopens the fds after a size-capped
    // rename so systemd's inherited fds actually follow (CROW-1197).
    #expect(unit.contains("StandardOutput=\(SystemdAutostart.quote("append:\(service.logURL.path)"))"))
    #expect(unit.contains("StandardError=\(SystemdAutostart.quote("append:\(service.logURL.path)"))"))
    // The PATH systemd --user hands a unit is too bare for git/gh/tmux.
    #expect(unit.contains("Environment="))
    #expect(unit.contains("/usr/bin"))
}

/// crowd exits(1) — a *clean* exit — when another instance holds the socket or
/// store lock. `Restart=on-failure` / `always` would respawn it forever;
/// `on-abnormal` restarts only on a crash, uncaught signal, or timeout.
@Test func restartPolicyIsOnAbnormalNotOnFailure() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let service = makeService(root: root, systemctl: FakeSystemctl())

    _ = try service.install(AutostartSpec(binaryPath: binary))

    let unit = try readUnit(service)
    #expect(unit.contains("Restart=on-abnormal"))
    #expect(!unit.contains("Restart=always"))
    #expect(!unit.contains("Restart=on-failure"))
    #expect(unit.contains("RestartSec=10"))
}

@Test func installQuotesExecStartSoSpacesSurvive() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("my bin"), named: "crowd")
    let service = makeService(root: root, systemctl: FakeSystemctl())

    _ = try service.install(AutostartSpec(binaryPath: binary, devRoot: "/home/jane/My Dev"))

    #expect(service.installedProgramPath() == binary)
    #expect(service.installedSocketPath() == nil)
    let unit = try readUnit(service)
    let execLine = try #require(unit.split(separator: "\n").first { $0.hasPrefix("ExecStart=") })
    let args = SystemdAutostart.parseExecArguments(String(execLine.dropFirst("ExecStart=".count)))
    #expect(args == [binary, "--dev-root", "/home/jane/My Dev"])
}

// MARK: - Install behavior

@Test func installEnablesAndStartsWhenNoDaemonIsRunning() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    let service = makeService(root: root, systemctl: systemctl, running: false)

    let status = try service.install(AutostartSpec(binaryPath: binary))

    #expect(systemctl.verbs.contains("daemon-reload"))
    #expect(systemctl.verbs.contains("enable"))
    #expect(systemctl.verbs.contains("start"))
    #expect(!systemctl.calls.contains { $0.contains("--now") })
    #expect(status.enabled)
    #expect(status.platform == "linux")
    #expect(status.supported)
    #expect(status.message.contains("crowd started"))
}

/// Starting alongside a running daemon would spawn a duplicate that
/// immediately refuses to start (single-instance + store-writer locks).
/// Write the unit and `enable` it (so the next login is covered) without
/// `start`.
@Test func installLeavesSystemdUnstartedWhenDaemonIsAlreadyRunning() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    let service = makeService(root: root, systemctl: systemctl, running: true)

    let status = try service.install(AutostartSpec(binaryPath: binary))

    #expect(systemctl.verbs.contains("daemon-reload"))
    #expect(systemctl.verbs.contains("enable"))
    #expect(!systemctl.verbs.contains("start"))
    #expect(status.enabled)
    #expect(status.message.contains("next login"))
}

@Test func installIsIdempotent() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    let service = makeService(root: root, systemctl: systemctl)
    let spec = AutostartSpec(binaryPath: binary)

    _ = try service.install(spec)
    let first = try readUnit(service)
    let status = try service.install(spec)
    let second = try readUnit(service)

    #expect(first == second)
    #expect(status.enabled)
    #expect(!status.stale)
}

@Test func installThrowsWhenDaemonReloadFails() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    systemctl.statuses["daemon-reload"] = 1
    let service = makeService(root: root, systemctl: systemctl)

    #expect(throws: AutostartError.self) {
        _ = try service.install(AutostartSpec(binaryPath: binary))
    }
}

@Test func installThrowsWhenEnableFails() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    systemctl.statuses["enable"] = 1
    let service = makeService(root: root, systemctl: systemctl)

    #expect(throws: AutostartError.self) {
        _ = try service.install(AutostartSpec(binaryPath: binary))
    }
}

@Test func installStillSucceedsWhenStartFails() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    systemctl.statuses["start"] = 1
    let service = makeService(root: root, systemctl: systemctl)

    let status = try service.install(AutostartSpec(binaryPath: binary))

    #expect(status.enabled)
    #expect(status.message.contains("could not start"))
}

@Test func installRejectsAMissingBinary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, systemctl: FakeSystemctl())

    #expect(throws: AutostartError.self) {
        _ = try service.install(AutostartSpec(binaryPath: root.appendingPathComponent("nope").path))
    }
}

/// An upgrade must re-point the unit rather than leave it aimed at the old
/// binary — the "no stale unit" acceptance criterion.
@Test func reinstallRepointsAtTheNewBinary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldBinary = try makeFakeBinary(in: root.appendingPathComponent("old"))
    let newBinary = try makeFakeBinary(in: root.appendingPathComponent("new"))
    let service = makeService(root: root, systemctl: FakeSystemctl())

    _ = try service.install(AutostartSpec(binaryPath: oldBinary))
    let status = try service.install(AutostartSpec(binaryPath: newBinary))

    #expect(status.installedPath == newBinary)
    #expect(!status.stale)
}

/// The install-time probe must check the socket the unit targets, not
/// the well-known default — otherwise a daemon on a custom `--socket` is missed
/// and needlessly started.
@Test func installProbesTheSpecSocketNotTheDefault() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    let spy = SocketProbeSpy(liveSocket: "/tmp/custom.sock")
    let service = spy.service(root: root, systemctl: systemctl)

    let status = try service.install(AutostartSpec(binaryPath: binary, socketPath: "/tmp/custom.sock"))

    #expect(spy.asked.contains("/tmp/custom.sock"))
    #expect(!systemctl.verbs.contains("start"))
    #expect(status.message.contains("next login"))
}

/// Status must probe the socket the installed unit registered, so a
/// systemd-started daemon on a custom socket reads as running.
@Test func statusProbesTheInstalledSocket() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let spy = SocketProbeSpy(liveSocket: "/tmp/custom.sock")
    let service = spy.service(root: root, systemctl: FakeSystemctl())
    _ = try service.install(AutostartSpec(binaryPath: binary, socketPath: "/tmp/custom.sock"))

    let status = try service.status(expected: nil)

    #expect(status.running)
    #expect(spy.asked.contains("/tmp/custom.sock"))
    #expect(service.installedSocketPath() == "/tmp/custom.sock")
}

/// A socket-only status probe (empty binaryPath) is "no expectation" — it must
/// not read as a stale unit just because the path differs from "".
@Test func socketOnlyStatusIsNotStale() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let service = makeService(root: root, systemctl: FakeSystemctl())
    _ = try service.install(AutostartSpec(binaryPath: binary))

    let status = try service.status(expected: AutostartSpec(binaryPath: "", socketPath: "/tmp/x.sock"))

    #expect(!status.stale)
    #expect(status.expectedPath == nil)
}

// MARK: - Status

@Test func statusReportsDisabledWithNoUnit() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, systemctl: FakeSystemctl())

    let status = try service.status(expected: nil)

    #expect(!status.enabled)
    #expect(!status.stale)
    #expect(status.supported)
    #expect(status.platform == "linux")
    #expect(status.label == "com.corveil.crowd")
    #expect(status.installedPath == nil)
    #expect(status.plistPath == service.unitURL.path)
    #expect(status.logPath == service.logURL.path)
}

@Test func statusFlagsAUnitPointingAtAnotherBinary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldBinary = try makeFakeBinary(in: root.appendingPathComponent("old"))
    let newBinary = try makeFakeBinary(in: root.appendingPathComponent("new"))
    let service = makeService(root: root, systemctl: FakeSystemctl())
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
    let service = makeService(root: root, systemctl: FakeSystemctl(), running: true)

    let status = try service.status(expected: nil)

    #expect(status.running)
    #expect(!status.enabled)
    #expect(status.message.contains("reboot"))
}

@Test func statusEncodesToJSONForTheCLIAndWebUI() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = makeService(root: root, systemctl: FakeSystemctl())

    let data = try JSONEncoder().encode(try service.status(expected: nil))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["enabled"] as? Bool == false)
    #expect(json["label"] as? String == "com.corveil.crowd")
    #expect(json["supported"] as? Bool == true)
    #expect(json["platform"] as? String == "linux")
}

// MARK: - Uninstall

@Test func uninstallRemovesTheUnitAndDisables() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeFakeBinary(in: root.appendingPathComponent("bin"))
    let systemctl = FakeSystemctl()
    let service = makeService(root: root, systemctl: systemctl)
    _ = try service.install(AutostartSpec(binaryPath: binary))

    let status = try service.uninstall()

    #expect(!FileManager.default.fileExists(atPath: service.unitURL.path))
    #expect(systemctl.verbs.contains("disable"))
    #expect(systemctl.calls.contains { $0.contains("--now") })
    #expect(!status.enabled)
    #expect(status.message.contains("removed"))
}

@Test func uninstallIsANoOpWhenNotInstalled() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let systemctl = FakeSystemctl()
    systemctl.statuses["disable"] = 1
    let service = makeService(root: root, systemctl: systemctl)

    let status = try service.uninstall()

    #expect(!status.enabled)
    #expect(status.message.contains("nothing to remove"))
}

}
