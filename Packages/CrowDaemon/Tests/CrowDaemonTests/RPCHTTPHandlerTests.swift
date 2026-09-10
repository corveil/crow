import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import CrowDaemon

/// One-shot `POST /rpc` (CROW-1220): Origin, JSON-RPC dispatch, local-only gate.
@Suite("POST /rpc")
struct RPCHTTPHandlerTests {
    private func tempDevRoot() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-rpc-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try ConfigStore.saveConfig(AppConfig(), devRoot: dir)
        return dir
    }

    private func makeApp(devRoot: String, router: CommandRouter? = nil) -> some ApplicationProtocol {
        let http = Router(context: CrowHTTPContext.self)
        http.add(middleware: WebAuthMiddleware<CrowHTTPContext>(
            sessions: SessionStore(), devRoot: devRoot, webDir: nil))
        RPCHTTPHandler.mount(
            on: http,
            commandRouter: router ?? stubRouter(),
            boundHost: "127.0.0.1",
            devRoot: devRoot)
        return Application(router: http)
    }

    private func stubRouter() -> CommandRouter {
        CommandRouter(handlers: [
            "add-link": { params in
                ["link_id": .string("00000000-0000-0000-0000-000000000001"),
                 "skipped": .bool(false),
                 "echo_url": params["url"] ?? .null]
            },
            "list-sessions": { _ in ["sessions": .array([])] },
        ])
    }

    private func rpcBody(_ method: String, params: [String: JSONValue] = [:]) -> ByteBuffer {
        let request = JSONRPCRequest(id: 1, method: method, params: params.isEmpty ? nil : params)
        let data = (try? JSONEncoder().encode(request)) ?? Data()
        return ByteBuffer(bytes: data)
    }

    private func decode(_ buffer: ByteBuffer) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: Data(buffer.readableBytesView))
    }

    @Test("a missing Origin round-trips add-link")
    func missingOriginRoundTrips() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/rpc", method: .post,
                headers: [.contentType: "application/json"],
                body: rpcBody("add-link", params: [
                    "session_id": .string(UUID().uuidString),
                    "label": .string("PR #1"),
                    "url": .string("https://github.com/corveil/crow/pull/1"),
                    "type": .string("pr"),
                ])
            ) { response in
                #expect(response.status == .ok)
                let body = try decode(response.body)
                #expect(body.error == nil)
                #expect(body.result?["skipped"] == .bool(false))
                #expect(body.result?["echo_url"]?.stringValue
                    == "https://github.com/corveil/crow/pull/1")
            }
        }
    }

    @Test("a cross-site Origin is forbidden")
    func evilOriginIsForbidden() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.origin] = "https://evil.example"
            try await client.execute(
                uri: "/rpc", method: .post, headers: headers,
                body: rpcBody("list-sessions")
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("a loopback Origin is allowed")
    func loopbackOriginIsAllowed() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.origin] = "http://127.0.0.1:8787"
            try await client.execute(
                uri: "/rpc", method: .post, headers: headers,
                body: rpcBody("list-sessions")
            ) { response in
                #expect(response.status == .ok)
                let body = try decode(response.body)
                #expect(body.error == nil)
                #expect(body.result?["sessions"] != nil)
            }
        }
    }

    @Test("malformed JSON is 400")
    func malformedBodyIsBadRequest() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/rpc", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "not-json")
            ) { response in
                #expect(response.status == .badRequest)
                let body = try decode(response.body)
                #expect(body.error?.code == RPCErrorCode.parseError)
            }
        }
    }

    @Test("local-only methods are refused for a non-local peer")
    func hookEventIsLocalOnly() async throws {
        // `.router` tests have a nil remoteAddress, so isLocalDirect is false —
        // the same decision a remote `/rpc` peer would see.
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/rpc", method: .post,
                headers: [.contentType: "application/json"],
                body: rpcBody("hook-event", params: [
                    "event_name": .string("Stop"),
                    "payload": .object([:]),
                ])
            ) { response in
                #expect(response.status == .ok)
                let body = try decode(response.body)
                #expect(body.error?.message == "hook-event is local-only")
            }
        }
    }
}
