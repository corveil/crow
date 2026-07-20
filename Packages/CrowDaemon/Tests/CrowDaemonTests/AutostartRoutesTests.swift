import Testing
import Foundation
import CrowAutostart
@testable import CrowDaemon

// MARK: - Autostart Routes (CROW-769)

/// The login item must carry the flags this daemon is actually running with,
/// so the login-launched crowd binds the same host/port/socket and reads the
/// same dev root — not the defaults.
@Suite struct AutostartSpecTests {
    @Test func specCarriesTheRunningDaemonsFlags() throws {
        let options = DaemonOptions.parse([
            "crowd", "--http-port", "9191", "--host", "127.0.0.1",
            "--dev-root", "/Users/jane/Dev", "--socket", "/tmp/crow-test.sock",
        ])

        let spec = try AutostartRoutes.currentSpec(options)

        #expect(spec.host == "127.0.0.1")
        #expect(spec.httpPort == 9191)
        #expect(spec.devRoot == "/Users/jane/Dev")
        #expect(spec.socketPath == "/tmp/crow-test.sock")
        // The binary is this daemon's own executable — never a resolved guess.
        #expect(spec.binaryPath == Bundle.main.executableURL?.path)
        #expect(spec.programArguments.first == spec.binaryPath)
        #expect(spec.programArguments.contains("--http-port"))
        #expect(spec.programArguments.contains("9191"))
    }

    @Test func specDefaultsMatchTheDaemonsOwnDefaults() throws {
        let options = DaemonOptions.parse(["crowd"])

        let spec = try AutostartRoutes.currentSpec(options)

        #expect(spec.httpPort == options.httpPort)
        #expect(spec.host == options.host)
        #expect(spec.socketPath == options.socketPath)
    }
}
