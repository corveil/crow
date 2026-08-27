import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLResponse/URLSession live here on Linux
#endif

/// The Corveil REST client backing org listing + one-key-per-org provisioning
/// (CROW-1121).
///
/// Where ``CorveilOAuthClient`` speaks the OAuth `/mcp/oauth/*` protocol to get a
/// user-scoped bearer, this client uses that bearer against the constrained
/// `/api/*` surface the backend opened for the Crow connected app
/// (RadiusMethod/corveil#2704, #2706):
///   - **list orgs** — `GET {base}/api/me/organizations` (scope `orgs.read`) →
///     the memberships the org dropdown renders.
///   - **provision key** — `POST {base}/api/keys` (scope `keys.provision`) → mints
///     one `sk-citadel-…` gateway key in a named org. The backend enforces **one
///     active key per (org, user, client)**: each mint deactivates the prior key
///     this client made for the user in that org. So a caller must reuse a stored
///     key and only re-POST to rotate — re-minting silently invalidates the old
///     value (``CorveilOrgProvisioner`` is where that reuse lives).
///   - **revoke key** — `DELETE {base}/api/keys/{id}` (scope `keys.provision`) →
///     soft-deactivates a key this client minted; `404` if it is already gone or
///     was minted by someone else.
///
/// It performs **no I/O beyond HTTP** and holds no state — the access-token
/// freshness, the org-list cache, and the config write live in
/// ``CorveilOrgProvisioner``. `transport` is injected so tests drive the whole
/// flow against a stub without a live Corveil, exactly like ``CorveilOAuthClient``.
struct CorveilAPIClient: Sendable {
    /// Performs one HTTP round-trip. Defaults to `URLSession.shared` in ``live``.
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The production client, backed by `URLSession`.
    static let live = CorveilAPIClient(
        transport: { try await URLSession.shared.data(for: $0) })

    // MARK: - Errors

    /// Every way an API call can fail, with enough detail to render a diagnostic.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The base URL couldn't be turned into the `/api/*` endpoints.
        case invalidBaseURL(String)
        /// The transport threw (DNS, TLS, connection refused, …).
        case transport(String)
        /// The bearer was rejected (401/403) — the token expired or lacks a scope.
        /// Split out because it is the one failure a caller acts on differently
        /// (reconnect / refresh) rather than surfacing verbatim.
        case unauthorized(status: Int, message: String)
        /// A structured API error body (`{"error":{"message":…,"type":…}}`).
        case api(status: Int, type: String, message: String)
        /// A non-2xx response that did not carry a structured error body.
        case http(status: Int, body: String)
        /// A 2xx response whose body didn't decode / lacked a required field.
        case malformedResponse(String)

