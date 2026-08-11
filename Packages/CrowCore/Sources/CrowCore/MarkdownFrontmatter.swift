import Foundation

/// Leading YAML frontmatter (`---` … `---`) handling for markdown bodies Crow
/// inlines into agent prompts.
///
/// Crow ships the `crow-review-pr` instructions as a SKILL file, which carries
/// `name`/`description` frontmatter because Claude Code's skill engine requires
/// it. Agents without a slash-command engine (Cursor, OpenCode, Codex, Grok,
/// Antigravity) get that body **inlined** into `.crow-review-prompt.md` instead,
/// where the frontmatter is worse than useless:
///
/// - It is skill-engine metadata the inlined brief has no reader for, and it
///   costs tokens on every review.
/// - It makes the prompt's first byte a `-`, so a CLI that parses its positional
///   prompt with an option parser reads it as a flag and exits. Cursor's
///   commander-based `agent` did exactly that — `error: unknown option '---`
///   (CROW-968). Shell quoting does not save you here: `printf %q` protects the
///   string from the *shell*, but a leading hyphen is not shell-special, so it
///   reaches the binary's argv intact.
///
/// Only the **inlined** copy is stripped. The `.claude/skills/crow-review-pr/
/// SKILL.md` Crow writes into a review clone keeps its frontmatter, as do the
/// checked-in `skills/crow-review-pr/SKILL.md` and its bundled `.template`
/// (`scripts/check-workspace-custom-instructions.sh` enforces that).
public enum MarkdownFrontmatter {
    private static let delimiter = "---"

    /// Drop a leading YAML frontmatter block, returning the body that follows.
    ///
    /// Deliberately conservative — the inputs include bodies that legitimately
    /// have no frontmatter (`Scaffolder.bundledReviewSkill()`'s built-in fallback,
    /// every test fixture), so the no-op path is the common one and must never
    /// damage its input:
    ///
    /// - The **first** line must be exactly `---`. Frontmatter is column-1 only,
    ///   so an indented `---` is left alone.
    /// - A closing `---` line must exist. Without one this is not a frontmatter
    ///   block, and the input is returned unchanged rather than consumed whole.
    /// - Leading blank lines after the closing delimiter are dropped, so the
    ///   result starts at the body's first real character.
    ///
    /// CRLF-terminated lines are recognized. The one accepted false positive is a
    /// document that opens with a markdown horizontal rule and contains a second
    /// one — indistinguishable from frontmatter by any line-based parser, and not
    /// a shape a SKILL body takes.
    public static func stripped(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let first = lines.first, isDelimiter(first) else { return body }
        // Search from line 2: the opening delimiter must not close itself.
        // `dropFirst()` yields a slice sharing `lines`' indices, so the returned
        // index addresses `lines` directly.
        guard let closing = lines.dropFirst().firstIndex(where: isDelimiter) else { return body }

        return lines[lines.index(after: closing)...]
            // `.whitespacesAndNewlines`, not `.whitespaces`: splitting a CRLF
            // document on `\n` makes a blank line the single character `\r`,
            // which `.whitespaces` (space + tab) does not match.
            .drop { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// A line that is exactly `---`, tolerating a CRLF carriage return. Splitting
    /// on `\n` leaves the `\r` attached to every line of a CRLF document.
    private static func isDelimiter(_ line: String) -> Bool {
        (line.hasSuffix("\r") ? String(line.dropLast()) : line) == delimiter
    }
}
