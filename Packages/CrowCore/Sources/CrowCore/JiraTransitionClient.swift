import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Performs a Jira **workflow status transition** via the Jira Cloud REST API,
/// fetching the issue's available transitions first and only firing one that
/// actually reaches the requested status name (#529).
///
/// Why REST and not `acli` / the agent-side MCP:
/// - `acli` is being removed (#528), and it blind-fires `--status NAME` with no
///   way to know whether that status is a reachable transition — an invalid name
///   is a hard error instead of a graceful no-op.
/// - The agent-side `jira` MCP lives in launched Claude sessions; the Crow app
///   (Manager / cron / UI-driven mark-in-review & mark-done) can't reach it.
///
/// So the app drives transitions itself over REST, authenticated with the same
/// Atlassian email + API token used elsewhere (HTTP Basic via
/// ``JiraCredentialResolver``). This mirrors ``JiraStatusFetcher`` (which already
/// reaches Jira Cloud REST for the Settings status picker) — same site host,
/// same credential, injectable transport for tests.
public enum JiraTransitionClient {
    /// The result of attempting a transition.
    public enum Outcome: Equatable, Sendable {
        /// The matching transition was found and POSTed successfully.
        case transitioned(id: String)
        /// No available transition reaches `targetStatusName` — a graceful no-op
        /// (the caller logs and moves on rather than erroring). `available` lists
        /// the reachable target-status names for diagnostics.
        case noMatchingTransition(available: [String])
    }

    public enum TransitionError: Error, Equatable, Sendable {
        case badSite
        case http(Int)
        case transport(String)
        case decode
    }

    /// A single workflow transition: its id, the transition's own name, and the
    /// status name it moves the issue **to**.
    struct Transition: Equatable {
        let id: String
        let name: String
        let toName: String
    }

    /// Build the transitions REST URL for a site host + issue key. Accepts a bare
    /// host (`acme.atlassian.net`) or a full origin; the scheme is always forced
    /// to **https** so the Basic credential is never sent in cleartext (mirrors
    /// ``JiraStatusFetcher/statusesURL(site:projectKey:)``).
    static func transitionsURL(site: String, issueKey: String) -> URL? {
        let trimmedSite = site.trimmingCharacters(in: .whitespaces)
        let trimmedKey = issueKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedSite.isEmpty, !trimmedKey.isEmpty else { return nil }
        let bareHost = trimmedSite.range(of: "://").map { String(trimmedSite[$0.upperBound...]) } ?? trimmedSite
        guard !bareHost.isEmpty,
              let encodedKey = trimmedKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://\(bareHost)/rest/api/3/issue/\(encodedKey)/transitions")
    }

    /// Parse the `GET /transitions` payload (`{ "transitions": [ { id, name,
    /// to: { name } } ] }`) into a list of ``Transition``.
    static func parseTransitions(_ data: Data) -> [Transition]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["transitions"] as? [[String: Any]] else { return nil }
        return raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = item["name"] as? String ?? ""
            let toName = (item["to"] as? [String: Any])?["name"] as? String ?? ""
            return Transition(id: id, name: name, toName: toName)
        }
    }

    /// Find the id of a transition that reaches `targetName`. Matches the target
    /// **status** name (`to.name`) first — that's what `jiraStatusMap` resolves to
    /// — then falls back to the transition's own `name` for workflows whose
    /// transition label equals the status. Case-insensitive.
    static func matchTransitionID(in transitions: [Transition], targetName: String) -> String? {
        let target = targetName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if let byTo = transitions.first(where: { $0.toName.caseInsensitiveCompare(target) == .orderedSame }) {
            return byTo.id
        }
        if let byName = transitions.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) {
            return byName.id
        }
        return nil
    }

    /// Transition `issueKey` on `site` to the workflow status named
    /// `targetStatusName`, authenticated with `authorization` (a full header
    /// value, e.g. `Basic …` from ``JiraCredentialResolver``). Fetches the available
    /// transitions, matches the target, and POSTs it. Returns
    /// `.noMatchingTransition` (not a failure) when the target isn't reachable so
    /// callers degrade gracefully. Injectable transport for testing.
    public static func transition(
        site: String,
        issueKey: String,
        targetStatusName: String,
        authorization: String,
        transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> Result<Outcome, TransitionError> {
        guard let url = transitionsURL(site: site, issueKey: issueKey) else {
            return .failure(.badSite)
        }

        // 1. Fetch available transitions.
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        getRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        getRequest.timeoutInterval = 15

        let transitions: [Transition]
        do {
            let (data, response) = try await transport(getRequest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            guard let parsed = parseTransitions(data) else { return .failure(.decode) }
            transitions = parsed
        } catch {
            return .failure(.transport(error.localizedDescription))
        }

        // 2. Match the requested status name against a reachable transition.
        guard let transitionID = matchTransitionID(in: transitions, targetName: targetStatusName) else {
            return .success(.noMatchingTransition(available: transitions.map(\.toName)))
        }

        // 3. POST the transition.
        var postRequest = URLRequest(url: url)
        postRequest.httpMethod = "POST"
        postRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        postRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        postRequest.timeoutInterval = 15
        postRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["transition": ["id": transitionID]])

        do {
            let (_, response) = try await transport(postRequest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            return .success(.transitioned(id: transitionID))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
