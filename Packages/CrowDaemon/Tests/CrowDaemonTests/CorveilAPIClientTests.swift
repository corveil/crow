import CrowCore
import CrowPersistence
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import CrowDaemon

/// Unit coverage for the Corveil REST client (CROW-1121), driven against a stub
/// transport — no live Corveil. The reuse/rotate/revoke coordination on top of it
/// lives in ``CorveilOrgProvisionerTests``.
@Suite struct CorveilAPIClientTests {

    // MARK: - Stub transport

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URLRequest] = []
        func append(_ request: URLRequest) { lock.lock(); items.append(request); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return items }
        var last: URLRequest? { all.last }
    }

    private func client(
        log: RequestLog? = nil,
        _ respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> CorveilAPIClient {
        CorveilAPIClient(transport: { request in
            log?.append(request)
            let (status, body) = respond(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        })
    }

    private func jsonData(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }

    private func bodyJSON(_ request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private let base = "https://corveil.test"

    // MARK: - Endpoints

    @Test func endpointsRejectNonHTTPBaseURL() {
        #expect(CorveilAPIClient.Endpoints(baseURL: "file:///etc/passwd") == nil)
        #expect(CorveilAPIClient.Endpoints(baseURL: "javascript://x") == nil)
        #expect(CorveilAPIClient.Endpoints(baseURL: "") == nil)
    }

    @Test func endpointsResolveUnderBaseURLToleratingTrailingSlash() throws {
        let e = try #require(CorveilAPIClient.Endpoints(baseURL: "https://corveil.test/"))
        #expect(e.organizations.absoluteString == "https://corveil.test/api/me/organizations")
        #expect(e.keys.absoluteString == "https://corveil.test/api/keys")
        #expect(e.key(id: "abc").absoluteString == "https://corveil.test/api/keys/abc")
    }

    // MARK: - List organizations

    @Test func listOrganizationsParsesMembershipRows() async throws {
        let log = RequestLog()
        let api = client(log: log) { _ in
            (200, self.jsonData([
                "organizations": [
                    ["organization_id": "org1", "organization_name": "Acme",
                     "role": "admin", "is_active": true],
                    ["organization_id": "org2", "organization_name": "Beta",
                     "role": "member", "is_active": false],
                ],
            ]))
        }
        let orgs = try await api.listOrganizations(baseURL: base, accessToken: "tok")
        #expect(orgs.count == 2)
        #expect(orgs[0] == .init(id: "org1", name: "Acme", role: "admin", isActive: true))
        #expect(orgs[1].isActive == false)
        // Bearer auth is sent.
        #expect(log.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(log.last?.url?.absoluteString == "https://corveil.test/api/me/organizations")
    }

    @Test func listOrganizationsSkipsRowsWithNoOrgID() async throws {
        let api = client { _ in
            (200, self.jsonData(["organizations": [
                ["organization_name": "No ID"],
                ["organization_id": "org1", "organization_name": "Acme"],
            ]]))
        }
        let orgs = try await api.listOrganizations(baseURL: base, accessToken: "tok")
        #expect(orgs.map(\.id) == ["org1"])
    }

    @Test func listOrganizationsMissingArrayIsMalformed() async throws {
        let api = client { _ in (200, self.jsonData(["something": "else"])) }
        await #expect(throws: CorveilAPIClient.Failure.self) {
            _ = try await api.listOrganizations(baseURL: self.base, accessToken: "tok")
        }
    }

    // MARK: - Provision key

    @Test func provisionKeySendsOrgAndParsesKey() async throws {
        let log = RequestLog()
        let api = client(log: log) { _ in
            (200, self.jsonData([
                "id": "key-123",
                "key_prefix": "sk-citadel-AbC",
                "key": "sk-citadel-AbCdEfGhIjKlMnOp",
                "created_at": "2026-01-02T03:04:05Z",
            ]))
        }
        let key = try await api.provisionKey(
            baseURL: base, accessToken: "tok", orgID: "org1", name: "Crow gateway")
        #expect(key.id == "key-123")
        #expect(key.prefix == "sk-citadel-AbC")
        #expect(key.value == "sk-citadel-AbCdEfGhIjKlMnOp")
        #expect(key.createdAt != nil)
        // Request shape.
        #expect(log.last?.httpMethod == "POST")
        #expect(log.last?.url?.absoluteString == "https://corveil.test/api/keys")
        let body = bodyJSON(log.last)
        #expect(body["organization_id"] as? String == "org1")
        #expect(body["name"] as? String == "Crow gateway")
    }

    @Test func provisionKeyWithoutKeyValueIsMalformed() async throws {
        // `key` is only present on creation; a response lacking it must not persist
        // a keyless record.
        let api = client { _ in
            (200, self.jsonData(["id": "key-123", "key_prefix": "sk-citadel-AbC"]))
        }
        await #expect(throws: CorveilAPIClient.Failure.self) {
            _ = try await api.provisionKey(
                baseURL: self.base, accessToken: "tok", orgID: "org1", name: "x")
        }
    }

    @Test func unauthorizedIsSurfacedDistinctly() async throws {
        let api = client { _ in
            (403, self.jsonData(["error": ["message": "missing scope", "type": "permission_denied"]]))
        }
        await #expect(throws: CorveilAPIClient.Failure.unauthorized(status: 403, message: "missing scope")) {
            _ = try await api.provisionKey(
                baseURL: self.base, accessToken: "tok", orgID: "org1", name: "x")
        }
    }

    @Test func structuredAPIErrorIsSurfaced() async throws {
        let api = client { _ in
            (409, self.jsonData(["error": ["message": "no team", "type": "no_team"]]))
        }
        await #expect(throws: CorveilAPIClient.Failure.api(status: 409, type: "no_team", message: "no team")) {
            _ = try await api.provisionKey(
                baseURL: self.base, accessToken: "tok", orgID: "org1", name: "x")
        }
    }

    // MARK: - Revoke key

    @Test func revokeKeySendsDelete() async throws {
        let log = RequestLog()
        let api = client(log: log) { _ in
            (200, self.jsonData(["status": "ok", "message": "API key revoked"]))
        }
        try await api.revokeKey(baseURL: base, accessToken: "tok", keyID: "key-123")
        #expect(log.last?.httpMethod == "DELETE")
        #expect(log.last?.url?.absoluteString == "https://corveil.test/api/keys/key-123")
    }

    @Test func revokeKeyTolerates404AsAlreadyGone() async throws {
        let api = client { _ in
            (404, self.jsonData(["error": ["message": "API key not found", "type": "not_found"]]))
        }
        // No throw — a missing key is the desired end state for a revoke.
        try await api.revokeKey(baseURL: base, accessToken: "tok", keyID: "gone")
    }

    @Test func revokeKeyRethrowsNon404Failures() async throws {
        let api = client { _ in
            (500, self.jsonData(["error": ["message": "boom", "type": "internal_error"]]))
        }
        await #expect(throws: CorveilAPIClient.Failure.self) {
            try await api.revokeKey(baseURL: self.base, accessToken: "tok", keyID: "key-123")
        }
    }

    @Test func revokeKeyRejectsAPathTraversingKeyIDWithoutSendingARequest() async throws {
        let log = RequestLog()
        let api = client(log: log) { _ in (200, Data()) }
        // `appendingPathComponent` neither encodes `/` nor collapses `..`, so an id
        // like `../me` would target a different endpoint. Reject before any request.
        for badID in ["../me", "a/b", "..", "keys/../secrets", ""] {
            await #expect(throws: CorveilAPIClient.Failure.self) {
                try await api.revokeKey(baseURL: self.base, accessToken: "tok", keyID: badID)
            }
        }
        #expect(log.all.isEmpty, "an unsafe key id must never reach the network")
    }

    @Test func isSafeKeyIDAcceptsUUIDsAndRejectsTraversal() {
        #expect(CorveilAPIClient.isSafeKeyID("3fa85f64-5717-4562-b3fc-2c963f66afa6"))
        #expect(CorveilAPIClient.isSafeKeyID("key-123"))
        #expect(!CorveilAPIClient.isSafeKeyID(""))
        #expect(!CorveilAPIClient.isSafeKeyID("   "))
        #expect(!CorveilAPIClient.isSafeKeyID("a/b"))
        #expect(!CorveilAPIClient.isSafeKeyID(".."))
        #expect(!CorveilAPIClient.isSafeKeyID("../me"))
        #expect(!CorveilAPIClient.isSafeKeyID("a\\b"))
    }
}
