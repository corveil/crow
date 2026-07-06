import Foundation
import Testing
import CrowIPC
@testable import CrowDaemon

/// The daemon drives its background automations (crow:auto, auto-merge,
/// auto-respond, review kickoff, scheduled jobs) + adopts terminals only when it
/// is the "authority" — it owns the app's socket, or that socket isn't answering
/// (the app is down). This replaced a static `forwardSocket == nil` check that
/// was only ever true when the daemon ran ON the app's socket, so on its own
/// default socket the daemon drove nothing even with the app closed (CROW-581).
@Suite struct AuthorityTests {
    private func tempSocketPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("crowd-auth-\(UUID().uuidString).sock")
    }

    @Test func nilForwardSocketIsAlwaysAuthority() {
        // Daemon owns the app's default socket → it's the sole authority.
        #expect(CrowDaemon.daemonIsAuthority(forwardSocket: nil) == true)
    }

    @Test func unreachableAppSocketMeansAuthority() {
        // Daemon on its own socket, app socket path has nothing listening (app
        // down) → the daemon takes over.
        #expect(CrowDaemon.daemonIsAuthority(forwardSocket: tempSocketPath()) == true)
    }

    @Test func liveAppSocketMeansNotAuthority() throws {
        // Something IS listening on the app socket (app up) → daemon backs off.
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path, router: CommandRouter(handlers: [:]))
        try server.start()
        defer { server.stop() }
        #expect(CrowDaemon.daemonIsAuthority(forwardSocket: path) == false)
    }
}
