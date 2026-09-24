import Foundation
import CrowCore

// MARK: - Review prompt builders (CROW-1302)
//
// `initialPromptFileName`, `buildReviewPrompt`, and `cursorReviewPrompt`.
// `prepareReviewClone` renders one `policySkillBody`. Only the inlined side
// (`cursorReviewPrompt`) strips YAML frontmatter; the copied SKILL.md keeps
// it. Claude (and unknown kinds) stay the terse `/crow-review-pr <url>` line.
extension ReviewSessionController {
    /// Filename of the initial prompt file the launcher expects for a given
    /// session kind. `review` and `job` sessions dispatch their first prompt
    /// by shell-substituting the file's contents into the agent's command
    /// (CROW-439); `work` and `manager` have no initial prompt file.
    ///
    /// Both `CursorAgent.autoLaunchCommand` and `ClaudeCodeAgent.autoLaunchCommand`
    /// encode the same mapping inline — this helper is the launcher's preflight
    /// validator, not a refactor of the agents.
    nonisolated static func initialPromptFileName(for kind: SessionKind) -> String? {
        switch kind {
        case .review: return ".crow-review-prompt.md"
        case .job:    return ".crow-job-prompt.md"
        case .work, .manager: return nil
        }
    }

    /// Build the initial prompt for a review session.
    ///
    /// Claude Code resolves `/crow-review-pr <URL>` via its slash-command /
    /// SKILL engine — the prompt file is a one-liner and the bundled
    /// `.claude/skills/crow-review-pr/SKILL.md` (copied alongside) supplies
    /// the actual instructions. Cursor's `agent` CLI has no equivalent slash-
    /// command engine, so for Cursor we expand the SKILL body inline with
    /// `$ARGUMENTS` already substituted to the PR URL — same instructions,
    /// no second-file indirection (#431).
    ///
    /// `internal` (not `private`) so `SessionServiceReviewPromptTests` can
    /// assert the branch dispatch via `@testable import Crow`. The actual
    /// SKILL-body substitution lives in `cursorReviewPrompt(skillBody:prURL:)`
    /// so tests can exercise the substitution logic without depending on
    /// `Scaffolder.bundledReviewSkill()` (which falls back to a trivial stub
    /// in test environments where the repo path can't be resolved from
    /// `ProcessInfo.processInfo.arguments[0]`).
    ///
    /// `skillBody` is a parameter rather than a fresh `bundledReviewSkill()` read
    /// so the caller can hand in a body whose verdict policy is already rendered
    /// for the session's workspace (CROW-963). It defaults to the bundled body
    /// (which renders the default policy downstream), keeping existing callers
    /// and tests unchanged.
    nonisolated static func buildReviewPrompt(
        prURL: String,
        prTitle: String,
        repoSlug: String,
        prNumber: Int,
        agentKind: AgentKind,
        skillBody: String? = nil
    ) -> String {
        switch agentKind {
        case .cursor, .openCode, .codex, .grok, .antigravity, .muse:
            // Cursor, OpenCode, Codex, Grok, Antigravity, and Muse all lack a Crow
            // slash-command engine, so they get the whole crow-review-pr SKILL
            // body inlined into the prompt file (a self-contained brief). Without
            // this, the review would receive a bare `/crow-review-pr <URL>` line
            // it can't resolve, never run `gh pr review`, and so never satisfy the
            // review-completion contract — the loop #830 set out to remove (#843
            // review round 2 for Codex; #861 review round 5 for Grok; Antigravity
            // wired the same way, #902). `agentKind` is threaded through so the
            // posted review footer names the right agent.
            //
            // This is the branch that carries the per-workspace verdict policy for
            // most installs (CROW-963) — the copied SKILL.md below it is read only
            // by Claude.
            return cursorReviewPrompt(
                skillBody: skillBody ?? Scaffolder.bundledReviewSkill(),
                prURL: prURL,
                agentKind: agentKind
            )
        default:
            // Claude Code (and any future agent with a compatible slash-
            // command engine) gets the terse `/crow-review-pr <URL>` form.
            return """
            /crow-review-pr \(prURL)
            """
        }
    }

    /// Apply the inlined-SKILL substitutions to a raw `crow-review-pr` SKILL
    /// body for agents without a slash-command engine (Cursor, OpenCode):
    /// strip the YAML frontmatter, replace `$ARGUMENTS` with the PR URL, and
    /// expand `${CROW_AGENT_DISPLAY_NAME:-…}` / legacy "via Claude Code" wording
    /// so the posted GitHub review identifies the reviewing agent correctly.
    ///
    /// The frontmatter strip (CROW-968) is what makes the inlined body safe to
    /// pass as a positional argument. The SKILL file opens with a `---` block
    /// because Claude Code's skill engine requires `name`/`description`; inlined,
    /// that block made the prompt's first byte a `-`, which Cursor's commander-
    /// based `agent` parsed as a flag — `error: unknown option '---` — killing the
    /// session before it started. Shell quoting never covered this: `printf %q`
    /// protects the string from the shell, but a leading hyphen is not
    /// shell-special and survives into argv. Stripping is right on its own merits
    /// too — the metadata has no reader in an inlined brief and costs tokens on
    /// every review.
    ///
    /// It belongs **here**, not upstream, and not in
    /// `CrowAttribution.expandSkillBody`: `prepareReviewClone` renders the
    /// workspace policy into one `policySkillBody` and forks it two ways, and the
    /// other consumer — the `.claude/skills/crow-review-pr/SKILL.md` copy written
    /// into the review clone — **must keep** its frontmatter or Claude Code won't
    /// load the skill. Only the inlined side is stripped.
    ///
    /// `agentKind` defaults to `.cursor` for backward compatibility with the
    /// original single-agent call site (and its unit test); pass the actual
    /// kind (e.g. `.openCode`) so the footer names the right agent.
    ///
    /// Split out from `buildReviewPrompt` so unit tests can verify the
    /// substitutions against a known input without depending on the
    /// scaffolder's file-resolution fallback.
    nonisolated static func cursorReviewPrompt(skillBody: String, prURL: String, agentKind: AgentKind = .cursor) -> String {
        CrowAttribution.expandSkillBody(
            MarkdownFrontmatter.stripped(skillBody)
                .replacingOccurrences(of: "$ARGUMENTS", with: prURL),
            agentKind: agentKind
        )
    }
}
