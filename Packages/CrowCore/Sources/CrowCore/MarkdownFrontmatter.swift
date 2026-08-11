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
    ///
    /// Scans the UTF-8 view rather than `components(separatedBy: "\n")`. Swift
    /// treats `"\r\n"` as a **single** grapheme cluster, and Foundation's
    /// grapheme-aware search differs by platform: Darwin splits a CRLF document
    /// on the embedded `\n`, swift-corelibs-foundation does not, so on Linux the
    /// whole file came back as one "line" and nothing was ever stripped. Bytes
    /// behave identically everywhere.
    public static func stripped(_ body: String) -> String {
        let bytes = Array(body.utf8)

        guard let opening = line(in: bytes, at: 0), isDelimiter(bytes, opening.content) else {
            return body
        }

        // Search from line 2: the opening delimiter must not close itself.
        var cursor = opening.next
        while let current = line(in: bytes, at: cursor) {
            guard isDelimiter(bytes, current.content) else {
                cursor = current.next
                continue
            }
            // Skip blank lines after the closing delimiter so the result starts
            // at the body's first real character.
            var start = current.next
            while let following = line(in: bytes, at: start), isBlank(bytes, following.content) {
                start = following.next
            }
            // `start` is always a line boundary, so the slice is valid UTF-8.
            return String(decoding: bytes[start...], as: UTF8.self)
        }

        return body
    }

    /// The line beginning at `offset`: its content without the line terminator,
    /// and the offset the next line starts at. `nil` once `offset` is past the end.
    private static func line(
        in bytes: [UInt8], at offset: Int
    ) -> (content: Range<Int>, next: Int)? {
        guard offset < bytes.count else { return nil }

        var end = offset
        while end < bytes.count, bytes[end] != Self.lineFeed { end += 1 }

        // Drop a CRLF's carriage return from the content, not from the offsets.
        var contentEnd = end
        if contentEnd > offset, bytes[contentEnd - 1] == Self.carriageReturn { contentEnd -= 1 }

        return (offset..<contentEnd, end < bytes.count ? end + 1 : bytes.count)
    }

    /// A line whose content is exactly `---`.
    private static func isDelimiter(_ bytes: [UInt8], _ content: Range<Int>) -> Bool {
        content.count == 3 && bytes[content].allSatisfy { $0 == Self.hyphen }
    }

    /// A line with nothing but horizontal whitespace on it.
    private static func isBlank(_ bytes: [UInt8], _ content: Range<Int>) -> Bool {
        bytes[content].allSatisfy { $0 == Self.space || $0 == Self.tab }
    }

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let hyphen: UInt8 = 0x2D
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
}
