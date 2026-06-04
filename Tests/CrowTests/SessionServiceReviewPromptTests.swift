import Foundation
import Testing
import CrowCore
@testable import Crow

/// Branch tests for `SessionService.buildReviewPrompt` and the underlying
/// Cursor substitution helper `cursorReviewPrompt(skillBody:prURL:)` (#431).
///
/// The Cursor branch is the actual payload Cursor's `agent` CLI receives
/// as argv and the basis of the GitHub-posted review body — `$ARGUMENTS`
/// substitution and the `via Claude Code` → `via Cursor` attribution swap
/// are the deliverable. Without these tests, a reworded attribution line
/// or a renamed placeholder in the SKILL would silently produce a
/// misattributed review (or a literal `PR $ARGUMENTS` brief) with nothing
/// to catch it.
@Suite("Review prompt branch")
struct SessionServiceReviewPromptTests {

    private static let prURL = "https://github.com/radiusmethod/crow/pull/123"
    private static let prTitle = "Some PR"
    private static let repoSlug = "radiusmethod/crow"
    private static let prNumber = 123

    /// Minimal SKILL-shaped fixture. Avoids depending on
    /// `Scaffolder.bundledReviewSkill()`, which falls back to a trivial stub
    /// when the test executable can't resolve the repo root from its argv0.
    private static let fixtureSkillBody = """
    # Crow Review PR
    Review PR $ARGUMENTS — checkout via `gh pr checkout $ARGUMENTS`.

    [🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/radiusmethod/crow)
    """

    @Test func cursorPromptSubstitutesPRURLForArguments() {
        let prompt = SessionService.cursorReviewPrompt(
            skillBody: Self.fixtureSkillBody,
            prURL: Self.prURL
        )

        // Every `$ARGUMENTS` occurrence must become the PR URL — there are
        // two in the fixture, mirroring the real SKILL's "title + `gh pr
        // checkout`" pair.
        #expect(prompt.contains("Review PR \(Self.prURL)"))
        #expect(prompt.contains("gh pr checkout \(Self.prURL)"))
        // No raw placeholder should leak through; otherwise Cursor would
        // receive `gh pr checkout $ARGUMENTS` literally.
        #expect(!prompt.contains("$ARGUMENTS"))
    }

    @Test func cursorPromptSwapsAttributionToCursor() {
        let prompt = SessionService.cursorReviewPrompt(
            skillBody: Self.fixtureSkillBody,
            prURL: Self.prURL
        )

        // Attribution must identify the reviewing agent correctly so the
        // posted GitHub review body says "via Cursor", not "via Claude Code".
        #expect(prompt.contains("via Cursor"))
        #expect(!prompt.contains("via Claude Code"))
        // The canonical URL must remain — only the agent-name segment is
        // swapped.
        #expect(prompt.contains("https://github.com/radiusmethod/crow"))
    }

    @Test func buildReviewPromptCursorBranchUsesCursorHelper() {
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .cursor
        )

        // The Cursor branch dispatches into `cursorReviewPrompt` and embeds
        // the PR URL. Even if `Scaffolder.bundledReviewSkill()` returns the
        // trivial test-environment fallback (no `$ARGUMENTS`, no
        // attribution to swap), the dispatch must produce non-empty output
        // distinct from the Claude one-liner.
        #expect(!prompt.isEmpty)
        #expect(!prompt.hasPrefix("/crow-review-pr"))
    }

    @Test func buildReviewPromptClaudeBranchIsTerseSlashCommand() {
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .claudeCode
        )

        // Claude Code expands `/crow-review-pr <URL>` via its SKILL engine,
        // so the prompt file is intentionally a one-liner.
        #expect(prompt == "/crow-review-pr \(Self.prURL)")
    }

    @Test func buildReviewPromptUnknownAgentFallsBackToSlashCommand() {
        // Any non-Cursor agent (including the default branch) should get
        // the Claude-style slash-command form. This guards against an
        // accidental capability regression for future agents added to
        // `AgentKind` without an explicit branch.
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: AgentKind(rawValue: "hypothetical-future-agent")
        )

        #expect(prompt == "/crow-review-pr \(Self.prURL)")
    }

    // MARK: - initialPromptFileName (CROW-439)

    /// `launchAgent` uses `SessionService.initialPromptFileName(for:)` as its
    /// preflight check: if the named file isn't on disk when the shell runs
    /// the `$(cat …)` substitution, the agent launches with an empty prompt
    /// and silently idles. The mapping must stay in sync with the inline
    /// branches in `CursorAgent.autoLaunchCommand` and
    /// `ClaudeCodeAgent.autoLaunchCommand`.
    @Test func initialPromptFileNameMapsReviewToReviewPrompt() {
        #expect(SessionService.initialPromptFileName(for: .review) == ".crow-review-prompt.md")
    }

    @Test func initialPromptFileNameMapsJobToJobPrompt() {
        #expect(SessionService.initialPromptFileName(for: .job) == ".crow-job-prompt.md")
    }

    @Test func initialPromptFileNameIsNilForWorkAndManager() {
        // Work and manager sessions never inline an initial prompt — the
        // preflight check skips them entirely.
        #expect(SessionService.initialPromptFileName(for: .work) == nil)
        #expect(SessionService.initialPromptFileName(for: .manager) == nil)
    }
}
