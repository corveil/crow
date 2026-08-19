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

    \(ReviewVerdictPolicy.gradingGuidancePlaceholder)

    | Color  | Meaning      | Verdict effect            |
    |--------|--------------|---------------------------|
    \(ReviewVerdictPolicy.tablePlaceholder)

    \(ReviewVerdictPolicy.notesPlaceholder)
    """

    /// SKILL-shaped fixture carrying the CROW-1062 static architecture-study prose
    /// (the Step 3 sub-step + the review-body section) alongside the placeholders.
    /// Because the study step is static prose — not a placeholder — the inline
    /// pipeline (frontmatter strip, `$ARGUMENTS`, attribution expansion) must carry
    /// it through untouched. Kept minimal so a reword in the real skill fails the
    /// CrowCore pin, while this asserts the *transport* preserves it.
    private static let architectureFixtureSkillBody = """
    # Crow Review PR
    Review PR $ARGUMENTS.

    **Architecture & Existing Patterns (study this before scoring the diff):**

    - Name the existing pathway the change should have extended, or state plainly that none exists.
    - Invents a parallel mechanism where a small extension of current behavior would do.

    These are defects in **this change** — grade them **Yellow** (should-fix) or **Red** (must-fix), never Green "consider later."

    ### Architecture / Existing Patterns

    \(ReviewVerdictPolicy.rulePlaceholder)
    """

    /// `fixtureSkillBody` with the real skill's YAML frontmatter prepended — the
    /// shape `Scaffolder.bundledReviewSkill()` actually returns in production, and
    /// the one that killed every Cursor review (CROW-968).
    private static let frontmatterSkillBody = """
    ---
    name: crow-review-pr
    description: >-
      Perform a comprehensive code and security review on a GitHub pull request,
      then post the findings as a PR review. Use when the user invokes
      /crow-review-pr or asks to review a pull request through Crow.
    ---

    \(fixtureSkillBody)
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

    @Test func buildReviewPromptMuseBranchInlinesSkillBody() {
        // #1033: Muse has no Crow slash-command engine, so like
        // Cursor/Codex/OpenCode/Grok/Antigravity it MUST get the inlined SKILL
        // body — not the bare `/crow-review-pr <URL>` one-liner it can't
        // resolve. Guards the regression where `.muse` silently fell into the
        // Claude `default` branch.
        let prompt = SessionService.buildReviewPrompt(
            prURL: Self.prURL,
            prTitle: Self.prTitle,
            repoSlug: Self.repoSlug,
            prNumber: Self.prNumber,
            agentKind: .muse
        )

        #expect(!prompt.isEmpty)
        #expect(!prompt.hasPrefix("/crow-review-pr"))
        #expect(prompt == SessionService.cursorReviewPrompt(
            skillBody: Scaffolder.bundledReviewSkill(),
            prURL: Self.prURL,
            agentKind: .muse))
    }

    // MARK: - Frontmatter strip (CROW-968)

    /// The inlined prompt is handed to the agent CLI as a bare positional
    /// argument. With the SKILL's `---` frontmatter still attached, its first byte
    /// was `-`, so Cursor's commander-based `agent` parsed it as a flag and exited
    /// with `error: unknown option '---` before the review ever began. Shell
    /// quoting does not cover this — `printf %q` protects the string from the
    /// shell, but a leading hyphen is not shell-special and survives into argv.
    @Test func cursorPromptStripsTheSkillFrontmatter() {
        let prompt = SessionService.cursorReviewPrompt(
            skillBody: Self.frontmatterSkillBody,
            prURL: Self.prURL
        )

        // The defect, stated directly.
        #expect(!prompt.hasPrefix("-"))
        #expect(!prompt.hasPrefix("---"))
        // Skill-engine metadata has no reader in an inlined brief and costs
        // tokens on every review — including the folded-scalar continuation lines.
        #expect(!prompt.contains("name: crow-review-pr"))
        #expect(!prompt.contains("description:"))
        #expect(!prompt.contains("Use when the user invokes"))
        // The strip must not cost us the body or the other substitutions.
        #expect(prompt.contains("Review PR \(Self.prURL)"))
        #expect(prompt.contains("gh pr checkout \(Self.prURL)"))
        #expect(prompt.contains("via Cursor"))
    }

    /// Stripping runs on every inlined body, and most of them have no frontmatter
    /// — `Scaffolder.bundledReviewSkill()`'s built-in fallback (returned whenever
    /// the repo root can't be resolved, i.e. in every test process) and the
    /// fixtures here. Those must pass through untouched, or the fix would trade
    /// one dead-review mode for another.
    @Test func cursorPromptIsUnchangedForABodyWithoutFrontmatter() {
        let withFrontmatter = SessionService.cursorReviewPrompt(
            skillBody: Self.frontmatterSkillBody, prURL: Self.prURL)
        let without = SessionService.cursorReviewPrompt(
            skillBody: Self.fixtureSkillBody, prURL: Self.prURL)

        // Same body in, same prompt out — the frontmatter is the only difference
        // between the two fixtures, so stripping must collapse them exactly.
        #expect(withFrontmatter == without)
    }

    /// Every inlining harness reaches the agent CLI's argument parser the same
    /// way, so none of them may emit a leading `-`. Mirrors the agent loop in
    /// `buildReviewPromptInlineBranchesCarryTheWorkspacePolicy`.
    @Test func noInlineBranchEmitsALeadingHyphen() {
        for agentKind: AgentKind in [.cursor, .openCode, .codex, .grok, .antigravity, .muse] {
            let prompt = SessionService.buildReviewPrompt(
                prURL: Self.prURL,
                prTitle: Self.prTitle,
                repoSlug: Self.repoSlug,
                prNumber: Self.prNumber,
                agentKind: agentKind,
                skillBody: Self.frontmatterSkillBody
            )

            #expect(!prompt.hasPrefix("-"), "\(agentKind.rawValue) would be parsed as a flag")
            #expect(!prompt.contains("name: crow-review-pr"), "\(agentKind.rawValue) kept its frontmatter")
        }
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

        for agentKind: AgentKind in [.cursor, .openCode, .codex, .grok, .antigravity, .muse] {
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

    /// CROW-986: the grading-guidance rules bound the *grade*, not the *gate*, so
    /// they must reach the agent through every inline branch and read identically
    /// under any workspace policy. Assert the built prompt carries all three rules
    /// for both the default (Red+Yellow) and a relaxed (Red-only) workspace.
    @Test func buildReviewPromptCarriesTheGradingGuidanceForEveryPolicy() {
        for blocking in [ReviewSeverity.defaultBlocking, [.red]] {
            let body = ReviewVerdictPolicy.expand(Self.policyFixtureSkillBody, blocking: blocking)

            for agentKind: AgentKind in [.cursor, .openCode, .codex, .grok, .antigravity, .muse] {
                let prompt = SessionService.buildReviewPrompt(
                    prURL: Self.prURL,
                    prTitle: Self.prTitle,
                    repoSlug: Self.repoSlug,
                    prNumber: Self.prNumber,
                    agentKind: agentKind,
                    skillBody: body
                )

                #expect(prompt.contains("An accepted risk is not a blocker."),
                        "\(agentKind.rawValue)/\(blocking) lost the accepted-risk rule")
                #expect(prompt.contains("Do not re-block a declined finding."),
                        "\(agentKind.rawValue)/\(blocking) lost the declined-finding rule")
                #expect(prompt.contains("Grade against the diff, not the roadmap."),
                        "\(agentKind.rawValue)/\(blocking) lost the grade-against-the-diff rule")
                // No verdict-family placeholder may survive expansion.
                #expect(!prompt.contains("{{CROW_REVIEW_"))
            }
        }
    }

    /// CROW-1062: the Step 3 architecture-study prose is static (not a
    /// placeholder), so the inline pipeline — frontmatter strip, `$ARGUMENTS`
    /// substitution, attribution expansion — must carry it to every non-Claude
    /// harness verbatim. If the strip or expansion ever dropped a static section,
    /// the inlining agents would review against the diff only while the copied
    /// SKILL.md (which Claude reads) still had it. Mirrors the grading-guidance
    /// transport test above.
    @Test func buildReviewPromptCarriesTheArchitectureStudyForEveryInlineAgent() {
        for agentKind: AgentKind in [.cursor, .openCode, .codex, .grok, .antigravity, .muse] {
            let prompt = SessionService.buildReviewPrompt(
                prURL: Self.prURL,
                prTitle: Self.prTitle,
                repoSlug: Self.repoSlug,
                prNumber: Self.prNumber,
                agentKind: agentKind,
                skillBody: Self.architectureFixtureSkillBody
            )

            #expect(prompt.contains("Architecture & Existing Patterns (study this before scoring the diff):"),
                    "\(agentKind.rawValue) lost the architecture study step")
            #expect(prompt.contains("Name the existing pathway the change should have extended"),
                    "\(agentKind.rawValue) lost the name-the-existing-pathway instruction")
            #expect(prompt.contains("grade them **Yellow** (should-fix) or **Red** (must-fix), never Green"),
                    "\(agentKind.rawValue) lost the Yellow/Red grade for architecture findings")
            #expect(prompt.contains("### Architecture / Existing Patterns"),
                    "\(agentKind.rawValue) lost the review-body architecture section")
            // The transport must not cost us the existing substitutions.
            #expect(prompt.contains(Self.prURL))
            #expect(!prompt.contains("$ARGUMENTS"))
            #expect(!prompt.contains("{{CROW_REVIEW_"))
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
