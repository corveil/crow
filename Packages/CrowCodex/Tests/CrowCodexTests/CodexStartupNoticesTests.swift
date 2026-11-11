import Testing
@testable import CrowCodex

/// CROW-1410: the startup-notice override and the migration-screen detector.
/// CROW-1425: the 0.167 read-only provider notice. Screens are verbatim
/// `capture-pane -p` captures from codex-cli 0.166.0 (migration) and 0.167.1
/// (provider notice), except where a test says otherwise.
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
            == .answer(keys: ["2", "Enter"], screen: .modelMigration))
        #expect(CodexStartupNotices.response(toScreen: Self.migrationScreenSecondHighlighted)
            == .answer(keys: ["2", "Enter"], screen: .modelMigration))
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

    // MARK: Read-only provider notice (CROW-1425, codex-cli 0.167.1)

    /// `-c model_provider=provB resume --last` on a thread recorded under
    /// `provA`, 160 columns: the mismatch variant (routing toggled on).
    static let providerMismatchScreen = """
          >_ OpenAI Codex (v0.167.1)
             /private/tmp/claude-501/crow1425/proj

          Tip: Use the desktop app. Run codex app to open it. It installs automatically if needed.

        › say hi

        ■ Conversation interrupted - use /feedback if something went wrong

          🔒  Continue in a new chat
              This chat uses provA, but Codex now uses provB, so this chat is read-only.

          c continue in new chat · n start fresh · esc other chats




        """

    /// An unrouted `resume --last` on a thread recorded under Crow's per-run
    /// `crow-corveil` provider (routing toggled off), 160 columns.
    static let providerUnavailableScreen = """
        › say hi

        ■ Conversation interrupted - use /feedback if something went wrong

          🔒  Model provider unavailable
              This chat uses model provider “crow-corveil”, which is no longer configured. Restore this provider’s configuration to continue.

          c continue in new chat · n start fresh · esc other chats
        """

    /// The same screen in a 50-column pane (a phone): the description takes
    /// four rows and the footer wraps mid-shortcut.
    static let providerUnavailableNarrowScreen = """
        ■ Conversation interrupted - use /feedback if
        something went wrong

          🔒  Model provider unavailable
              This chat uses model provider “crow-
              corveil”, which is no longer configured.
              Restore this provider’s configuration to
              continue.

          c continue in new chat · n start fresh · esc
          other chats
        """

    @Test func providerNoticeIsAnsweredWithStartFresh() {
        let expected = CodexStartupNotices.Response.answer(keys: ["n"], screen: .providerNotice)
        #expect(CodexStartupNotices.response(toScreen: Self.providerMismatchScreen) == expected)
        #expect(CodexStartupNotices.response(toScreen: Self.providerUnavailableScreen) == expected)
        #expect(CodexStartupNotices.response(toScreen: Self.providerUnavailableNarrowScreen) == expected)
        #expect(CodexStartupNotices.startFreshKeys == ["n"])
    }

    /// 40 columns wraps the footer at a different point. From upstream's
    /// `provider_error_mismatch_local_40` render snapshot.
    @Test func providerNoticeFooterWrappedAtFortyColumns() {
        let screen = """
              🔒   Continue in a new chat
                  This chat uses Team Gateway, but
                  Codex now uses Amazon Bedrock
                  Runtime, so this chat is read-
                  only.

              c continue in new chat · n start fresh
              · esc other chats
            """
        #expect(CodexStartupNotices.response(toScreen: screen)
            == .answer(keys: ["n"], screen: .providerNotice))
    }

    /// The policy variants offer no continuation, so the footer has no `c`.
    /// From upstream's `provider_error_policy_provider_local_80` snapshot.
    @Test func policyNoticeWithoutContinueIsAnswered() {
        let screen = """
              🔒   Model provider blocked by policy
                  This chat uses model provider “OpenAI”, but your organization requires
                  “Amazon Bedrock”. Contact your administrator or start a new chat using
                  the required provider.

              n start fresh · esc other chats
            """
        #expect(CodexStartupNotices.response(toScreen: screen)
            == .answer(keys: ["n"], screen: .providerNotice))
    }

    /// A lock emoji in its emoji presentation (with U+FE0F) still matches.
    @Test func providerNoticeToleratesVariationSelector() {
        let screen = "  \u{1F512}\u{FE0F}  Continue in a new chat\n"
            + "      This chat uses a, but Codex now uses b, so this chat is read-only.\n\n"
            + "  c continue in new chat · n start fresh · esc other chats\n"
        #expect(CodexStartupNotices.response(toScreen: screen)
            == .answer(keys: ["n"], screen: .providerNotice))
    }

    /// A transcript that quotes the notice is not answered: the composer is
    /// the bottom of the pane.
    @Test func quotedProviderNoticeInTheTranscriptIsIgnored() {
        let screen = """
            • On 0.167 the pane showed:

                🔒  Continue in a new chat
                    This chat uses provA, but Codex now uses provB, so this chat is read-only.
                c continue in new chat · n start fresh · esc other chats

            › Ask Codex to do anything

              gpt-5.5 default · ~/dev
            """
        #expect(CodexStartupNotices.response(toScreen: screen) == nil)
    }

    /// The footer alone, or under a title Crow hasn't pinned, is not enough.
    @Test func providerFooterNeedsAKnownTitle() {
        let noTitle = """
              This chat uses provA, but Codex now uses provB, so this chat is read-only.

              c continue in new chat · n start fresh · esc other chats
            """
        let unknownTitle = """
              🔒  Something new
                  Some explanation.

              c continue in new chat · n start fresh · esc other chats
            """
        let titleTooFarUp = (["  🔒  Continue in a new chat"]
            + Array(repeating: "      description", count: 11)
            + ["  c continue in new chat · n start fresh · esc other chats"])
            .joined(separator: "\n")
        #expect(CodexStartupNotices.response(toScreen: noTitle) == nil)
        #expect(CodexStartupNotices.response(toScreen: unknownTitle) == nil)
        #expect(CodexStartupNotices.response(toScreen: titleTooFarUp) == nil)
    }

    @Test func onlyTheProviderNoticeEndsTheStartup() {
        #expect(CodexStartupNotices.Screen.providerNotice.isLastStartupScreen)
        #expect(!CodexStartupNotices.Screen.modelMigration.isLastStartupScreen)
    }
}
