import Foundation

/// The Crow session sent to an AI gateway as `X-Crow-Session` (CROW-1476).
///
/// A gateway's request log carries the agent's own conversation id (read from
/// the request body) and `X-Crow-Version` (``CrowVersionHeader``), but nothing
/// that names the Crow session, so mapping a logged request back to a session
/// meant matching timestamps by hand. Every gateway request a Crow-launched
/// agent makes now carries `X-Crow-Session: <crow session uuid>`.
///
/// - Claude Code: ``GatewayResolver/resolve(_:crowVersion:crowSession:resolveSecret:)``
///   appends the header to `ANTHROPIC_CUSTOM_HEADERS`, unless the gateway
///   already configures a header with that name (the user's value wins).
/// - Codex: `CodexGatewayArgs` names an env var in an `env_http_headers`
///   override, and the paste-time key export sets it.
///
/// The value is only the UUID (``Foundation/UUID/uuidString``, the form every
/// `crow` verb prints and takes): no name, path or ticket.
public enum CrowSessionHeader {
    /// The header name, as sent.
    public static let name = "X-Crow-Session"

    /// The header value for `sessionID`.
    public static func value(for sessionID: UUID) -> String {
        sessionID.uuidString
    }

    /// Whether `headerNames` already holds this header, compared
    /// case-insensitively as HTTP does.
    public static func isConfigured(in headerNames: some Sequence<String>) -> Bool {
        headerNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
