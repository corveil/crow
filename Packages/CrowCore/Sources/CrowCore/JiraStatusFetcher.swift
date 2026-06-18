import Foundation

/// Fetches the concrete workflow **status names** for a Jira project, so the
/// Settings status-mapping UI can offer live names instead of free-text (#523).
///
/// `acli` has no transition/status *list* command and the in-app UI can't reach
/// the agent-side Atlassian MCP, so this calls the Jira Cloud REST endpoint
/// `GET /rest/api/3/project/{projectKey}/statuses` directly, authenticated with
/// the same Atlassian email + API token used for the MCP server (HTTP Basic).
/// That endpoint returns every status across the project's issue types — no
/// sample issue needed.
public enum JiraStatusFetcher {
    public enum FetchError: Error, Equatable {
        case badSite
        case http(Int)
        case transport(String)
        case decode
    }

    /// Build the project-statuses REST URL for a site host + project key.
    /// Accepts a bare host (`acme.atlassian.net`) or a full `https://…` origin.
    static func statusesURL(site: String, projectKey: String) -> URL? {
        let trimmedSite = site.trimmingCharacters(in: .whitespaces)
        let trimmedKey = projectKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedSite.isEmpty, !trimmedKey.isEmpty else { return nil }
        let origin = trimmedSite.hasPrefix("http") ? trimmedSite : "https://\(trimmedSite)"
        guard let encodedKey = trimmedKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(origin)/rest/api/3/project/\(encodedKey)/statuses")
    }

    /// Parse the `project/{key}/statuses` JSON payload into a de-duplicated,
    /// order-preserving list of status names across all issue types.
    static func parseStatusNames(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let issueTypes = json as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var names: [String] = []
        for issueType in issueTypes {
            guard let statuses = issueType["statuses"] as? [[String: Any]] else { continue }
            for status in statuses {
                guard let name = status["name"] as? String, !name.isEmpty else { continue }
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    /// Fetch the distinct status names for `projectKey` on `site`, authenticated
    /// with `authorization` (a full header value, e.g. `Basic …` from
    /// ``AtlassianMCPResolver``). Injectable transport for testing.
    public static func fetchStatusNames(
        site: String,
        projectKey: String,
        authorization: String,
        transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> Result<[String], FetchError> {
        guard let url = statusesURL(site: site, projectKey: projectKey) else {
            return .failure(.badSite)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            guard let names = parseStatusNames(data) else { return .failure(.decode) }
            return .success(names)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
