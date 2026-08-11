import Foundation
import Testing
@testable import CrowCore

/// Tests for the frontmatter strip applied to inlined review prompts (CROW-968).
///
/// The bug this guards: the `crow-review-pr` SKILL body was inlined verbatim into
/// `.crow-review-prompt.md`, so the prompt's first byte was `-` and Cursor's
/// commander-based `agent` parsed it as a flag — `error: unknown option '---`.
/// The review session died before it started.
///
/// The no-op cases matter just as much as the stripping one: this helper runs on
/// every inlined review body, including bodies that legitimately have no
/// frontmatter (`Scaffolder.bundledReviewSkill()`'s built-in fallback, the engine
/// test fixtures). Damaging those would trade one dead-review mode for another.
@Suite("MarkdownFrontmatter")
struct MarkdownFrontmatterTests {

    /// The real `skills/crow-review-pr/SKILL.md` shape, including the `description:
    /// >-` folded block scalar that spans three lines — a naive "find the next
    /// line containing `---`" scan would still work here, but a body-aware one
    /// would need to understand YAML. Pinning the actual shape keeps the simple
    /// parser honest.
    private static let skillShaped = """
    ---
    name: crow-review-pr
    description: >-
      Perform a comprehensive code and security review on a GitHub pull request,
      then post the findings as a PR review. Use when the user invokes
      /crow-review-pr or asks to review a pull request through Crow.
    ---

    # Crow Review PR

    Review PR $ARGUMENTS.
    """

    @Test func stripsTheSkillFrontmatterBlock() {
        let stripped = MarkdownFrontmatter.stripped(Self.skillShaped)

        // The defect itself: a leading `-` is what `agent` read as a flag.
        #expect(!stripped.hasPrefix("-"))
        #expect(!stripped.hasPrefix("---"))
        // Metadata gone — including the folded-scalar continuation lines, which a
        // parser that stopped at the first `---` after line 1 would leave behind.
        #expect(!stripped.contains("name: crow-review-pr"))
        #expect(!stripped.contains("description:"))
        #expect(!stripped.contains("Use when the user invokes"))
        // Body intact and starting at its first real character (the blank line
        // between the closing delimiter and the heading is dropped).
        #expect(stripped == """
        # Crow Review PR

        Review PR $ARGUMENTS.
        """)
    }

    /// `Scaffolder.bundledReviewSkill()` returns a frontmatter-free stub whenever
    /// the repo root can't be resolved (every test process), and the engine's
    /// prompt fixtures have none either. Those bodies must come back byte-identical.
    @Test func isANoOpWithoutFrontmatter() {
        let body = """
        # Crow Review PR
        Review PR $ARGUMENTS — checkout via `gh pr checkout $ARGUMENTS`.
        """

        #expect(MarkdownFrontmatter.stripped(body) == body)
    }

    /// An opening `---` with no closing one is not a frontmatter block. Returning
    /// the input unchanged is the safe reading — the alternative (consume to EOF)
    /// would hand the agent an empty prompt and leave it idling, the exact silent
    /// failure CROW-439's preflight exists to prevent.
    @Test func isANoOpWhenTheBlockIsNeverClosed() {
        let body = """
        ---
        name: crow-review-pr

        # Crow Review PR
        """

        #expect(MarkdownFrontmatter.stripped(body) == body)
    }

    /// Frontmatter is column-1-only, so an indented `---` is body content (a YAML
    /// snippet inside a fenced block, say), not a delimiter.
    @Test func isANoOpWhenTheDelimiterIsNotOnTheFirstLine() {
        let indented = "  ---\nname: x\n---\nbody"
        #expect(MarkdownFrontmatter.stripped(indented) == indented)

        let laterBlock = "# Heading\n\n---\nname: x\n---\nbody"
        #expect(MarkdownFrontmatter.stripped(laterBlock) == laterBlock)
    }

    @Test func isANoOpOnAnEmptyBody() {
        #expect(MarkdownFrontmatter.stripped("") == "")
    }

    /// Splitting on `\n` leaves `\r` attached to every line of a CRLF document, so
    /// the delimiter check has to tolerate it — otherwise a CRLF SKILL body would
    /// silently keep its frontmatter and reintroduce CROW-968.
    @Test func handlesCRLFLineEndings() {
        let body = "---\r\nname: crow-review-pr\r\n---\r\n\r\n# Crow Review PR\r\nBody."

        let stripped = MarkdownFrontmatter.stripped(body)

        #expect(!stripped.hasPrefix("-"))
        #expect(!stripped.contains("name: crow-review-pr"))
        // The body's own CRLF endings survive — only the frontmatter is removed.
        #expect(stripped == "# Crow Review PR\r\nBody.")
    }

    /// An empty frontmatter block still strips, and must not leave the result
    /// starting on a delimiter or a blank line.
    @Test func stripsAnEmptyFrontmatterBlock() {
        #expect(MarkdownFrontmatter.stripped("---\n---\n\n# Body") == "# Body")
    }

    /// Only the FIRST block goes. A `---` horizontal rule later in the body is
    /// content and must survive — the strip is not a global delete.
    @Test func leavesLaterHorizontalRulesAlone() {
        let stripped = MarkdownFrontmatter.stripped("""
        ---
        name: x
        ---

        # Body

        ---

        ## Section
        """)

        #expect(stripped == """
        # Body

        ---

        ## Section
        """)
    }
}
