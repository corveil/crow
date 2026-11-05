import Testing
@testable import CrowCodex

/// CROW-1410: the startup-notice override and the migration-screen detector.
/// Screens are verbatim `capture-pane -p` captures from codex-cli 0.166.0.
@Suite("CodexStartupNotices")
struct CodexStartupNoticesTests {
    /// The model-migration screen as Codex 0.166.0 draws it inline
    /// (`--no-alt-screen`), with the trailing blank rows tmux pads.
    static let migrationScreen = """
          Crow New is here.

        › 1. Try new model
          2. Use existing model

          enter/esc confirm · ⌃c quit






        """

    /// The same screen after `2`, before Enter.
    static let migrationScreenSecondHighlighted = """
          Meet GPT-6 Sol
          Our latest Sol is more intelligent and more efficient so your usage limits go further.

          1. Try new model
        › 2. Use existing model

          enter/esc confirm · ctrl + c quit
        """

    /// The composer after the prompt is answered.
    static let composer = """
          >_ OpenAI Codex (v0.166.0)
             /tmp/repro/proj

          Tip: When the composer is empty, press Esc to step back and edit your last message; Enter confirms.


        › Ask Codex to do anything

          Crow Old default · /tmp/repro/proj
        """

    @Test func overrideIsQuoteFreeAndMarksALaunch() {
        #expect(CodexStartupNotices.configOverrides == " -c check_for_update_on_startup=false")
        #expect(!CodexStartupNotices.configOverrides.contains("\""))
        #expect(CodexStartupNotices.isCodexLaunch("codex -c check_for_update_on_startup=false --no-alt-screen"))
        #expect(!CodexStartupNotices.isCodexLaunch("codex --no-alt-screen"))
        #expect(!CodexStartupNotices.isCodexLaunch("claude --continue"))
    }

    @Test func migrationScreenIsAnsweredWithUseExistingModel() {
        #expect(CodexStartupNotices.response(toScreen: Self.migrationScreen)
            == .answer(keys: ["2", "Enter"]))
        #expect(CodexStartupNotices.response(toScreen: Self.migrationScreenSecondHighlighted)
            == .answer(keys: ["2", "Enter"]))
    }

    @Test func noOptOutScreenIsLeftForTheOperator() {
        let screen = """
              GPT-5.4 is no longer available

              Codex now uses GPT-6 Sol in place of GPT-5.4. Switch to GPT-6 Sol to continue.

              enter/esc continue · ⌃c quit
            """
        guard case .needsOperator = CodexStartupNotices.response(toScreen: screen) else {
            Issue.record("expected needsOperator")
            return
        }
    }

    @Test func runningSessionIsIgnored() {
        #expect(CodexStartupNotices.response(toScreen: Self.composer) == nil)
        #expect(CodexStartupNotices.response(toScreen: "") == nil)
    }

    /// A transcript that quotes the screen (a ticket about this very bug) must
    /// not be answered: the composer is still the bottom of the pane.
    @Test func quotedPromptInTheTranscriptIsIgnored() {
        let screen = """
            • Codex sat on this screen:

              › 1. Try new model
                2. Use existing model
                enter/esc confirm · ⌃c quit

            › Ask Codex to do anything

              gpt-5.6-terra default · ~/dev
            """
        #expect(CodexStartupNotices.response(toScreen: screen) == nil)
    }

    /// The update screen is suppressed by the override, so the detector never
    /// presses anything on it (its default, "Update now", runs npm).
    @Test func updateScreenIsNotAnswered() {
        let screen = """
              Update available · 0.166.0 → 9.9.9
              Release notes: https://github.com/openai/codex/releases/latest

            › 1. Update now (runs `npm install -g @openai/codex`)
              2. Skip
              3. Skip until next version

              enter continue · esc skip
            """
        #expect(CodexStartupNotices.response(toScreen: screen) == nil)
    }

    @Test func optionsMustSitDirectlyAboveTheFooter() {
        let screen = """
            › 1. Try new model
              2. Use existing model
              something else
              enter/esc confirm · ⌃c quit
            """
        #expect(CodexStartupNotices.response(toScreen: screen) == nil)
    }
}
