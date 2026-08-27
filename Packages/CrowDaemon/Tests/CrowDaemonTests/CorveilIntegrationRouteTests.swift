import CrowCore
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import CrowDaemon

/// End-to-end coverage of the Corveil Connect routes over a real loopback server
/// (CROW-1119): the local-only gating on both routes, and the full
/// connect → callback → tokens-stored path against a stub Corveil backend.
///
/// Same harness as ``CorveilRouteGatingTests``: routes are mounted on a live
/// `.test(.live)` server so a refactor that drops the gate fails here, and each
/// refused case asserts the Corveil backend was never called.
@Suite struct CorveilIntegrationRouteTests {

    // MARK: - Stub backend + capture boxes

    /// Records the paths the client hit, so a refused request can assert the
    /// backend was never reached.
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ request: URLRequest) {
            lock.lock(); paths.append(request.url?.path ?? ""); lock.unlock()
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
        var hitRegister: Bool { all.contains { $0.hasSuffix("/register") } }
        var hitToken: Bool { all.contains { $0.hasSuffix("/token") } }
    }

    /// Captures what the persistence door was asked to store.
    private final class PersistBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _tokens: CorveilOAuthTokens?
        private var _clientID = ""
        private var _baseURL = ""
        private var _calls = 0
        func record(baseURL: String, clientID: String, tokens: CorveilOAuthTokens) {
            lock.lock()
            _baseURL = baseURL; _clientID = clientID; _tokens = tokens; _calls += 1
            lock.unlock()
        }
        var tokens: CorveilOAuthTokens? { lock.lock(); defer { lock.unlock() }; return _tokens }
        var clientID: String { lock.lock(); defer { lock.unlock() }; return _clientID }
        var baseURL: String { lock.lock(); defer { lock.unlock() }; return _baseURL }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    /// Captures the URL Connect asked the browser to open.
    private final class OpenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: URL?
        func record(_ url: URL) { lock.lock(); _url = url; lock.unlock() }
        var url: URL? { lock.lock(); defer { lock.unlock() }; return _url }
    }

    private func json(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// A stub Corveil backend: `/register` mints a client, `/token` mints tokens.
    private func backend(log: CallLog) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            log.record(request)
            let path = request.url?.path ?? ""
            let (status, body): (Int, Data)
            if path.hasSuffix("/register") {
                (status, body) = (201, self.json([
                    "client_id": "cid-xyz",
                    "registration_access_token": "reg-tok",
                    "registration_client_uri": "https://corveil.test/mcp/oauth/register/cid-xyz",
                    "scope": "orgs.read keys.provision",
                ]))
            } else if path.hasSuffix("/token") {
                (status, body) = (200, self.json([
                    "access_token": "at-final", "refresh_token": "rt-final",
                    "token_type": "Bearer", "expires_in": 3600, "scope": "orgs.read",
                ]))
            } else {
                (status, body) = (404, Data())
            }
            return (body, HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: - Fixture

    private struct Harness {
        let app: any ApplicationProtocol
        let pending: CorveilPendingAuthStore
        let calls: CallLog
        let persisted: PersistBox
        let opened: OpenBox
        let devRoot: String
        func cleanUp() { try? FileManager.default.removeItem(atPath: devRoot) }
    }

    private func makeHarness() -> Harness {
        let devRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("corveil-routes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        let calls = CallLog()
        let persisted = PersistBox()
        let opened = OpenBox()
        let pending = CorveilPendingAuthStore()

        let router = Router(context: CrowHTTPContext.self)
        CorveilIntegrationRoutes.mount(
            on: router, boundHost: "127.0.0.1", devRoot: devRoot, httpPort: 8787,
            pending: pending,
            client: CorveilOAuthClient(transport: backend(log: calls)),
            openBrowser: { opened.record($0) },
            persist: { baseURL, clientID, tokens in
                persisted.record(baseURL: baseURL, clientID: clientID, tokens: tokens)
            })
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "crowd-test"))
        return Harness(
            app: app, pending: pending, calls: calls, persisted: persisted,
            opened: opened, devRoot: devRoot)
    }

    private let jsonHeaders: HTTPFields = [.contentType: "application/json"]
    private let xff = HTTPField.Name("x-forwarded-for")!
    private let connectURI = CorveilIntegrationRoutes.connectPath
    private let callbackURI = CorveilIntegrationRoutes.callbackPath

    private func decodeJSON(_ buffer: ByteBuffer) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any])
    }

    // MARK: - Gating: refused

    @Test func connectRefusesProxiedPeer() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        let headers: HTTPFields = [.contentType: "application/json", xff: "203.0.113.9"]
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: connectURI, method: .post, headers: headers,
                body: ByteBuffer(string: #"{"baseURL":"https://corveil.test"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(!h.calls.hitRegister, "the gate must run before any DCR call")
    }

    @Test func connectRefusesCrossSiteOrigin() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        let headers: HTTPFields = [.contentType: "application/json", .origin: "https://evil.com"]
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: connectURI, method: .post, headers: headers,
                body: ByteBuffer(string: #"{"baseURL":"https://corveil.test"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(!h.calls.hitRegister)
    }

    @Test func callbackRefusesProxiedPeer() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        let headers: HTTPFields = [xff: "203.0.113.9"]
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: "\(callbackURI)?code=x&state=y", method: .get, headers: headers
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(!h.calls.hitToken, "the gate must run before any token exchange")
    }

    // MARK: - Connect: happy path

    @Test func connectRegistersOpensBrowserAndReturnsAuthorizeURL() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: connectURI, method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{"baseURL":"https://corveil.test"}"#)
            ) { response in
                #expect(response.status == .ok)
                let body = try decodeJSON(response.body)
                let authorizeURL = try #require(body["authorizeURL"] as? String)
                #expect(authorizeURL.hasPrefix("https://corveil.test/mcp/oauth/authorize?"))
                #expect(authorizeURL.contains("client_id=cid-xyz"))
                #expect(authorizeURL.contains("code_challenge_method=S256"))
            }
        }
        #expect(h.calls.hitRegister)
        #expect(h.pending.count == 1, "an in-flight authorization is recorded")
        #expect(h.opened.url?.absoluteString.contains("/mcp/oauth/authorize") == true)
    }

    @Test func connectWithoutBaseURLIsRejected() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: connectURI, method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        #expect(!h.calls.hitRegister)
    }

    // MARK: - Callback: happy path + failures

    /// Seed a pending authorization directly, then drive the callback — the token
    /// exchange runs, tokens are stored, and the state is consumed (single-use).
    @Test func callbackExchangesCodeAndStoresTokens() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        h.pending.put(CorveilPendingAuthorization(
            state: "st-1", codeVerifier: "verifier-1", clientID: "cid-xyz",
            redirectURI: CorveilOAuthClient.redirectURI(httpPort: 8787),
            baseURL: "https://corveil.test", registrationAccessToken: "reg-tok",
            scope: "orgs.read keys.provision", createdAt: Date()))

        try await h.app.test(.live) { client in
            try await client.execute(
                uri: "\(callbackURI)?code=auth-code-1&state=st-1", method: .get
            ) { response in
                #expect(response.status == .ok)
                let html = String(buffer: response.body)
                #expect(html.contains("Connected to Corveil"))
            }
        }
        #expect(h.calls.hitToken)
        let tokens = try #require(h.persisted.tokens)
        #expect(tokens.accessToken == "at-final")
        #expect(tokens.refreshToken == "rt-final")
        #expect(tokens.registrationAccessToken == "reg-tok")  // carried from the pending record
        #expect(tokens.accessTokenExpiresAt != nil)
        #expect(h.persisted.clientID == "cid-xyz")
        #expect(h.pending.count == 0, "the state is consumed and can't be replayed")
    }

    @Test func callbackWithUnknownStateIsRejected() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: "\(callbackURI)?code=x&state=never-issued", method: .get
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("expired"))
            }
        }
        #expect(!h.calls.hitToken, "no token exchange for an unrecognized state")
        #expect(h.persisted.calls == 0)
    }

    @Test func callbackWithProviderErrorIsRendered() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        try await h.app.test(.live) { client in
            try await client.execute(
                uri: "\(callbackURI)?error=access_denied&error_description=User%20said%20no", method: .get
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("User said no"))
            }
        }
        #expect(!h.calls.hitToken)
    }

    @Test func callbackMissingCodeIsRejected() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        h.pending.put(CorveilPendingAuthorization(
            state: "st-2", codeVerifier: "v", clientID: "c", redirectURI: "r",
            baseURL: "https://corveil.test", registrationAccessToken: "reg", scope: "s", createdAt: Date()))
        try await h.app.test(.live) { client in
            try await client.execute(uri: "\(callbackURI)?state=st-2", method: .get) { response in
                #expect(response.status == .badRequest)
            }
        }
        #expect(!h.calls.hitToken)
    }

    // MARK: - Full end-to-end: connect issues the state the callback consumes

    @Test func connectThenCallbackEndToEnd() async throws {
        let h = makeHarness(); defer { h.cleanUp() }
        try await h.app.test(.live) { client in
            // 1) Connect → authorize URL carrying the issued state.
            var issuedState = ""
            try await client.execute(
                uri: connectURI, method: .post, headers: jsonHeaders,
                body: ByteBuffer(string: #"{"baseURL":"https://corveil.test"}"#)
            ) { response in
                #expect(response.status == .ok)
                let authorizeURL = try #require(try decodeJSON(response.body)["authorizeURL"] as? String)
                let items = URLComponents(string: authorizeURL)?.queryItems ?? []
                issuedState = items.first { $0.name == "state" }?.value ?? ""
                #expect(!issuedState.isEmpty)
            }

            // 2) The browser redirect comes back to the loopback callback with that
            //    same state + an authorization code.
            try await client.execute(
                uri: "\(callbackURI)?code=code-from-corveil&state=\(issuedState)", method: .get
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Connected to Corveil"))
            }
        }
        #expect(h.calls.hitRegister)
        #expect(h.calls.hitToken)
        #expect(h.persisted.tokens?.accessToken == "at-final")
        #expect(h.pending.count == 0)
    }
}
