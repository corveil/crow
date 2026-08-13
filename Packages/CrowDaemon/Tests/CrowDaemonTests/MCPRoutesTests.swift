import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CrowDaemon

/// The remote MCP endpoint's auth boundary (CROW-1004).
///
/// The protocol behaviour itself is covered in `CrowIPCTests` (which runs in the
/// Linux PR lane); what can only be tested here is the HTTP shell: bearer auth,
/// the `WebAuthMiddleware` exemption, Origin, and the status codes the MCP spec
/// pins.
@Suite("MCP HTTP endpoint")
struct MCPRoutesTests {

    // MARK: - Fixtures

    private func tempDevRoot(tokens: [MCPTokenRecord] = [], webPassword: String? = nil) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var config = AppConfig()
        config.mcpTokens = tokens
        if let webPassword { config.webAuth = PasswordHash.make(password: webPassword) }
        try ConfigStore.saveConfig(config, devRoot: dir)
        return dir
    }

    /// A router carrying the real middleware stack, so the `isAuthExempt` decision
    /// is exercised rather than assumed.
    private func makeApp(devRoot: String) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        router.add(middleware: WebAuthMiddleware<CrowHTTPContext>(
            sessions: SessionStore(), devRoot: devRoot, webDir: nil))
        MCPRoutes.mount(
            on: router,
            commandRouter: stubRouter(),
            boundHost: "127.0.0.1",
            devRoot: devRoot,
            serverVersion: "test")
        return Application(router: router)
    }

    /// Answers the five exported read methods with empty-but-shaped payloads.
    private func stubRouter() -> CommandRouter {
        CommandRouter(handlers: [
            "list-sessions": { _ in ["sessions": .array([])] },
            "list-sessions-live": { _ in ["sessions": .object([:])] },
            "list-tickets": { _ in ["issues": .array([])] },
            "list-reviews": { _ in ["reviews": .array([])] },
            "get-session": { _ in ["id": .string(UUID().uuidString)] },
        ])
    }

    private func mint(_ scopes: [MCPScope], expiresAt: Date? = nil) -> (MCPTokenRecord, String) {
        let minted = MCPTokenStore.mint(name: "test", scopes: scopes, expiresAt: expiresAt)
        return (minted.record, minted.plaintext)
    }

    private func body(_ method: String, params: [String: JSONValue] = [:]) -> ByteBuffer {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method),
        ]
        if !params.isEmpty { object["params"] = .object(params) }
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return ByteBuffer(bytes: data)
    }

    /// Builds the request headers as one value. Returns `HTTPFields` rather than
    /// letting each test mutate a local `var`, because the closure passed to
    /// `client.execute` is `@Sendable` and cannot capture a mutable binding.
    private func headers(token: String?, extra: [String: String] = [:]) -> HTTPFields {
        var fields: HTTPFields = [.contentType: "application/json"]
        if let token { fields[.authorization] = "Bearer \(token)" }
        for (name, value) in extra {
            guard let field = HTTPField.Name(name) else { continue }
            fields[field] = value
        }
        return fields
    }

    private func decode(_ buffer: ByteBuffer) throws -> [String: JSONValue] {
        try #require(
            try JSONDecoder().decode(JSONValue.self, from: Data(buffer.readableBytesView)).objectValue)
    }

    // MARK: - Authentication

    @Test("A request with no token is refused")
    func noTokenIsRefused() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: nil), body: body("tools/list")
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(response.headers[.wwwAuthenticate]?.contains("Bearer") == true)
            }
        }
    }

    @Test("A tokenless request is refused even when no web password is set")
    func noTokenIsRefusedWithoutWebPassword() async throws {
        // ⚠️ The reason `/mcp` cannot simply sit behind `WebAuthMiddleware`: that
        // gate is opt-in and inert on a daemon with no web password, so it would
        // wave this request straight through. MCPRoutes must be stricter.
        let devRoot = try tempDevRoot(webPassword: nil)
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: nil), body: body("tools/list")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("An unknown token is refused")
    func unknownTokenIsRefused() async throws {
        let (record, _) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post,
                headers: headers(token: "crow_mcp_not-a-real-token"), body: body("tools/list")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("An expired token is refused")
    func expiredTokenIsRefused() async throws {
        let (record, plaintext) = mint([.boardRead], expiresAt: Date().addingTimeInterval(-60))
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext), body: body("tools/list")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("A revoked token stops working")
    func revokedTokenIsRefused() async throws {
        let (_, plaintext) = mint([.boardRead])
        // Minted, then never persisted — which is what revocation leaves behind.
        let devRoot = try tempDevRoot(tokens: [])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext), body: body("tools/list")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("A non-Bearer Authorization scheme is refused")
    func basicAuthIsRefused() async throws {
        let devRoot = try tempDevRoot()
        let fields = headers(token: nil, extra: ["authorization": "Basic dXNlcjpwYXNz"])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: fields, body: body("tools/list")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("A valid token is accepted")
    func validTokenWorks() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext), body: body("tools/list")
            ) { response in
                #expect(response.status == .ok)
                let object = try decode(response.body)
                let tools = try #require(object["result"]?.objectValue?["tools"]?.arrayValue)
                #expect(tools.count == 2)
            }
        }
    }

    // MARK: - Scope enforcement

    @Test("tools/list shows only what the token's scopes cover")
    func toolsListIsScopedByToken() async throws {
        let (record, plaintext) = mint([.sessionsRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext), body: body("tools/list")
            ) { response in
                let object = try decode(response.body)
                let names = try #require(object["result"]?.objectValue?["tools"]?.arrayValue)
                    .compactMap { $0.objectValue?["name"]?.stringValue }
                #expect(Set(names) == ["get_board_summary", "list_sessions", "get_session", "list_stuck_sessions"])
                #expect(!names.contains("list_tickets"))
            }
        }
    }

    @Test("A board-only token cannot call a session tool")
    func outOfScopeCallIsRefused() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext),
                body: body("tools/call", params: ["name": .string("list_sessions")])
            ) { response in
                let object = try decode(response.body)
                #expect(object["error"]?.objectValue?["code"]?.intValue
                    == MCPProtocol.ErrorCode.invalidParams)
            }
        }
    }

    @Test("No MCP tool can reach a local-only method")
    func localOnlyMethodsAreUnreachable() async throws {
        // Structural, not incidental: the tool catalog is a closed allowlist, so
        // there is no request shape that names an arbitrary RPC method.
        #expect(MCPToolCatalog.exportedMethods
            .intersection(ParityLedger.localOnlyRPCMethods).isEmpty)
        let (record, plaintext) = mint([.sessionsRead, .boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            for method in ["gateway-get", "web-password-get", "run-setup", "mcp-token-mint"] {
                try await client.execute(
                    uri: "/mcp", method: .post, headers: headers(token: plaintext),
                    body: body("tools/call", params: ["name": .string(method)])
                ) { response in
                    let object = try decode(response.body)
                    #expect(object["error"]?.objectValue?["message"]?.stringValue
                        == "Unknown tool: \(method)")
                }
            }
        }
    }

    // MARK: - Transport contract

    @Test("GET and DELETE are 405")
    func getAndDeleteAreNotAllowed() async throws {
        // Revision 2026-07-28 removed the GET stream and protocol sessions; 405 is
        // what tells an older client to stop trying to open one.
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.router) { client in
            for method in [HTTPRequest.Method.get, .delete] {
                try await client.execute(uri: "/mcp", method: method) { response in
                    #expect(response.status == .methodNotAllowed)
                    #expect(response.headers[.allow] == "POST")
                }
            }
        }
    }

    @Test("An unknown method is 404 with a JSON-RPC body")
    func unknownMethodIs404() async throws {
        // The status *and* the body matter: a 404 with a `-32601` body is what lets
        // a client tell a modern MCP server from a legacy HTTP+SSE server that does
        // not host this endpoint at all.
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext),
                body: body("resources/list")
            ) { response in
                #expect(response.status == .notFound)
                let object = try decode(response.body)
                #expect(object["error"]?.objectValue?["code"]?.intValue == -32601)
            }
        }
    }

    @Test("A notification is 202 with no body")
    func notificationIs202() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"), "method": .string("notifications/initialized"),
        ]
        object["params"] = .object([:])
        let data = try JSONEncoder().encode(JSONValue.object(object))
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext),
                body: ByteBuffer(bytes: data)
            ) { response in
                #expect(response.status == .accepted)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test("An unsupported protocol version is 400 with -32022")
    func unsupportedVersionIs400() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        let params: [String: JSONValue] = [
            "_meta": .object([MCPProtocol.metaVersionKey: .string("1900-01-01")]),
        ]
        let fields = headers(token: plaintext, extra: [
            "mcp-protocol-version": "1900-01-01",
            "mcp-method": "tools/list",
        ])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: fields,
                body: body("tools/list", params: params)
            ) { response in
                #expect(response.status == .badRequest)
                let object = try decode(response.body)
                let error = try #require(object["error"]?.objectValue)
                #expect(error["code"]?.intValue == -32022)
                // The `supported` list is what lets the client retry rather than fail.
                #expect(error["data"]?.objectValue?["supported"] != nil)
            }
        }
    }

    @Test("A header that disagrees with the body is 400 with -32020")
    func headerMismatchIs400() async throws {
        let (record, plaintext) = mint([.sessionsRead])
        let devRoot = try tempDevRoot(tokens: [record])
        let params: [String: JSONValue] = [
            "name": .string("list_sessions"),
            "_meta": .object([MCPProtocol.metaVersionKey: .string(MCPProtocol.modernVersion)]),
        ]
        let fields = headers(token: plaintext, extra: [
            "mcp-protocol-version": MCPProtocol.modernVersion,
            "mcp-method": "tools/call",
            // Disagrees with the body's `name`, which is the whole point.
            "mcp-name": "get_session",
        ])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: fields,
                body: body("tools/call", params: params)
            ) { response in
                #expect(response.status == .badRequest)
                let object = try decode(response.body)
                #expect(object["error"]?.objectValue?["code"]?.intValue == -32020)
            }
        }
    }

    @Test("A legacy request needs no MCP headers")
    func legacyNeedsNoHeaders() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext),
                body: body("initialize", params: ["protocolVersion": .string("2025-11-25")])
            ) { response in
                #expect(response.status == .ok)
                let object = try decode(response.body)
                #expect(object["result"]?.objectValue?["protocolVersion"]?.stringValue == "2025-11-25")
            }
        }
    }

    @Test("A cross-site Origin is 403")
    func badOriginIsForbidden() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        let fields = headers(token: plaintext, extra: ["origin": "https://evil.example"])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: fields, body: body("tools/list")
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("Malformed JSON is 400, not a 500")
    func malformedBodyIs400() async throws {
        let (record, plaintext) = mint([.boardRead])
        let devRoot = try tempDevRoot(tokens: [record])
        try await makeApp(devRoot: devRoot).test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(token: plaintext),
                body: ByteBuffer(string: "{not json")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
