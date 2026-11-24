import Foundation
import Testing
@testable import CrowCore

/// `AskUserQuestionPicker` against screens captured from Claude Code 2.1.331
/// (`tmux capture-pane -p`, 2026-11-23). The prompt above each picker repeats
/// the question text on purpose: only the picker's own region may count.
@Suite struct AskUserQuestionPickerTests {
    typealias P = AskUserQuestionPicker

    static let color = ChatQuestion(question: "Which color?", header: "Color", multiSelect: false, options: [
        .init(label: "Red", description: "warm"), .init(label: "Blue", description: "cool"),
        .init(label: "Green", description: "natural"),
    ])
    static let toppings = ChatQuestion(question: "Which toppings?", header: "Toppings", multiSelect: true, options: [
        .init(label: "Cheese", description: "dairy"), .init(label: "Olives", description: "salty"),
        .init(label: "Basil", description: "fresh"),
    ])
    static let pet = ChatQuestion(question: "Which pet?", header: "Pet", multiSelect: false, options: [
        .init(label: "Cat", description: "meow"), .init(label: "Dog", description: "woof"),
    ])
    static let two = [color, toppings]

    static let prompt = """
    ❯ Call the AskUserQuestion tool. Q1: header "Color", question "Which color?", multiSelect false. Q2: header
      "Toppings", question "Which toppings?", multiSelect true.
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    """

    static let colorScreen = prompt + """

    ←  ☐ Color  ☐ Toppings  ✔ Submit  →

    Which color?

    ❯ 1. Red
         warm
      2. Blue
         cool
      3. Green
         natural
      4. Type something.
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
      5. Chat about this

    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    static let toppingsScreen = prompt + """

    ←  ☒ Color  ☒ Toppings  ✔ Submit  →

    Which toppings?

    ❯ 1. [✔] Cheese
             dairy
      2. [ ] Olives
             salty
      3. [✔] Basil
             fresh
      4. [ ] Type something
         Submit
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
      5. Chat about this

    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    static let reviewScreen = prompt + """

    ←  ☒ Color  ☒ Toppings  ✔ Submit  →

    Review your answers

     ● Which color?
       → Blue
     ● Which toppings?
       → Cheese, Basil

    ❯ 1. Submit answers
      2. Cancel
    """

    static let petScreen = """
    ❯ Call AskUserQuestion once with ONE question: header "Pet", question "Which pet?"
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
     ☐ Pet

    Which pet?

    ❯ 1. Cat
         meow
      2. Dog
         woof
      3. Type something.
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
      4. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    static let idleScreen = """
    ⏺ Answered Claude's questions:
      ⎿  · Which color? → Teal
         · Which toppings? → Cheese, Basil, Ham
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    """

    // MARK: read

    @Test func readsASingleSelectQuestion() {
        guard case .question(let i, let rows) = P.read(Self.colorScreen, questions: Self.two) else {
            Issue.record("not a question screen"); return
        }
        #expect(i == 0)
        #expect(rows.compactMap(\.number) == [1, 2, 3, 4, 5])
        #expect(rows[0].isCursor)
        #expect(rows[0].text == "Red")
        #expect(rows[3].text == "Type something.")
        #expect(rows.allSatisfy { $0.checked == nil })
    }

    @Test func readsAMultiSelectQuestionWithItsSubmitRow() {
        guard case .question(let i, let rows) = P.read(Self.toppingsScreen, questions: Self.two) else {
            Issue.record("not a question screen"); return
        }
        #expect(i == 1)
        #expect(rows.map(\.checked) == [true, false, true, false, nil, nil])
        #expect(rows[4].isSubmit)
        #expect(rows[3].text == "Type something")
    }

    @Test func readsTheReviewStep() {
        #expect(P.read(Self.reviewScreen, questions: Self.two) == .review(cursorOnSubmit: true, allAnswered: true))
        let warned = Self.reviewScreen.replacingOccurrences(
            of: "Review your answers\n", with: "Review your answers\n\nSome questions are unanswered\n")
        #expect(P.read(warned, questions: Self.two) == .review(cursorOnSubmit: true, allAnswered: false))
    }

    @Test func aLoneQuestionHasABareTabBar() {
        guard case .question(0, let rows) = P.read(Self.petScreen, questions: [Self.pet]) else {
            Issue.record("not a question screen"); return
        }
        #expect(rows.count == 4)
    }

    @Test func noPickerOrAnotherCallsPickerIsAbsent() {
        #expect(P.read(Self.idleScreen, questions: Self.two) == .absent)
        // The Pet picker is up, but this call asked about colors.
        #expect(P.read(Self.petScreen, questions: Self.two) == .absent)
    }

    @Test func aQuestionTextThatDoesNotMatchIsUnrecognized() {
        let other = Self.colorScreen.replacingOccurrences(of: "\nWhich color?\n", with: "\nWhich colour?\n")
        #expect(P.read(other, questions: Self.two) == .unrecognized)
    }

    @Test func aWrappedQuestionStillMatches() {
        let long = ChatQuestion(
            question: "Which of these comment-loop changes should the scorer pick up before the next run?",
            header: "Comment loop", multiSelect: false, options: [.init(label: "A"), .init(label: "B")])
        let screen = """
        ←  ☐ Comment loop  ✔ Submit  →

