import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLResponse/URLSession live here on Linux
#endif

/// Fetches the operator's **assigned Jira work items** for the ticket board via
/// the Jira Cloud REST API, so the board read-back agrees with Jira (#533).
///
/// Why REST and not `acli` / the agent-side MCP — same reasoning as
/// ``JiraTransitionClient`` and ``JiraStatusFetcher``: `acli` requires a separate
/// install + auth, and the session-side `jira` MCP isn't reachable from the Crow
/// app process. The app drives the read itself over REST, authenticated with the
/// same Atlassian email + API token used elsewhere (HTTP Basic via
/// ``JiraCredentialResolver``). Mirrors ``JiraStatusFetcher`` — same site host,
/// same credential, injectable transport for tests.
///
/// Uses Jira Cloud's enhanced JQL search endpoint
/// `GET /rest/api/3/search/jql` (the legacy `/rest/api/3/search` was removed on
/// Cloud). A single page of up to `maxResults` items is fetched, matching the
/// previous `acli --limit 100` behavior; token pagination (`nextPageToken`) is a
/// follow-up if boards ever exceed a page.
///
/// The enhanced endpoint dropped the legacy `total` field, so match totals that
/// must exceed the page cap (the done-in-24h badge, #572) come from
/// `POST /rest/api/3/search/approximate-count` via ``fetchApproximateCount``.
public enum JiraSearchClient {
    public enum FetchError: Error, Equatable {
        case badSite
        case http(Int)
        case transport(String)
        case decode
    }

    /// Build the enhanced-search REST URL for a site host + JQL + fields. Accepts
    /// a bare host (`acme.atlassian.net`) or a full origin; the scheme is always
    /// forced to **https** so the Basic credential is never sent in cleartext
    /// (mirrors ``JiraStatusFetcher/statusesURL(site:projectKey:)``).
    static func searchURL(site: String, jql: String, fields: [String], maxResults: Int) -> URL? {
        let trimmedSite = site.trimmingCharacters(in: .whitespaces)
        let trimmedJQL = jql.trimmingCharacters(in: .whitespaces)
        guard !trimmedSite.isEmpty, !trimmedJQL.isEmpty else { return nil }
        let bareHost = trimmedSite.range(of: "://").map { String(trimmedSite[$0.upperBound...]) } ?? trimmedSite
        guard !bareHost.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = bareHost
        components.path = "/rest/api/3/search/jql"
        components.queryItems = [
            URLQueryItem(name: "jql", value: trimmedJQL),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "maxResults", value: "\(maxResults)"),
        ]
        return components.url
    }

    /// Parse the `search/jql` payload (`{ "issues": [ { key, fields:{…} } ] }`)
    /// into the raw issue dictionaries. Returns the (possibly empty) `issues`
    /// array, or `nil` when the payload shape is unrecognized.
    static func parseIssues(_ data: Data) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let issues = json["issues"] as? [[String: Any]] else {
            // A well-formed response with no matches still carries an `issues` key;
            // a missing key means an unexpected shape.
            return nil
        }
        return issues
    }

    /// Build the approximate-count REST URL for a site host. Same bare-host
    /// handling and forced-https as ``searchURL(site:jql:fields:maxResults:)``.
    static func approximateCountURL(site: String) -> URL? {
        let trimmedSite = site.trimmingCharacters(in: .whitespaces)
        guard !trimmedSite.isEmpty else { return nil }
        let bareHost = trimmedSite.range(of: "://").map { String(trimmedSite[$0.upperBound...]) } ?? trimmedSite
        guard !bareHost.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = bareHost
        components.path = "/rest/api/3/search/approximate-count"
        return components.url
    }

    /// Parse the approximate-count payload (`{ "count": N }`). NSNumber bridges
    /// both integer and double JSON encodings.
    static func parseApproximateCount(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["count"] as? NSNumber)?.intValue
    }

    /// Fetch the (eventually-consistent) total number of work items matching
    /// `jql` on `site` via `POST /rest/api/3/search/approximate-count` — the
    /// enhanced search API's replacement for the legacy `total` field. Used so
    /// counts that must exceed the fetched page cap (the done-in-24h badge,
    /// #572) don't saturate at the page size. Injectable transport for testing.
    public static func fetchApproximateCount(
        site: String,
        jql: String,
        authorization: String,
        transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> Result<Int, FetchError> {
        let trimmedJQL = jql.trimmingCharacters(in: .whitespaces)
        guard let url = approximateCountURL(site: site), !trimmedJQL.isEmpty else {
            return .failure(.badSite)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["jql": trimmedJQL])
        request.timeoutInterval = 15

        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            guard let count = parseApproximateCount(data) else { return .failure(.decode) }
            return .success(count)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// Fetch the assigned work items matching `jql` on `site`, authenticated with
    /// `authorization` (a full header value, e.g. `Basic …` from
    /// ``JiraCredentialResolver``). Returns the raw issue dictionaries (each
    /// `{ key, fields }`) for the caller to map. Injectable transport for testing.
    public static func fetchAssigned(
        site: String,
        jql: String,
        authorization: String,
        fields: [String] = ["key", "summary", "status", "labels", "priority", "parent"],
        maxResults: Int = 100,
        transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> Result<[[String: Any]], FetchError> {
        guard let url = searchURL(site: site, jql: jql, fields: fields, maxResults: maxResults) else {
            return .failure(.badSite)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            guard let issues = parseIssues(data) else { return .failure(.decode) }
            return .success(issues)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
