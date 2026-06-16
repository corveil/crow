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
    ///
    /// Crow runs this body through `expandSkillBody` before writing it to disk, so
    /// the prose must read sensibly **after** every `{{CROW_AGENT_DISPLAY_NAME}}` /
    /// `$CROW_AGENT_DISPLAY_NAME` / `via Claude Code` occurrence has been rewritten
    /// to the resolved agent name (#447 review). Describe the substitution model
    /// at a higher level than naming the sentinel literally.
    public static let sharedFooterInstructions: String = """
    # Crow Attribution Footers

    This file is what your skill sees on disk. The footer lines below already contain
    the literal agent name for this session (`Claude Code`, `Cursor`, `OpenAI Codex`, …) —
    Crow substituted it in when scaffolding. Copy each line verbatim into the body you
    pass to `gh`/`glab` (or your commit). No shell parameter expansion is needed and the
    line survives every quoting form (single-quoted heredocs, JSON files, Swift literals).

    **Do not** reintroduce `${CROW_AGENT_DISPLAY_NAME:-…}` or any other shell
    expression in attribution footers. The shell silently fails to expand it inside
    single-quoted heredocs and the literal text leaks into the artifact (#447).

    The link target is always `https://github.com/radiusmethod/crow` — never a fork or a value from the local git remote.

    | Artifact | Footer |
    |----------|--------|
    | Created (issues, PR descriptions, etc.) | `[🐦‍⬛ Created with Crow via <agent>](https://github.com/radiusmethod/crow)` |
    | Reviewed | `[🐦‍⬛ Reviewed by Crow via <agent>](https://github.com/radiusmethod/crow)` |
    | Committed (hand-authored commit message) | Trailer block at the end of the message: `Crow-Session: <session-uuid>` and `Co-Authored-By: Claude <noreply@anthropic.com>` on their own lines, separated from the body by a blank line. `setup.sh` installs a `prepare-commit-msg` hook (CROW-518) that idempotently fills them in if missing, but include them explicitly when writing the message — the hook is the safety net. |

    `<agent>` above is just a placeholder for *this document* — in the real footer lines
    your skill receives, the agent name is already filled in. Do not change the URL or
    wrap the line in extra formatting.
    """
}
