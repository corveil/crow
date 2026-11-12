import Foundation

/// The Manager context and the on-demand `crow-cli` skill (CROW-1443).
///
/// Claude Code loads every `CLAUDE.md` from a session's working directory up to
/// the filesystem root, and every Crow session — Managers, work, review and job
/// sessions — runs under `{devRoot}`. So whatever `Scaffolder` writes to
/// `{devRoot}/.claude/CLAUDE.md` is paid for on every turn of every session.
/// That file is therefore kept to what every session needs (capped at
/// ``maxBytes``), and the per-verb CLI reference ships as a skill that is read
/// only when an agent needs a verb the context does not list.
///
/// Both live in `Resources/ManagerContext/`, a SwiftPM resource of this target,
/// so dev builds and the shipped app scaffold from the same source. The crow
/// repo's own root `CLAUDE.md` is repo documentation and is never scaffolded:
/// a session in a crow worktree would otherwise load the context twice.
enum ManagerContext {
    /// Upper bound on the scaffolded Manager context, before the operator's
    /// preserved `## Known Issues / Corrections` tail is appended.
    static let maxBytes = 12 * 1024

    /// The heading whose tail `Scaffolder` preserves across relaunches.
    static let correctionsHeading = "## Known Issues / Corrections"

    /// Skill directory name under `{devRoot}/.claude/skills/`.
    static let cliSkillName = "crow-cli"

    /// `{devRoot}/.claude/CLAUDE.md`, as shipped.
    static func markdown() -> String {
        resource("manager-context.md") ?? """
        # Crow — Manager Context

        See crow --help for CLI reference.
        All crow, gh, glab, and git worktree commands require dangerouslyDisableSandbox: true.
        Write temp files to $TMPDIR, not /tmp.

        \(correctionsHeading)
        """
    }

    /// `{devRoot}/.claude/skills/crow-cli/SKILL.md`.
    static func cliSkill() -> String {
        resource("crow-cli/SKILL.md") ?? """
        ---
        name: crow-cli
        description: Look up a crow CLI verb's exact flags and output before running it.
        ---

        # crow CLI reference

        The reference was not bundled with this build. Run `crow --help` and
        `crow <verb> --help` for every verb's flags; never guess one.
        """
    }

    /// `{devRoot}/.claude/skills/crow-cli/reference.md`.
    static func cliReference() -> String {
        resource("crow-cli/reference.md") ?? """
        # crow CLI — per-verb reference

        Not bundled with this build. Run `crow --help` and `crow <verb> --help`.
        """
    }

    private static func resource(_ relativePath: String) -> String? {
        guard let dir = Bundle.module.url(forResource: "ManagerContext", withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: dir.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
