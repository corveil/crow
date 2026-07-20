import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - `crow autostart` Parsing (CROW-769)

@Test func autostartInstallParsesDaemonFlags() throws {
    let cmd = try AutostartCommand.Install.parse([
        "--binary", "/usr/local/bin/crowd",
        "--host", "0.0.0.0",
        "--port", "9000",
        "--dev-root", "/Users/jane/Dev",
        "--socket", "/tmp/crow.sock",
    ])
    #expect(cmd.daemon.binary == "/usr/local/bin/crowd")
    #expect(cmd.daemon.host == "0.0.0.0")
    #expect(cmd.daemon.port == 9000)
    #expect(cmd.daemon.devRoot == "/Users/jane/Dev")
    #expect(cmd.daemon.socket == "/tmp/crow.sock")
    #expect(!cmd.json)
}

@Test func autostartInstallDefaultsEveryDaemonFlagToUnset() throws {
    let cmd = try AutostartCommand.Install.parse([])
    #expect(cmd.daemon.binary == nil)
    #expect(cmd.daemon.host == nil)
    #expect(cmd.daemon.port == nil)
    #expect(cmd.daemon.devRoot == nil)
    #expect(cmd.daemon.socket == nil)
}

@Test func autostartSubcommandsAcceptJSON() throws {
    #expect(try AutostartCommand.Install.parse(["--json"]).json)
    #expect(try AutostartCommand.Uninstall.parse(["--json"]).json)
    #expect(try AutostartCommand.Status.parse(["--json"]).json)
}

@Test func autostartStatusTakesABinaryToCompareAgainst() throws {
    let cmd = try AutostartCommand.Status.parse(["--binary", "/opt/crowd"])
    #expect(cmd.binary == "/opt/crowd")
}

/// Bare `crow autostart` should report, not mutate anything.
@Test func autostartDefaultsToStatus() throws {
    let parsed = try AutostartCommand.parseAsRoot([])
    #expect(parsed is AutostartCommand.Status)
}

@Test func autostartRejectsAnUnknownSubcommand() {
    #expect(throws: (any Error).self) {
        _ = try AutostartCommand.parseAsRoot(["enable"])
    }
}

/// Tilde-relative paths are expanded before they land in the plist — launchd
/// does no shell expansion, so `~/Dev` would be handed to crowd verbatim.
@Test func autostartInstallExpandsTildePaths() throws {
    let cmd = try AutostartCommand.Install.parse(["--dev-root", "~/Dev", "--socket", "~/sock", "--binary", "/bin/sh"])
    let spec = try cmd.daemon.spec()
    #expect(spec.devRoot?.hasPrefix("/") == true)
    #expect(spec.socketPath?.hasPrefix("/") == true)
    #expect(spec.devRoot?.hasSuffix("/Dev") == true)
}
