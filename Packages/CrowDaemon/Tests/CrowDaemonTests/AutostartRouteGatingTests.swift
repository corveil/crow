import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import CrowAutostart
@testable import CrowDaemon

// MARK: - `POST /autostart` is local-only (CROW-769)

/// Records whether `install`/`uninstall` were reached, so a route test can
/// prove the gate ran BEFORE the mutation — not just that a status came back.
private final class RecordingAutostart: AutostartService, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var installCalls = 0
    private(set) var uninstallCalls = 0

    func install(_ spec: AutostartSpec) throws -> AutostartStatus {
        lock.lock(); installCalls += 1; lock.unlock()
        return makeStatus(enabled: true)
    }

    func uninstall() throws -> AutostartStatus {
        lock.lock(); uninstallCalls += 1; lock.unlock()
        return makeStatus(enabled: false)
    }

    func status(expected: AutostartSpec?) throws -> AutostartStatus {
        makeStatus(enabled: false)
    }

    private func makeStatus(enabled: Bool) -> AutostartStatus {
        AutostartStatus(platform: "macos", supported: true, label: "com.corveil.crowd", enabled: enabled)
    }
}

/// Same gating as the other local-only writes (`SecretRoutes`): registering a
/// LaunchAgent mutates the host machine, so a proxied/remote session — even a
/// logged-in one — must be refused. Driven end to end through the mounted route
/// over a real loopback server, so a refactor that drops `gateOK` fails here.
@Suite struct AutostartRouteGatingTests {
    private func makeApp(_ service: AutostartService) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        AutostartRoutes.mount(
            on: router, boundHost: "127.0.0.1",
            options: DaemonOptions.parse(["crowd"]), service: service)
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "crowd-test"))
    }

    private let jsonHeaders: HTTPFields = [.contentType: "application/json"]
    private let xff = HTTPField.Name("x-forwarded-for")!

    @Test func localDirectPeerMayInstall() async throws {
        let fake = RecordingAutostart()
        try await makeApp(fake).test(.live) { client in
            try await client.execute(
                uri: "/autostart", method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{"enabled":true}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(fake.installCalls == 1)
    }

    /// A loopback peer WITH an X-Forwarded-For is a local reverse proxy carrying
    /// a remote user — not local-direct. Must be refused before any mutation.
    @Test func proxiedPeerIsForbidden() async throws {
        let fake = RecordingAutostart()
        let headers: HTTPFields = [.contentType: "application/json", xff: "203.0.113.9"]
        try await makeApp(fake).test(.live) { client in
            try await client.execute(
                uri: "/autostart", method: .post, headers: headers,
                body: ByteBuffer(string: #"{"enabled":false}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(fake.installCalls == 0)
        #expect(fake.uninstallCalls == 0)
    }

    /// A cross-site Origin fails the CSRF check even from a local peer.
    @Test func crossSiteOriginIsForbidden() async throws {
        let fake = RecordingAutostart()
        let headers: HTTPFields = [.contentType: "application/json", .origin: "https://evil.com"]
        try await makeApp(fake).test(.live) { client in
            try await client.execute(
                uri: "/autostart", method: .post, headers: headers,
                body: ByteBuffer(string: #"{"enabled":true}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(fake.installCalls == 0)
    }

    /// Reading status is safe from any authenticated session — a remote user may
    /// at least see whether the host comes back after a reboot.
    @Test func statusReadIsAllowedEvenWhenProxied() async throws {
        let fake = RecordingAutostart()
        let headers: HTTPFields = [xff: "203.0.113.9"]
        try await makeApp(fake).test(.live) { client in
            try await client.execute(uri: "/autostart", method: .get, headers: headers) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
