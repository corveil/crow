import Foundation

/// Jira REST credential used only by the in-app status fetch (CROW-528). The
/// Crow app process calls Jira's REST API directly (e.g. the #523 workspace
/// status-map dropdown via ``JiraStatusFetcher``); it cannot use the `jira` MCP,
/// which only serves Claude Code sessions. Those sessions instead inherit the
/// global `jira` MCP server from `~/.claude.json`, so Crow no longer injects or
/// provisions any Jira MCP itself.
///
/// Auth is a **personal API token** sent as HTTP Basic: the resolver builds
/// `Authorization: Basic base64("\(username):\(token)")`. `tokenRef` is an
/// `op://…` 1Password reference (resolved via `op read`) so the token never
/// lands at rest in `config.json`; a non-`op://` value is treated as a plaintext
/// token (stored in `config.json`, so warn in the UI). The Jira site comes from
/// the workspace's `jiraSite`, so no endpoint is stored here.
public struct JiraCredential: Codable, Sendable, Equatable {
    /// The Jira account email/username used for HTTP Basic auth (`JIRA_USERNAME`).
    public var username: String
    /// The API token, as an `op://…` reference (preferred) or plaintext.
    public var tokenRef: String

    public init(username: String, tokenRef: String) {
        self.username = username
        self.tokenRef = tokenRef
    }

    /// Whether this credential has enough to authenticate. Both a username and a
    /// token are required for Basic auth.
    public var isEmpty: Bool {
        username.trimmingCharacters(in: .whitespaces).isEmpty
            && tokenRef.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        tokenRef = try container.decodeIfPresent(String.self, forKey: .tokenRef) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case username, tokenRef
    }
}
