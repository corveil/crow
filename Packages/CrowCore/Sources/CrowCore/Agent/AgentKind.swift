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

    /// The Cursor agent.
    public static let cursor = AgentKind(rawValue: "cursor")

    /// The OpenCode agent (sst/opencode).
    public static let openCode = AgentKind(rawValue: "opencode")
}

public extension AgentKind {
    /// Human-readable label for this kind, resolved through `AgentRegistry`.
    /// Falls back to `rawValue` (e.g. `"cursor"`) when no agent is registered
    /// for the kind — per CROW-427 the fallback must NOT silently be
    /// `"Claude Code"`.
    var displayName: String {
        AgentRegistry.shared.agent(for: self)?.displayName ?? rawValue
    }

    /// SF Symbol name for this kind, resolved through `AgentRegistry`.
    /// Falls back to a neutral `"sparkles"` when no agent is registered, so
    /// the tab UI doesn't render an empty SF Symbol box.
    var iconSystemName: String {
        AgentRegistry.shared.agent(for: self)?.iconSystemName ?? "sparkles"
    }
}
