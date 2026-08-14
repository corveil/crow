import CrowCore
import CrowEngine
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import CrowDaemon

// MARK: - `POST /config/corveil` is local-only (CROW-1011)

/// Settings → Corveil CLI's Verify / Reinstall skill buttons execute an absolute
/// path on the daemon host, so they carry the same gating as `SecretRoutes` and
/// `AutostartRoutes`: a proxied/remote session — even a logged-in one — is
/// refused, and a cross-site Origin is refused even from a local peer.
///
/// Driven end to end through the mounted route over a real loopback server, so a
/// refactor that drops `gateOK` fails here. Each forbidden case additionally
/// asserts the subprocess never ran: the stub binary these point at leaves a
/// marker file behind, so "refused" means refused *before* execution rather than
/// after it.
@Suite struct CorveilRouteGatingTests {

    // MARK: - Fixtures

    /// A devRoot plus a stub `corveil` that touches `marker` when run.
    private struct Fixture {
        let devRoot: String
        let binary: String
        let marker: String

        var ranBinary: Bool { FileManager.default.fileExists(atPath: marker) }

        func cleanUp() { try? FileManager.default.removeItem(atPath: devRoot) }
    }

    private func makeFixture() throws -> Fixture {
        let devRoot = NSTemporaryDirectory().appending("corveil-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        let marker = (devRoot as NSString).appendingPathComponent("ran")
        let binary = (devRoot as NSString).appendingPathComponent("corveil")
        try """
        #!/bin/sh
        : > "\(marker)"
        if [ "$1" = "skill" ]; then printf 'stub skill' > "$4"; fi
        echo 'corveil 0.0.1-stub'
        """.write(toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        return Fixture(devRoot: devRoot, binary: binary, marker: marker)
    }

    /// `AppState` is main-actor isolated, so the suite builds its app there. The
    /// route only touches it on the reinstall path (to update the launch-time
    /// warning), which is itself a `MainActor.run` hop.
    @MainActor
    private func makeApp(_ fixture: Fixture) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        CorveilRoutes.mount(
            on: router, boundHost: "127.0.0.1", devRoot: fixture.devRoot, appState: AppState())
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "crowd-test"))
    }

    private let jsonHeaders: HTTPFields = [.contentType: "application/json"]
    private let xff = HTTPField.Name("x-forwarded-for")!

    private func body(_ action: String, path: String) -> ByteBuffer {
        ByteBuffer(string: #"{"action":"\#(action)","path":"\#(path)"}"#)
    }

    // MARK: - Allowed

    @Test func localDirectPeerMayVerify() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: jsonHeaders,
                body: body("verify", path: fixture.binary)
            ) { response in
                #expect(response.status == .ok)
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any])
                #expect(json["ok"] as? Bool == true)
                #expect(json["message"] as? String == "corveil 0.0.1-stub")
            }
        }
        #expect(fixture.ranBinary)
    }

    @Test func localDirectPeerMayReinstallTheSkill() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: jsonHeaders,
                body: body("reinstall-skill", path: fixture.binary)
            ) { response in
                #expect(response.status == .ok)
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any])
                #expect(json["ok"] as? Bool == true)
                // The response names the file it wrote, so the UI can say where.
                #expect(json["skill_path"] as? String
                    == CorveilCLI.skillPath(devRoot: fixture.devRoot))
            }
        }
        #expect(FileManager.default.fileExists(
            atPath: CorveilCLI.skillPath(devRoot: fixture.devRoot)))
    }

    /// A broken binary is a successful *report* of a broken binary. 200 with
    /// `ok: false`, not an HTTP error — the browser renders the diagnostic either
    /// way and would otherwise have to dig it out of an error path.
    @Test func aFailingBinaryStillAnswersOK() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: jsonHeaders,
                body: body("verify", path: "/nonexistent/corveil")
            ) { response in
                #expect(response.status == .ok)
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any])
                #expect(json["ok"] as? Bool == false)
            }
        }
    }

    // MARK: - Refused

    /// A loopback peer WITH an X-Forwarded-For is a local reverse proxy carrying
    /// a remote user — not local-direct. Must be refused before anything runs.
    @Test func proxiedPeerIsForbidden() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let headers: HTTPFields = [.contentType: "application/json", xff: "203.0.113.9"]
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: headers,
                body: body("verify", path: fixture.binary)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(!fixture.ranBinary, "the gate must run before the subprocess")
    }

    /// A cross-site Origin fails the CSRF check even from a local peer — a page
    /// in the user's own browser must not be able to drive host execution.
    @Test func crossSiteOriginIsForbidden() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let headers: HTTPFields = [.contentType: "application/json", .origin: "https://evil.com"]
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: headers,
                body: body("reinstall-skill", path: fixture.binary)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(!fixture.ranBinary, "the gate must run before the subprocess")
    }

    // MARK: - Bad requests

    @Test func anUnknownActionIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: jsonHeaders,
                body: body("uninstall", path: fixture.binary)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        #expect(!fixture.ranBinary)
    }

    /// No path in the request and none in config: there is nothing to run, and
    /// saying so beats executing the empty string.
    @Test func noPathAnywhereIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await makeApp(fixture).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil", method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{"action":"verify"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        #expect(!fixture.ranBinary)
    }
}