        var description: String {
            switch self {
            case .invalidBaseURL(let url): return "invalid Corveil base URL: \(url)"
            case .transport(let message): return "network error: \(message)"
            case .unauthorized(let status, let message):
                return "Corveil rejected the connection (HTTP \(status)): \(message)"
            case .api(let status, let type, let message):
                return "Corveil returned HTTP \(status) (\(type)): \(message)"
            case .http(let status, let body):
                return "Corveil returned HTTP \(status): \(body.prefix(200))"
            case .malformedResponse(let detail): return "unexpected Corveil response: \(detail)"
            }
        }
    }

    // MARK: - Endpoints

    /// The `/api/*` endpoints, resolved against a Corveil base URL.
    struct Endpoints: Sendable, Equatable {
        let organizations: URL
        let keys: URL
        private let root: URL

        /// Resolve from a base URL like `https://app.corveil.example`. A trailing
        /// slash is tolerated. Returns nil unless the URL is an `http`/`https` URL
        /// with a host, so a `file://` or custom-scheme base URL is rejected here
        /// rather than reaching the transport — the same guard ``CorveilOAuthClient``
        /// applies.
        init?(baseURL: String) {
            let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            guard let root = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
                  let scheme = root.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  root.host != nil
            else { return nil }
            self.root = root
            organizations = root.appendingPathComponent("api/me/organizations")
            keys = root.appendingPathComponent("api/keys")
        }

        /// `DELETE /api/keys/{id}` for a specific key id. Callers validate `id` is a
        /// single safe path segment first (``isSafeKeyID``): `appendingPathComponent`
        /// does not encode `/` and does not collapse `..`, so an id like `../me` would
        /// otherwise resolve to a different endpoint. Key ids are backend-issued
        /// UUIDs, so this is defense-in-depth against a hostile `baseURL`.
        func key(id: String) -> URL {
            root.appendingPathComponent("api/keys").appendingPathComponent(id)
        }
    }

    /// Whether a key id is a single, safe URL path segment. Rejects the sequences
    /// `appendingPathComponent` mishandles — path separators and `..` traversal —
    /// plus empty/whitespace. Backend key ids are UUIDs; anything else is anomalous.
    static func isSafeKeyID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespaces).isEmpty
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("..")
    }

    // MARK: - Models

    /// One Corveil org the user belongs to — the shape `GET /api/me/organizations`
    /// returns (`{organization_id, organization_name, role, is_active, …}`), pared
    /// to what the dropdown and provisioning need.
    struct Organization: Sendable, Equatable {
        let id: String
        let name: String
        let role: String
        let isActive: Bool
    }

    /// A freshly-minted gateway key. `value` is the full `sk-citadel-…` secret,
    /// present only on creation; `prefix` is the display prefix.
    struct ProvisionedKey: Sendable, Equatable {
        let id: String
        let prefix: String
        let value: String
        let createdAt: Date?
    }

    // MARK: - Operations

    /// `GET /api/me/organizations` — every org the bearer's user belongs to.
    func listOrganizations(baseURL: String, accessToken: String) async throws -> [Organization] {
        let endpoints = try resolve(baseURL)
        var request = URLRequest(url: endpoints.organizations)
        request.httpMethod = "GET"
        authorize(&request, accessToken)

        let json = try await sendExpectingJSON(request)
        guard let rows = json["organizations"] as? [[String: Any]] else {
            throw Failure.malformedResponse("organizations response had no organizations array")
        }
        return rows.compactMap(Self.decodeOrganization)
    }

    /// `POST /api/keys` — mint one gateway key in `orgID`. The backend auto-resolves
    /// a team and tags the key to this client, and returns the full `sk-citadel-…`
    /// value exactly once, here.
    func provisionKey(
        baseURL: String, accessToken: String, orgID: String, name: String
    ) async throws -> ProvisionedKey {
        let endpoints = try resolve(baseURL)
        var request = URLRequest(url: endpoints.keys)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, accessToken)
        let body: [String: Any] = ["organization_id": orgID, "name": name]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let json = try await sendExpectingJSON(request)
        guard let id = json["id"] as? String, !id.isEmpty else {
            throw Failure.malformedResponse("key response had no id")
        }
        guard let value = json["key"] as? String, !value.isEmpty else {
            // `key` is only set on creation; its absence means we didn't get a
            // usable key back and must not persist a keyless record.
            throw Failure.malformedResponse("key response had no key value")
        }
        return ProvisionedKey(
            id: id,
            prefix: (json["key_prefix"] as? String) ?? "",
            value: value,
            createdAt: Self.parseTimestamp(json["created_at"]))
    }

    /// `DELETE /api/keys/{id}` — revoke a key this client minted. A `404` means the
    /// key is already gone (revoked elsewhere, or never existed), which is success
    /// for a caller whose goal is "this key no longer exists".
    func revokeKey(baseURL: String, accessToken: String, keyID: String) async throws {
        let endpoints = try resolve(baseURL)
        guard Self.isSafeKeyID(keyID) else {
            // An id carrying `/` or `..` could target a different endpoint via
            // `appendingPathComponent`; refuse rather than issue the request.
            throw Failure.malformedResponse("unsafe key id")
        }
        var request = URLRequest(url: endpoints.key(id: keyID))
        request.httpMethod = "DELETE"
        authorize(&request, accessToken)

        do {
            _ = try await sendExpectingJSON(request, allowEmptyBody: true)
        } catch Failure.api(let status, _, _) where status == 404 {
            return  // already gone — the desired end state
        } catch Failure.http(let status, _) where status == 404 {
            return
        }
    }

    // MARK: - Decoding helpers

    private static func decodeOrganization(_ row: [String: Any]) -> Organization? {
        guard let id = row["organization_id"] as? String, !id.isEmpty else { return nil }
        return Organization(
            id: id,
            name: (row["organization_name"] as? String) ?? "",
            role: (row["role"] as? String) ?? "",
            isActive: (row["is_active"] as? Bool) ?? false)
    }

    /// Corveil timestamps are RFC 3339 strings. Accept both the plain and the
    /// fractional-seconds shapes (a single `ISO8601DateFormatter` accepts only
    /// one), mirroring `CorveilConnectionRPC.parseExpiry`.
    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    // MARK: - HTTP plumbing

    private func resolve(_ baseURL: String) throws -> Endpoints {
        guard let endpoints = Endpoints(baseURL: baseURL) else {
            throw Failure.invalidBaseURL(baseURL)
        }
        return endpoints
    }

    private func authorize(_ request: inout URLRequest, _ accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// Run `request`, map transport/HTTP/API failures to ``Failure``, and return
    /// the decoded JSON object on 2xx. `allowEmptyBody` tolerates a 2xx with no
    /// JSON body (some DELETEs), returning an empty dictionary.
    private func sendExpectingJSON(
        _ request: URLRequest, allowEmptyBody: Bool = false
    ) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200...299).contains(status) else {
            // The backend's error body is `{"error":{"message":…,"type":…}}`
            // (OpenAI-shaped). Surface 401/403 as `.unauthorized` so a caller can
            // distinguish "reconnect" from a plain request error.
            let (type, message) = Self.errorFields(object)
            if status == 401 || status == 403 {
                throw Failure.unauthorized(status: status, message: message ?? "not authorized")
            }
            if let message {
                throw Failure.api(status: status, type: type ?? "error", message: message)
            }
            throw Failure.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        if let object { return object }
        if allowEmptyBody { return [:] }
        throw Failure.malformedResponse("response body was not a JSON object")
    }

    /// Pull `error.message` / `error.type` out of an OpenAI-shaped error body.
    private static func errorFields(_ object: [String: Any]?) -> (type: String?, message: String?) {
        guard let error = object?["error"] as? [String: Any] else { return (nil, nil) }
        return (error["type"] as? String, error["message"] as? String)
    }
}
