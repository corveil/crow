import Foundation

/// Canonical Crow attribution footers for GitHub/GitLab artifacts and skill instructions.
public enum CrowAttribution {
    public static let repoURL = "https://github.com/corveil/crow"

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
        AgentKind.openCode.rawValue: "OpenCode",
        AgentKind.antigravity.rawValue: "Antigravity",
        AgentKind.grok.rawValue: "Grok Build",
        AgentKind.muse.rawValue: "Muse Code",
    ]

    /// Every display name Crow knows for its built-in kinds — the
    /// registration-**independent** counterpart to `AgentRegistry.allAgents()`
    /// (which only holds kinds whose binary resolved at daemon boot). Callers
    /// that must recognize an agent even when its binary later stops resolving —
    /// e.g. the orphan-window reaper matching a pane whose process is still up
    /// after its binary was uninstalled (#861 review r10) — union this with the
    /// registry so they keep both zero-maintenance (new kinds land in the table)
    /// and registration-independence.
    public static var allKnownDisplayNames: Set<String> {
        Set(knownDisplayNames.values)
    }

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

    // MARK: - Model-attributed footers (CROW-1533)

    /// Which footer `crow attribution --kind` prints.
    public enum FooterKind: String, CaseIterable, Sendable {
        /// `Reviewed by Crow via …` — PR reviews.
        case review
        /// `Created with Crow via …` — issues, PR descriptions, other authored artifacts.
        case created
    }

    /// Separator between the agent name and the model id in a footer.
    public static let modelSeparator = " · "

    /// The longest model id a footer will print.
    public static let maxModelLength = 64

    /// Return `raw` if it is safe to print in a footer, or nil.
    ///
    /// The model id comes from the harness transcript, which records what the
    /// API (or a third-party gateway in front of it) answered, so treat it as
    /// untrusted. Allow only `^[A-Za-z0-9._-]{1,64}$`. That rejects shell
    /// metacharacters (`$(…)`, backticks), Markdown link and HTML syntax
    /// (`]`, `(`, `<`), whitespace and newlines, and ARNs or deployment paths
    /// (`:`, `/`) that would leak an AWS account id, region or internal name.
    /// Nothing is trimmed or repaired: a value that fails is dropped whole.
    public static func sanitizedModel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.unicodeScalars.count <= maxModelLength else { return nil }
        let allowed = raw.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": true
            default: false
            }
        }
        return allowed ? raw : nil
    }

    /// The finished footer line: `[🐦‍⬛ Reviewed by Crow via <agent> · <model>](…)`.
    ///
    /// `model` passes through ``sanitizedModel(_:)`` here, so a caller can't
    /// print an unchecked value by forgetting to validate it. A nil or
    /// rejected model gives the footer without a model part, byte-identical
    /// to ``reviewMarkdownLink(agentDisplayName:)`` /
    /// ``ticketMarkdownLink(agentDisplayName:)``.
    public static func footer(
        kind: FooterKind,
        agentDisplayName: String = defaultAgentDisplayName,
        model: String? = nil
    ) -> String {
        let label = sanitizedModel(model).map { agentDisplayName + modelSeparator + $0 } ?? agentDisplayName
        switch kind {
        case .review: return reviewMarkdownLink(agentDisplayName: label)
        case .created: return ticketMarkdownLink(agentDisplayName: label)
        }
    }

    /// Default review footer (Claude Code) — backward-compatible alias.
    public static var reviewMarkdownLink: String { reviewMarkdownLink() }

    /// Default ticket footer (Claude Code) — backward-compatible alias.
    public static var ticketMarkdownLink: String { ticketMarkdownLink() }

    /// Substitute shell env expressions, legacy `{{…}}` placeholder, `via Claude
    /// Code` segments, and the review-verdict policy blocks.
    ///
    /// `reviewBlocking` defaults to ``ReviewSeverity/defaultBlocking`` so every
    /// existing call site keeps rendering today's verdict rule, and — more
    /// importantly — so no `{{CROW_REVIEW_VERDICT_*}}` placeholder can reach disk
    /// through a path that forgot to pass a policy (CROW-963). The review path
    /// pre-expands with the workspace's own set before its Claude/inlined branches
    /// diverge; `ReviewVerdictPolicy.expand` is idempotent, so this second pass is
    /// a no-op there rather than a conflicting re-render.
    ///
    /// `reviewInstructions` fills the `crow-review-pr` workspace-instructions
    /// placeholder (CROW-1340) and is substituted **last**, after every rewrite
    /// above, so the operator's text reaches the agent verbatim. Its `nil`
    /// default removes the placeholder line — the same "nothing reaches disk
    /// unexpanded" guarantee the verdict policy gets.
    public static func expandSkillBody(
        _ skillBody: String,
        agentKind: AgentKind,
        reviewBlocking: [ReviewSeverity] = ReviewSeverity.defaultBlocking,
        reviewInstructions: String? = nil
    ) -> String {
        let name = agentDisplayName(for: agentKind)
        let policyExpanded = ReviewVerdictPolicy.expand(skillBody, blocking: reviewBlocking)
        let attributed = policyExpanded
            .replacingOccurrences(of: shellAgentDisplayNameExpression, with: name)
            .replacingOccurrences(of: "$\(agentDisplayNameEnvironmentKey)", with: name)
            .replacingOccurrences(of: skillAgentPlaceholder, with: name)
            .replacingOccurrences(of: "via Claude Code", with: "via \(name)")
        return ReviewWorkspaceInstructions.expand(attributed, instructions: reviewInstructions)
    }

    /// Shared attribution rules copied into `.claude/skills/crow-attribution/FOOTER.md`.
    ///
    /// It tells skills to run `crow attribution` (CROW-1533) and keeps the static
    /// lines as the fallback.
    ///
    /// Crow runs this body through `expandSkillBody` before writing it to disk, so
    /// the prose must read sensibly **after** every `{{CROW_AGENT_DISPLAY_NAME}}` /
    /// `$CROW_AGENT_DISPLAY_NAME` / `via Claude Code` occurrence has been rewritten
    /// to the resolved agent name (#447 review). Describe the substitution model
    /// at a higher level than naming the sentinel literally.
    public static let sharedFooterInstructions: String = """
    # Crow Attribution Footers

    Get the footer line from Crow when you post, and copy it verbatim as the last line of
    the body you pass to `gh`/`glab`:

    ```bash
    crow attribution --kind review     # PR reviews
    crow attribution --kind created    # issues, PR descriptions, other artifacts you wrote
    ```

    It prints one line naming this session's harness and, when Crow knows it, the model
    the session is running: `[🐦‍⬛ Reviewed by Crow via <agent> · <model>](https://github.com/corveil/crow)`.
    The model is read when you run the command, because it can change mid-session. Like
    every `crow` command, run it with `dangerouslyDisableSandbox: true`.

    The model is left out, and the command still prints the footer and exits 0, when the
    operator turned it off (`crow automation set --attribution-model false`, or Settings →
    Automation), when you pass `--no-model`, when the session is unknown, when the harness
    reports no model (only Claude Code and Codex do), or when the model id isn't plain
    letters, digits, `.`, `_` and `-`. Don't add, edit or guess a model yourself.

    If the command fails, use the static line from the table below. Your skill shows it
    with the agent name already filled in: Crow substituted it when scaffolding.

    Copy the line into the body as text, and pass the body by file (`--body-file`) where
    the CLI allows it. **Do not** put `$(crow attribution …)`, `${CROW_AGENT_DISPLAY_NAME:-…}`
    or any other shell expression in a footer or body. The shell silently fails to expand
    it inside single-quoted heredocs and the literal text leaks into the artifact (#447).

    The link target is always `https://github.com/corveil/crow` — never a fork or a value from the local git remote.

    | Artifact | Footer (static fallback) |
    |----------|--------|
    | Created (issues, PR descriptions, etc.) | `[🐦‍⬛ Created with Crow via <agent>](https://github.com/corveil/crow)` |
    | Reviewed | `[🐦‍⬛ Reviewed by Crow via <agent>](https://github.com/corveil/crow)` |
    | Committed (hand-authored commit message) | Trailer block at the end of the message: `Crow-Session: <session-uuid>` and `Co-Authored-By: Claude <noreply@anthropic.com>` on their own lines, separated from the body by a blank line. `setup.sh` installs a `prepare-commit-msg` hook (CROW-518) that idempotently fills them in if missing, but include them explicitly when writing the message — the hook is the safety net. |

    `<agent>` and `<model>` above are placeholders for *this document*. Do not change the
    URL or wrap the line in extra formatting. The footer is informational: nothing gates
    on it.
    """
}
