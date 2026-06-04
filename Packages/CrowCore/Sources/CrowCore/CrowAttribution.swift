import Foundation

/// Canonical Crow attribution footers for GitHub/GitLab artifacts and skill instructions.
public enum CrowAttribution {
    public static let repoURL = "https://github.com/radiusmethod/crow"

    /// Human-readable agent label when kind/env is unknown (legacy installs).
    public static let defaultAgentDisplayName = "Claude Code"

    /// Raw agent id injected into managed terminals (`claude-code`, `cursor`, `codex`, …).
    public static let agentKindEnvironmentKey = "CROW_AGENT_KIND"

    /// Human-readable agent label injected into managed terminals.
    public static let agentDisplayNameEnvironmentKey = "CROW_AGENT_DISPLAY_NAME"

    /// Placeholder in bundled SKILL bodies expanded by `expandSkillBody(_:agentKind:)`.
    public static let skillAgentPlaceholder = "{{CROW_AGENT_DISPLAY_NAME}}"

    /// Bash parameter expansion for footers in skill `gh`/`glab` `--body` arguments.
    public static let shellAgentDisplayNameExpression =
        "${\(agentDisplayNameEnvironmentKey):-\(defaultAgentDisplayName)}"

    /// Intentional second source of truth: `AgentRegistry` is not populated in
    /// CrowCore-only unit tests, so known kinds resolve here before the registry.
    private static let knownDisplayNames: [String: String] = [
        AgentKind.claudeCode.rawValue: "Claude Code",
        AgentKind.cursor.rawValue: "Cursor",
        AgentKind.codex.rawValue: "OpenAI Codex",
    ]

    /// Resolve the display name for `agentKind`, falling back to `defaultAgentDisplayName`.
    public static func agentDisplayName(for agentKind: AgentKind?) -> String {
        guard let agentKind else { return defaultAgentDisplayName }
        if let known = knownDisplayNames[agentKind.rawValue] { return known }
        let registryName = agentKind.displayName
        return registryName == agentKind.rawValue ? defaultAgentDisplayName : registryName
    }

    /// Read `CROW_AGENT_DISPLAY_NAME` or map `CROW_AGENT_KIND`; default to Claude Code.
    public static func agentDisplayName(fromEnvironment environment: [String: String]?) -> String {
        guard let environment else { return defaultAgentDisplayName }
        if let explicit = environment[agentDisplayNameEnvironmentKey],
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        if let raw = environment[agentKindEnvironmentKey],
           !raw.isEmpty {
            return agentDisplayName(for: AgentKind(rawValue: raw))
        }
        return defaultAgentDisplayName
    }

    /// Environment entries to inject when spawning a managed terminal.
    public static func environmentEntries(for agentKind: AgentKind) -> [String: String] {
        [
            agentKindEnvironmentKey: agentKind.rawValue,
            agentDisplayNameEnvironmentKey: agentDisplayName(for: agentKind),
        ]
    }

    public static func reviewMarkdownLink(agentDisplayName: String = defaultAgentDisplayName) -> String {
        "[🐦‍⬛ Reviewed by Crow via \(agentDisplayName)](\(repoURL))"
    }

    public static func ticketMarkdownLink(agentDisplayName: String = defaultAgentDisplayName) -> String {
        "[🐦‍⬛ Created with Crow via \(agentDisplayName)](\(repoURL))"
    }

    /// Default review footer (Claude Code) — backward-compatible alias.
    public static var reviewMarkdownLink: String { reviewMarkdownLink() }

    /// Default ticket footer (Claude Code) — backward-compatible alias.
    public static var ticketMarkdownLink: String { ticketMarkdownLink() }

    /// Substitute shell env expressions, legacy `{{…}}` placeholder, and `via Claude Code` segments.
    public static func expandSkillBody(_ skillBody: String, agentKind: AgentKind) -> String {
        let name = agentDisplayName(for: agentKind)
        return skillBody
            .replacingOccurrences(of: shellAgentDisplayNameExpression, with: name)
            .replacingOccurrences(of: "$\(agentDisplayNameEnvironmentKey)", with: name)
            .replacingOccurrences(of: skillAgentPlaceholder, with: name)
            .replacingOccurrences(of: "via Claude Code", with: "via \(name)")
    }

    /// Shared attribution rules copied into `.claude/skills/crow-attribution/FOOTER.md`.
    public static let sharedFooterInstructions: String = """
    # Crow Attribution Footers

    Crow injects these environment variables into every managed terminal:

    - `CROW_AGENT_KIND` — raw agent id (`claude-code`, `cursor`, `codex`, …)
    - `CROW_AGENT_DISPLAY_NAME` — human label (`Claude Code`, `Cursor`, `OpenAI Codex`, …)

    **Always** use `${CROW_AGENT_DISPLAY_NAME:-Claude Code}` in attribution footers inside
    double-quoted `gh`/`glab` arguments so the shell applies the default when unset.

    The link target is always `https://github.com/radiusmethod/crow` — never a fork or a value from the local git remote.

    | Artifact | Footer |
    |----------|--------|
    | Created (issues, PR descriptions, etc.) | `[🐦‍⬛ Created with Crow via <agent>](https://github.com/radiusmethod/crow)` |
    | Reviewed | `[🐦‍⬛ Reviewed by Crow via <agent>](https://github.com/radiusmethod/crow)` |

    Replace `<agent>` with `${CROW_AGENT_DISPLAY_NAME:-Claude Code}`. Do not change the URL or wrap the line in extra formatting.
    """
}