        Which of these comment-loop changes should the scorer pick up
        before the next run?

        ❯ 1. A
          2. B
          3. Type something.
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        guard case .question(0, _) = P.read(screen, questions: [long]) else {
            Issue.record("wrapped question not matched"); return
        }
    }

    @Test func aDescriptionThatLooksNumberedIsNotARow() {
        #expect(P.parseRow("     3. Do the third thing") == nil)
        #expect(P.parseRow("  2. Blue ✔") == P.Row(number: 2, isCursor: false, checked: true, text: "Blue"))
        #expect(P.parseRow("❯ 1. 1. Tag worker comments")?.text == "1. Tag worker comments")
        #expect(P.parseRow("❯    Submit") == P.Row(number: nil, isCursor: true, checked: nil, text: "Submit"))
    }

    // MARK: tall pickers (CROW-1519)

    /// The reported picker: one multi-select question, four options with long
    /// descriptions, in an 80×24 pane (Claude Code 2.1.331, 2026-11-24). Same
    /// shape as the capture, text replaced.
    static let replies = ChatQuestion(
        question: "Which X replies should I post now? They follow the research: early, on mid-size accounts or "
            + "mutuals, each adding something concrete. No links, since nobody asked for a tool.",
        header: "X replies", multiSelect: true, options: [
            .init(label: "R1 Ana (fresh)", description: "a"), .init(label: "R2 Ben (secrets)", description: "b"),
            .init(label: "R3 Ben (tokens)", description: "c"), .init(label: "R4 Cy (mutual)", description: "d"),
        ])

    /// The 24 visible rows. The tab bar, the question and rows 1–2 are the 13
    /// lines above the top row, in the scrollback only.
    static let repliesCut = """
             @ben (90 min, 1.4k views; a tool that reads local auth files for
             telemetry): "Worth checking the other direction too: if an agent ever
             read an auth file or .env in a session, the contents sit in the
             transcript on disk and already went to the provider. Rotate anything
             that shows up there."
      3. [ ] R3 Ben (tokens)
             @ben (63 min, 1.3k views; skills now on by default, so sessions burn
             fewer tokens): "In a week of our own sessions, history resent past
             200k tokens was most of the avoidable spend. Fewer tool schemas
             riding along on every turn should cut straight into that line."
             (Pick only one of the two Ben replies if you'd rather not reply
             twice.)
      4. [ ] R4 Cy (mutual)
             @cy, a mutual (his own post on keeping candidate facts tied to their
             source): "The 'every fact shows where it came from' part is what
             people will actually trust. Provenance beats a tidy summary."
      5. [ ] Type something
         Submit
    ────────────────────────────────────────────────────────────────────────────────
      6. Chat about this
     ↑ 13 more lines
    Enter to select · ↑/↓ to navigate · Esc to cancel

    """

    /// The same picker in a pane tall enough for all of it: the question is
    /// drawn behind a `│` gutter.
    static let repliesWhole = """
    ────────────────────────────────────────────────────────────────────────────────
    ←  ☐ X replies  ✔ Submit  →

    │ Which X replies should I post now? They follow the research: early, on
    │ mid-size accounts or mutuals, each adding something concrete. No links,
    │ since nobody asked for a tool.

    ❯ 1. [ ] R1 Ana (fresh)
             @ana (18 min old, 445 views): "And for what already happened, every
             tool call is in your transcripts."
      2. [ ] R2 Ben (secrets)

    """ + repliesCut.replacingOccurrences(of: " ↑ 13 more lines\n", with: "\n")

    @Test func aPickerCutAtTheTopIsReadFromItsVisibleRows() {
        let screen = P.read(Self.repliesCut, questions: [Self.replies])
        guard case .question(0, let rows) = screen else { Issue.record("read \(screen)"); return }
        #expect(rows.map(\.number) == [3, 4, 5, nil, 6])
        #expect(rows.map(\.checked) == [false, false, false, nil, nil])
        #expect(rows[3].isSubmit)
    }

    @Test func aCutMultiSelectFallsBackInsteadOfSayingTheQuestionIsNotOpen() {
        // Rows 1 and 2 are out of view, so their boxes can't be read: the
        // driver falls back (the picker is up), it doesn't give up as absent.
        let d = decide(Self.repliesCut, [Self.replies], [.init(selected: [0, 2])])
        #expect(d == .fail("Option 1 is out of view in the terminal."))
        #expect(d != .fail("The question isn't open in the terminal."))
    }

    @Test func theWholeTallPickerReadsThroughTheQuestionGutter() {
        let screen = P.read(Self.repliesWhole, questions: [Self.replies])
        guard case .question(0, let rows) = screen else { Issue.record("read \(screen)"); return }
        #expect(rows.map(\.number) == [1, 2, 3, 4, 5, nil, 6])
        #expect(rows[0].isCursor)
        // Every box in view: it toggles row 1, then row 3.
        #expect(decide(Self.repliesWhole, [Self.replies], [.init(selected: [0, 2])])
            == .step(.init(key: .key("1"), expect: .checked(question: 0, row: 1, true))))
    }

    /// Recorded with Claude Code 2.1.331 at 80×24: question 2 of 2, after
    /// question 1 (a multi-select with `Next`). Its tab bar is out of view, and
    /// the scrollback above still holds question 1's tab bar and text.
    static let replies2 = ChatQuestion(
        question: "Which replies should I post now? They follow the research: early, on mid-size accounts or "
            + "mutuals, each adding something concrete.",
        header: "Replies", multiSelect: true, options: [
            .init(label: "R1 Alpha"), .init(label: "R2 Beta"), .init(label: "R3 Gamma"), .init(label: "R4 Delta"),
        ])
    static let tone = ChatQuestion(
        question: "Which tone should the replies use overall, given the audience and the time of day?",
        header: "Tone", multiSelect: false, options: [.init(label: "Dry"), .init(label: "Warm"), .init(label: "Punchy")])

    static let toneCut = """
    │ Which tone should the replies use overall, given the audience and the time of
    │ day?

    ❯ 1. Dry
         Measured and understated: short sentences, no exclamation marks, facts
         stated plainly. Suits a mid-morning slot when readers are working and skim
         quickly. Lets the concrete detail carry the reply, avoids sounding like
         marketing, and tends to earn trust from peers who are wary of hype.
      2. Warm
         Friendly and personal, using first names and acknowledging the other
         person's point before adding anything. Suits an evening slot when readers
         are relaxed and more likely to reply at length. Builds goodwill with
         mutuals, though it can read as soft if the reply has no concrete detail.
      3. Punchy
         Brief, confident, energetic lines with a clear takeaway up front. Suits a
         lunchtime slot when feeds are busy and attention is short. Stands out in a
         crowded thread, but works best on the strongest replies, since bold claims
         without evidence can backfire with mid-size accounts.
      4. Type something.
    ────────────────────────────────────────────────────────────────────────────────
      5. Chat about this
     ↑ 13 more lines
    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    @Test func aCutSecondQuestionIsMatchedByItsVisibleText() {
        let qs = [Self.replies2, Self.tone]
        guard case .question(1, let rows) = P.read(Self.toneCut, questions: qs) else {
            Issue.record("question 2 not matched"); return
        }
        #expect(rows.compactMap(\.number) == [1, 2, 3, 4, 5])
        #expect(P.satisfied(.left(question: 0), by: P.read(Self.toneCut, questions: qs), answers: [
            .init(selected: [0]), .init(selected: [1]),
        ]))
        #expect(decide(Self.toneCut, qs, [.init(selected: [0]), .init(selected: [1])], expected: 1, started: true)
            == .step(.init(key: .key("2"), expect: .left(question: 1))))
        // The same rows under another question's text are not this question.
        let wrongText = Self.toneCut.replacingOccurrences(of: "│ day?", with: "│ night?")
        #expect(P.read(wrongText, questions: qs) == .absent)
    }

    @Test func aMultiSelectThatIsNotLastEndsInANextRow() {
        #expect(P.parseRow("     Next") == P.Row(number: nil, isCursor: false, checked: nil, text: "Next"))
        #expect(P.parseRow("❯    Next")?.isSubmit == true)
        // A description that says only "Submit" is not the row.
        #expect(P.parseRow("         Submit") == nil)
    }

    /// Recorded at 80×24: a single-select whose rows 1–3 are out of view. A
    /// digit still picks an option that is out of view.
    static let plan = ChatQuestion(
        question: "Which plan should we take for the launch next week?", header: "Plan", multiSelect: false,
        options: [.init(label: "Alpha"), .init(label: "Beta"), .init(label: "Gamma"), .init(label: "Delta")])
    static let day = ChatQuestion(question: "Which day?", header: "Day", multiSelect: false, options: [
        .init(label: "Mon", description: "start of week"), .init(label: "Fri", description: "end of week"),
    ])
    static let planCut = """
         reversal.
      4. Delta
         Launch quietly behind a feature flag, enabling it for internal staff first
         and then for a random percentage of new sign-ups each day.
      5. Type something.
    ────────────────────────────────────────────────────────────────────────────────
      6. Chat about this
     ↑ 25 more lines
    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    @Test func aCutSingleSelectStillPicksByDigit() {
        let qs = [Self.plan, Self.day]
        guard case .question(0, _) = P.read(Self.planCut, questions: qs) else {
            Issue.record("cut single-select not matched"); return
        }
        #expect(decide(Self.planCut, qs, [.init(selected: [0]), .init(selected: [1])])
            == .step(.init(key: .key("1"), expect: .left(question: 0))))
    }

    @Test func aCutPickerOfAnotherCallOrAPermissionPromptIsAbsent() {
        // Rows that are not this call's options.
        #expect(P.read(Self.planCut, questions: Self.two) == .absent)
        // Another call's tab bar in view.
        #expect(P.read(Self.petScreen, questions: [Self.plan, Self.day]) == .absent)
        // `Esc to cancel`, numbered rows, but no `Chat about this`.
        let permission = """
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for this command
           3. No

         Esc to cancel · Tab to amend
        """
        #expect(P.read(permission, questions: [Self.color]) == .absent)
    }

    @Test func aCutPickerTwoQuestionsCouldOwnIsUnrecognized() {
        let a = ChatQuestion(question: "Ship today?", header: "Ship", multiSelect: false,
                             options: [.init(label: "Yes"), .init(label: "No")])
        let b = ChatQuestion(question: "Tag it?", header: "Tag", multiSelect: false,
                             options: [.init(label: "Yes"), .init(label: "No")])
        let screen = """
             a long description
          2. No
             another long description
          3. Type something.
        ────
          4. Chat about this
         ↑ 9 more lines
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        #expect(P.read(screen, questions: [a, b]) == .unrecognized)
        #expect(P.read("│ today?\n\n" + screen, questions: [a, b]) != .unrecognized)
    }

    @Test func aReviewStepCutAtTheTopIsNeverTakenForAClosedPicker() {
        // Recorded at 80×24 with the title in view but the tab bar not.
        let review = """

        Review your answers

         │ ● Which replies should I post now? They follow the research: early, on
         │   mid-size accounts or mutuals, each adding something concrete.
           → R1 Alpha
         │ ● Which tone should the replies use overall, given the audience and the time
         │   of day?
           → Warm

        ❯ 1. Submit answers
          2. Cancel
        """
        let qs = [Self.replies2, Self.tone]
        #expect(P.read(review, questions: qs) == .review(cursorOnSubmit: true, allAnswered: true))
        // The title out of view too: the unanswered warning could be with it.
        let titleCut = review.replacingOccurrences(of: "Review your answers\n", with: "")
        #expect(P.read(titleCut, questions: qs) == .unrecognized)
    }

    // MARK: decide

    private func decide(_ screen: String, _ qs: [ChatQuestion], _ a: [P.Answer], expected: Int = 0, started: Bool = false) -> P.Decision {
        P.decide(screen: P.read(screen, questions: qs), questions: qs, answers: a, expected: expected, started: started)
    }

    @Test func singleSelectPicksByDigit() {
        let d = decide(Self.colorScreen, Self.two, [.init(selected: [1]), .init(selected: [0])])
        #expect(d == .step(.init(key: .key("2"), expect: .left(question: 0))))
    }

    @Test func singleSelectOtherFocusesTheTextRowFirst() {
        let d = decide(Self.colorScreen, Self.two, [.init(other: "Teal"), .init(selected: [0])])
        #expect(d == .step(.init(key: .key("4"), expect: .cursor(question: 0, row: 4))))
        let focused = Self.colorScreen
            .replacingOccurrences(of: "❯ 1. Red", with: "  1. Red")
            .replacingOccurrences(of: "  4. Type something.", with: "❯ 4. Type something.")
        #expect(decide(focused, Self.two, [.init(other: "Teal"), .init(selected: [0])], started: true)
            == .step(.init(key: .literal("Teal"), expect: .otherTyped(question: 0))))
        let typed = focused.replacingOccurrences(of: "❯ 4. Type something.", with: "❯ 4. Teal")
        #expect(decide(typed, Self.two, [.init(other: "Teal"), .init(selected: [0])], started: true)
            == .step(.init(key: .key("Enter"), expect: .left(question: 0))))
    }

    @Test func multiSelectTogglesOnlyWhatDiffers() {
        // Screen: Cheese and Basil ticked. Want Olives only.
        let a: [P.Answer] = [.init(selected: [0]), .init(selected: [1])]
        #expect(decide(Self.toppingsScreen, Self.two, a, expected: 1, started: true)
            == .step(.init(key: .key("1"), expect: .checked(question: 1, row: 1, false))))
        // Want exactly what is ticked: walk down to Submit.
        let same: [P.Answer] = [.init(selected: [0]), .init(selected: [0, 2])]
        #expect(decide(Self.toppingsScreen, Self.two, same, expected: 1, started: true)
            == .step(.init(key: .key("Down"), expect: .cursor(question: 1, row: 2))))
    }

    @Test func multiSelectEntersFromTheSubmitRow() {
        let onSubmit = Self.toppingsScreen
            .replacingOccurrences(of: "❯ 1. [✔] Cheese", with: "  1. [✔] Cheese")
            .replacingOccurrences(of: "     Submit", with: "❯    Submit")
        let a: [P.Answer] = [.init(selected: [0]), .init(selected: [0, 2])]
        #expect(decide(onSubmit, Self.two, a, expected: 1, started: true)
            == .step(.init(key: .key("Enter"), expect: .left(question: 1))))
    }

    @Test func multiSelectOtherWalksToTheTextRowAndTypes() {
        let a: [P.Answer] = [.init(selected: [0]), .init(selected: [0, 2], other: "Ham")]
        #expect(decide(Self.toppingsScreen, Self.two, a, expected: 1, started: true)
            == .step(.init(key: .key("Down"), expect: .cursor(question: 1, row: 2))))
        let atOther = Self.toppingsScreen
            .replacingOccurrences(of: "❯ 1. [✔] Cheese", with: "  1. [✔] Cheese")
            .replacingOccurrences(of: "  4. [ ] Type something", with: "❯ 4. [ ] Type something")
        #expect(decide(atOther, Self.two, a, expected: 1, started: true)
            == .step(.init(key: .literal("Ham"), expect: .otherTyped(question: 1))))
        // Typing ticks the row by itself; then on to Submit.
        let typed = atOther.replacingOccurrences(of: "❯ 4. [ ] Type something", with: "❯ 4. [✔] Ham")
        #expect(decide(typed, Self.two, a, expected: 1, started: true)
            == .step(.init(key: .key("Down"), expect: .cursor(question: 1, row: nil))))
    }

    @Test func reviewSubmitsOnlyWhenEveryQuestionIsDone() {
        let a: [P.Answer] = [.init(selected: [1]), .init(selected: [0, 2])]
        #expect(decide(Self.reviewScreen, Self.two, a, expected: 2, started: true)
            == .step(.init(key: .key("Enter"), expect: .closed)))
        guard case .fail = decide(Self.reviewScreen, Self.two, a, expected: 1, started: true) else {
            Issue.record("early review accepted"); return
        }
    }

    @Test func aPickerThatIsNotUpFailsBeforeAnyKey() {
        let d = decide(Self.idleScreen, Self.two, [.init(selected: [1]), .init(selected: [0])])
        #expect(d == .fail("The question isn't open in the terminal."))
        #expect(decide(Self.idleScreen, Self.two, [.init(selected: [1]), .init(selected: [0])], expected: 2, started: true) == .done)
    }

    @Test func aPickerOnTheWrongQuestionFails() {
        let d = decide(Self.toppingsScreen, Self.two, [.init(selected: [1]), .init(selected: [0])], expected: 0)
        guard case .fail = d else { Issue.record("expected a failure"); return }
    }

    // MARK: satisfied

    @Test func expectationsReadTheNextScreen() {
        let a: [P.Answer] = [.init(selected: [1]), .init(selected: [0])]
        let color = P.read(Self.colorScreen, questions: Self.two)
        let toppings = P.read(Self.toppingsScreen, questions: Self.two)
        #expect(P.satisfied(.left(question: 0), by: toppings, answers: a))
        #expect(!P.satisfied(.left(question: 0), by: color, answers: a))
        #expect(P.satisfied(.left(question: 1), by: .absent, answers: a))
        #expect(P.satisfied(.checked(question: 1, row: 3, true), by: toppings, answers: a))
        #expect(!P.satisfied(.checked(question: 1, row: 2, true), by: toppings, answers: a))
        #expect(P.satisfied(.cursor(question: 1, row: 1), by: toppings, answers: a))
        #expect(P.satisfied(.closed, by: .absent, answers: a))
        #expect(!P.satisfied(.closed, by: .unrecognized, answers: a))
    }

    @Test func aLongTypedAnswerMatchesByItsVisibleStart() {
        #expect(P.typedMatches("Water, sparkl", "Water, sparkling"))
        #expect(P.typedMatches("Water, sparkling", "Water, sparkling"))
        #expect(!P.typedMatches("Juice", "Water"))
    }

    // MARK: answers

    @Test func validateChecksEachQuestionsShape() {
        #expect(P.validate([.init(selected: [1]), .init(selected: [0, 2])], for: Self.two) == nil)
        #expect(P.validate([.init(other: "Teal"), .init(other: "Ham")], for: Self.two) == nil)
        #expect(P.validate([.init(selected: [1])], for: Self.two) != nil)                       // count
        #expect(P.validate([.init(selected: [0, 1]), .init(selected: [0])], for: Self.two) != nil) // two picks
        #expect(P.validate([.init(selected: [1], other: "x"), .init(selected: [0])], for: Self.two) != nil)
        #expect(P.validate([.init(selected: [9]), .init(selected: [0])], for: Self.two) != nil)  // range
        #expect(P.validate([.init(selected: [1]), .init(other: "  ")], for: Self.two) != nil)   // blank
    }

    @Test func otherTextCannotPressEnter() {
        #expect(P.cleanedOther("a\nb\tc") == "a b c")
        #expect(P.cleanedOther(" \n ") == nil)
        #expect(P.cleanedOther(String(repeating: "x", count: 5_000))?.count == P.maxOtherChars)
    }

    @Test func fallbackMessageIsHeaderAnswerLines() {
        let msg = P.fallbackMessage([.init(other: "Teal"), .init(selected: [2, 0], other: "Ham")], for: Self.two)
        #expect(msg == "Color: Teal\nToppings: Cheese, Basil, Ham")
    }
}
