import Foundation
import Testing
import CrowCore
@testable import CrowEngine

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

    private static let prURL = "https://github.com/corveil/crow/pull/123"
    private static let prTitle = "Some PR"
    private static let repoSlug = "corveil/crow"
    private static let prNumber = 123

    /// Minimal SKILL-shaped fixture. Avoids depending on
    /// `Scaffolder.bundledReviewSkill()`, which falls back to a trivial stub
    /// when the test executable can't resolve the repo root from its argv0.
    private static let fixtureSkillBody = """
    # Crow Review PR
    Review PR $ARGUMENTS — checkout via `gh pr checkout $ARGUMENTS`.

    [🐦‍⬛ Reviewed by Crow via ${CROW_AGENT_DISPLAY_NAME:-Claude Code}](https://github.com/corveil/crow)
    """

    /// SKILL-shaped fixture carrying the CROW-963 verdict placeholders, in the
    /// same shape the real skill has them. Kept separate from `fixtureSkillBody`
    /// so the pre-existing substitution tests stay a minimal input.
    private static let policyFixtureSkillBody = """
    # Crow Review PR
    Review PR $ARGUMENTS.

    \(ReviewVerdictPolicy.rulePlaceholder)

    | Color  | Meaning      | Verdict effect            |
    |--------|--------------|---------------------------|
    \(ReviewVerdictPolicy.tablePlaceholder)

    \(ReviewVerdictPolicy.notesPlaceholder)
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
        #expect(!prompt.contains("${CROW_AGENT_DISPLAY_NAME:-Claude Code}"))
        #expect(!prompt.contains("$CROW_AGENT_DISPLAY_NAME"))
        // The canonical URL must remain — only the agent-name segment is
        // swapped.
        #expect(prompt.contains("https://github.com/corveil/crow"))
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

    @Test func buildReviewPromptCodexBranchInlinesSkillBody() {
        // #843 review round 2: Codex has no slash-command engine, so it MUST
        // get the inlined SKILL body — not the bare `/crow-review-pr <URL>`
        // one-liner it can't resolve (which would leave the review unable to
        // post a verdict and stuck in the re-kick loop). Guards the regression
        // where `.codex` silently fell into the Claude `default` branch.
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .codex
        )

        #expect(!prompt.isEmpty)
        #expect(!prompt.hasPrefix("/crow-review-pr"))
    }

    @Test func buildReviewPromptGrokBranchInlinesSkillBody() {
        // #861 review round 5: Grok has no slash-command engine either, so it
        // MUST get the inlined SKILL body — not the bare `/crow-review-pr <URL>`
        // one-liner it can't resolve (which would leave the review unable to
        // post a verdict and stuck in the re-kick loop). Guards the regression
        // where `.grok` silently fell into the Claude `default` branch, despite
        // the matrix / GrokAgent comments claiming the inlined-skill contract.
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .grok
        )

        #expect(!prompt.isEmpty)
        #expect(!prompt.hasPrefix("/crow-review-pr"))
    }

    @Test func buildReviewPromptAntigravityBranchInlinesSkillBody() {
        // #902: Antigravity has no Crow slash-command engine, so like
        // Cursor/Codex/OpenCode it MUST get the inlined SKILL body — not the bare
        // `/crow-review-pr <URL>` one-liner it can't resolve (which would leave
        // the review unable to run `gh pr review` and post a verdict). Guards the
        // regression where `.antigravity` silently fell into the Claude `default`
        // branch.
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .antigravity
        )

        #expect(!prompt.isEmpty)
        #expect(!prompt.hasPrefix("/crow-review-pr"))
        // Pin the *exact* inline branch (not merely "any non-Claude branch") and
        // the `.antigravity` agentKind threading: the output must equal the
        // inline-SKILL helper called with `.antigravity`. Independent of whether
        // `bundledReviewSkill()` returns the real skill or the test-env stub —
        // both sides resolve it identically — so this catches a stray `.antigravity`
        // in a different non-Claude branch OR a wrong-agentKind footer (#902 review
        // Green 1).
        #expect(prompt == SessionService.cursorReviewPrompt(
            skillBody: Scaffolder.bundledReviewSkill(),
            prURL: Self.prURL,
            agentKind: .antigravity))
    }

    // MARK: - Per-workspace verdict policy (CROW-963)

    /// The acceptance criterion a file-copy-only implementation fails.
    ///
    /// Claude reads the copied `.claude/skills/crow-review-pr/SKILL.md`, but
    /// Cursor/OpenCode/Codex/Grok/Antigravity read the **inlined** prompt body —
    /// and `agentsByKind.review` is commonly Cursor, so the inlined path is the
    /// normal case, not an edge one. `prepareReviewClone` renders the workspace's
    /// policy once and passes the result in via `skillBody:`; if that parameter
    /// stops being threaded, the inlining agents silently revert to the default
    /// rule while the copied file is correct.
    @Test func buildReviewPromptInlineBranchesCarryTheWorkspacePolicy() {
        let redOnlyBody = ReviewVerdictPolicy.expand(
            Self.policyFixtureSkillBody, blocking: [.red])

        for agentKind: AgentKind in [.cursor, .openCode, .codex, .grok, .antigravity] {
            let prompt = SessionService.buildReviewPrompt(
                prURL: Self.prURL,
                prTitle: Self.prTitle,
                repoSlug: Self.repoSlug,
                prNumber: Self.prNumber,
                agentKind: agentKind,
                skillBody: redOnlyBody
            )

            #expect(prompt.contains("any Red finding"), "\(agentKind.rawValue) lost the policy")
            #expect(!prompt.contains("any Red **or** any Yellow finding"))
            #expect(prompt.contains("| Yellow | Should fix   | Approve allowed           |"))
            // Q4: relaxing Yellow must not stop it being reported.
            #expect(prompt.contains("Report every one of them in the review body"))
            // The policy must not cost us the existing substitutions.
            #expect(prompt.contains(Self.prURL))
            #expect(!prompt.contains("$ARGUMENTS"))
            #expect(!prompt.contains("{{CROW_REVIEW_VERDICT_"))
        }
    }

    /// Omitting `skillBody:` must keep the pre-CROW-963 behaviour exactly, so
    /// every existing caller and test is unaffected by the new parameter.
    @Test func buildReviewPromptWithoutASkillBodyFallsBackToTheBundledSkill() {
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .cursor
        )

        #expect(prompt == SessionService.cursorReviewPrompt(
            skillBody: Scaffolder.bundledReviewSkill(),
            prURL: Self.prURL,
            agentKind: .cursor))
    }

    /// A policy-expanded body passed through `cursorReviewPrompt` — which calls
    /// `CrowAttribution.expandSkillBody`, which expands the policy AGAIN with the
    /// default set — must keep the workspace's policy, not have it overwritten.
    @Test func cursorPromptDoesNotLetTheSecondExpansionOverwriteThePolicy() {
        let redOnlyBody = ReviewVerdictPolicy.expand(
            Self.policyFixtureSkillBody, blocking: [.red])
        let prompt = SessionService.cursorReviewPrompt(
            skillBody: redOnlyBody, prURL: Self.prURL, agentKind: .cursor)

        #expect(prompt.contains("any Red finding"))
        #expect(!prompt.contains("any Red **or** any Yellow finding"))
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
