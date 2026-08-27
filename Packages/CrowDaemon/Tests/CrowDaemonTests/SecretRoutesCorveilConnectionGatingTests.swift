import CrowCore
import CrowEngine
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import CrowDaemon

// MARK: - `POST /config/corveil-connection` is local-only (CROW-1120)

/// The browser's half of the Corveil connection write path carries the same
/// gating as the gateway / web-password / MCP-token routes it sits beside in
/// `SecretRoutes`: a proxied/remote session — even a logged-in one — is refused,
/// and a cross-site Origin is refused even from a local peer. The OAuth tokens it
/// writes are credentials, so a remote peer must not author or clear the
/// connection.
///
/// Driven end to end through the mounted route over a real loopback server, so a
/// refactor that drops `gateOK` fails here. Each forbidden case additionally
/// asserts nothing was persisted.
@Suite struct SecretRoutesCorveilConnectionGatingTests {

    private func makeDevRoot() throws -> String {
        let devRoot = NSTemporaryDirectory().appending("corveil-conn-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        return devRoot
    }

    private func makeApp(devRoot: String) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        SecretRoutes.mount(on: router, boundHost: "127.0.0.1", devRoot: devRoot)
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "crowd-test"))
    }

    private let jsonHeaders: HTTPFields = [.contentType: "application/json"]
    private let xff = HTTPField.Name("x-forwarded-for")!

    private func connectBody() -> ByteBuffer {
        ByteBuffer(string: #"{"clientID":"crow-client-1","accessToken":"at-secret"}"#)
    }

    // MARK: - Allowed

    @Test func localDirectPeerMaySetAndClear() async throws {
        let devRoot = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try await makeApp(devRoot: devRoot).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil-connection", method: .post, headers: jsonHeaders,
                body: connectBody()
            ) { response in
                #expect(response.status == .ok)
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any])
                #expect(json["saved"] as? Bool == true)
                #expect(json["connected"] as? Bool == true)
            }
        }
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?.oauth.accessToken == "at-secret")

        // Clear.
        try await makeApp(devRoot: devRoot).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil-connection", method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{"clear":true}"#)
            ) { response in
                #expect(response.status == .ok)
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any])
                #expect(json["connected"] as? Bool == false)
            }
        }
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
    }

    @Test func anEmptyConnectionIsRejected() async throws {
        let devRoot = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try await makeApp(devRoot: devRoot).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil-connection", method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{"baseURL":"https://corveil.example.com"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
    }

    // MARK: - Refused

    @Test func proxiedPeerIsForbidden() async throws {
        let devRoot = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let headers: HTTPFields = [.contentType: "application/json", xff: "203.0.113.9"]
        try await makeApp(devRoot: devRoot).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil-connection", method: .post, headers: headers,
                body: connectBody()
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil,
                "the gate must run before any write")
    }

    @Test func crossSiteOriginIsForbidden() async throws {
        let devRoot = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let headers: HTTPFields = [.contentType: "application/json", .origin: "https://evil.com"]
        try await makeApp(devRoot: devRoot).test(.live) { client in
            try await client.execute(
                uri: "/config/corveil-connection", method: .post, headers: headers,
                body: connectBody()
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil,
                "the gate must run before any write")
    }
}
