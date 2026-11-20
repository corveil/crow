import Foundation
import Testing
@testable import CrowCore

/// The composer probe behind pre-expiry `/compact` (CROW-1493). The fixtures are
/// shaped on a `capture-pane -p -e` of Claude Code 2.1.330.
@Suite struct ClaudeComposerTests {
    static let esc = "\u{1B}"

    /// The bottom of an idle Claude Code pane, with `composer` as the prompt row.
    static func pane(_ composer: String, extra: [String] = []) -> String {
        ([
            "\(esc)[38;5;246m  ⎿  Done\(esc)[39m",
            "",
            "\(esc)[38;5;244m──────────────── crow-1493-context-size-compaction ─",
            composer,
        ] + extra + [
            "\(esc)[38;5;244m────────────────────────────────────────────────",
            "\(esc)[39m  \(esc)[36m[Opus 5.5 | Max]\(esc)[38;5;246m 21%",
            "  \(esc)[38;5;220m⏵⏵\(esc)[39m \(esc)[38;5;220mauto mode on\(esc)[38;5;246m (shift+tab to cycle)\(esc)[39m",
        ]).joined(separator: "\n")
    }

    @Test func emptyComposer() {
        #expect(ClaudeComposer.state(ofCapture: Self.pane("\(Self.esc)[38;5;246m❯ \(Self.esc)[39m")) == .empty)
    }

    @Test func typedTextIsInput() {
        #expect(ClaudeComposer.state(ofCapture: Self.pane("\(Self.esc)[38;5;246m❯ \(Self.esc)[39mfix the build")) == .hasInput)
    }

    @Test func plainCaptureWithTextIsInput() {
        // No escapes at all: default color, so it counts.
        #expect(ClaudeComposer.state(ofCapture: Self.pane("> half a thought")) == .hasInput)
    }

    @Test func dimSuggestionIsNotInput() {
        let row = "\(Self.esc)[38;5;246m❯ \(Self.esc)[39m\(Self.esc)[2mrun the tests again\(Self.esc)[0m"
        #expect(ClaudeComposer.state(ofCapture: Self.pane(row)) == .empty)
    }

    @Test func grayPlaceholderIsNotInput() {
        let indexed = "❯ \(Self.esc)[38;5;245mTry \"how does this work?\"\(Self.esc)[39m"
        let rgb = "❯ \(Self.esc)[38;2;153;153;153mTry \"refactor\"\(Self.esc)[39m"
        let bright = "❯ \(Self.esc)[90mTry\(Self.esc)[39m"
        #expect(ClaudeComposer.state(ofCapture: Self.pane(indexed)) == .empty)
        #expect(ClaudeComposer.state(ofCapture: Self.pane(rgb)) == .empty)
        #expect(ClaudeComposer.state(ofCapture: Self.pane(bright)) == .empty)
    }

    @Test func unknownColorCountsAsInput() {
        // White (a dark theme's typed text) and an unknown hue are not gray.
        let white = "❯ \(Self.esc)[38;2;240;240;240mtyped\(Self.esc)[39m"
        let hue = "❯ \(Self.esc)[38;5;174mtyped\(Self.esc)[39m"
        #expect(ClaudeComposer.state(ofCapture: Self.pane(white)) == .hasInput)
        #expect(ClaudeComposer.state(ofCapture: Self.pane(hue)) == .hasInput)
    }

    @Test func resetAfterDimRestoresDefault() {
        let row = "❯ \(Self.esc)[2mghost\(Self.esc)[0m real"
        #expect(ClaudeComposer.state(ofCapture: Self.pane(row)) == .hasInput)
    }

    @Test func multiLineDraftIsInputEvenWhenTheFirstRowIsEmpty() {
        #expect(ClaudeComposer.state(ofCapture: Self.pane("❯ ", extra: ["  second line"])) == .hasInput)
    }

    @Test func noComposerIsNotFound() {
        #expect(ClaudeComposer.state(ofCapture: "Do you trust the files in this folder?\n❯ 1. Yes") == .notFound)
        // Bash mode swaps the glyph: not a composer this can read.
        #expect(ClaudeComposer.state(ofCapture: Self.pane("! ls")) == .notFound)
        #expect(ClaudeComposer.state(ofCapture: "") == .notFound)
    }

    @Test func oscHyperlinksAndBackgroundColorsAreSkipped() {
        let link = "❯ \(Self.esc)]8;;https://x\u{07}\(Self.esc)]8;;\u{07}\(Self.esc)[48;5;236m \(Self.esc)[49m"
        #expect(ClaudeComposer.state(ofCapture: Self.pane(link)) == .empty)
    }
}
