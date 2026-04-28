import Foundation

/// Identifier for a coding agent implementation (Claude Code today; others later).
///
/// Declared as a `RawRepresentable` struct rather than an enum so downstream
/// packages can register additional kinds without modifying `CrowCore`.
public struct AgentKind: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The Claude Code agent.
    public static let claudeCode = AgentKind(rawValue: "claude-code")

    /// The OpenAI Codex agent.
    public static let codex = AgentKind(rawValue: "codex")
}
