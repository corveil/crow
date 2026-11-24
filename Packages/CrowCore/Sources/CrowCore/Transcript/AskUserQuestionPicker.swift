import Foundation

/// Answers a Claude Code `AskUserQuestion` picker from its screen (CROW-1512).
///
/// The web Chat view's question card hands the operator's answers to the
/// daemon, which has to type them into the TUI picker that is actually waiting
/// (the picker is the source of truth; nothing else can answer the tool). This
/// type is the pure half: it reads a `capture-pane` of the agent's pane into a
/// ``Screen``, and decides the *one* next key from what is on screen, with the
/// screen state that key must produce (``Step/expect``). The driver
/// (`AskUserQuestionDriver`, CrowEngine) presses it, re-captures, checks the
/// expectation, and repeats. Anything it doesn't recognise is a ``Decision/fail``,
/// and the driver falls back to dismissing the picker and sending the answers
/// as a plain message.
///
/// The key map, recorded against Claude Code 2.1.331 with `tmux capture-pane`
/// before and after every key (2026-11-23):
///
/// - The picker draws a tab bar (`←  ☐ Color  ☐ Toppings  ✔ Submit  →`; a lone
///   single-select question draws just ` ☐ Pet`), the question text, numbered
///   option rows with their descriptions indented under them, a
///   `Type something.` row, then `Chat about this` and the footer
///   `Enter to select · Tab/Arrow keys to navigate · Esc to cancel`.
/// - Single-select: the option's digit picks it and moves to the next question.
///   The `Type something.` row's digit puts the cursor in its text field; typed
///   text replaces the placeholder and Enter commits it and moves on.
/// - Multi-select (`[ ]` / `[✔]` rows): a digit toggles that row and leaves the
///   cursor where it is. Typing in the `Type something` row ticks it; its digit
///   only toggles it, without focusing the field. Below it sits a `Submit` row:
///   Down to it, then Enter, moves on.
/// - With more than one question, or any multi-select one, the last step lands
///   on `Review your answers` with the cursor on `1. Submit answers`; Enter
///   submits. A lone single-select question submits on its pick.
/// - Esc dismisses the picker (the tool result is the "doesn't want to
///   proceed" rejection).
public enum AskUserQuestionPicker {
    /// The operator's answer to one question: indices into its options, and
    /// the free text typed in its `Type something` row.
    public struct Answer: Sendable, Equatable {
        public var selected: [Int]
        public var other: String?

        public init(selected: [Int] = [], other: String? = nil) {
            self.selected = selected
            self.other = other
        }
    }

    /// One numbered or `Submit` row of a question screen.
    public struct Row: Sendable, Equatable {
        /// 1-based, as drawn. Nil for the multi-select `Submit` row.
        public var number: Int?
        public var isCursor: Bool
        /// Multi-select checkbox state; single-select draws a trailing ` ✔`
        /// on the picked row. Nil when the row shows neither.
        public var checked: Bool?
        public var text: String

        public init(number: Int?, isCursor: Bool, checked: Bool?, text: String) {
            self.number = number
            self.isCursor = isCursor
            self.checked = checked
            self.text = text
        }

        public var isSubmit: Bool { number == nil }
    }

    public enum Screen: Sendable, Equatable {
        /// The picker shows question `index` of the call.
        case question(index: Int, rows: [Row])
        /// The `Review your answers` step.
        case review(cursorOnSubmit: Bool, allAnswered: Bool)
        /// A picker for this call is up, but in a shape this reader doesn't know.
        case unrecognized
        /// No picker for this call on screen.
        case absent
    }

    public enum Key: Sendable, Equatable {
        /// A tmux key name (`Enter`, `Down`) or a single digit.
        case key(String)
        /// Text typed literally (`send-keys -l`), never parsed as key names.
        case literal(String)
    }

    /// What the screen must show after a key, for the driver to go on.
    public enum Expectation: Sendable, Equatable {
        /// Question `question` is still up with the cursor on `row` (nil: the
        /// `Submit` row).
        case cursor(question: Int, row: Int?)
        /// Question `question`'s row `row` shows `checked`.
        case checked(question: Int, row: Int, Bool)
        /// Question `question`'s `Type something` row holds the answer's text.
        case otherTyped(question: Int)
        /// The picker moved past question `question` (the next one, the
        /// review step, or closed).
        case left(question: Int)
        /// The picker is gone.
        case closed
    }

    public struct Step: Sendable, Equatable {
        public var key: Key
        public var expect: Expectation
    }

    public enum Decision: Sendable, Equatable {
        case step(Step)
        /// Every answer is in and the picker closed.
        case done
        case fail(String)
    }

    /// The pointer glyph Claude Code draws on the cursor row.
    static let cursorGlyph: Character = "❯"

    // MARK: - Reading the screen

    /// Read a plain-text capture of the pane's visible rows.
    public static func read(_ capture: String, questions: [ChatQuestion]) -> Screen {
        let lines = capture.components(separatedBy: "\n")
        guard let bar = lines.lastIndex(where: { isTabBar($0, questions: questions) }) else { return .absent }
        let region = Array(lines[(bar + 1)...])
        if region.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Review your answers" }) {
            let submit = region.first { squash($0).hasSuffix("1.Submitanswers") }
            guard let submit else { return .unrecognized }
            let warned = region.contains { $0.contains("Some questions are unanswered") }
            return .review(cursorOnSubmit: submit.contains(cursorGlyph), allAnswered: !warned)
        }
        guard region.contains(where: { $0.contains("Esc to cancel") }) else { return .unrecognized }
        // The question text runs from the tab bar to the first numbered row,
        // wrapped to the pane width; compare with all whitespace removed.
        guard let firstRow = region.firstIndex(where: { parseRow($0) != nil && parseRow($0)?.number != nil })
        else { return .unrecognized }
        let asked = squash(region[..<firstRow].joined(separator: " "))
        guard let index = questions.firstIndex(where: { squash($0.question) == asked }) else { return .unrecognized }
        let rows = region[firstRow...].compactMap(parseRow)
        return .question(index: index, rows: rows)
    }

    /// The tab bar names the questions' headers behind a `☐` / `☒` box.
    static func isTabBar(_ line: String, questions: [ChatQuestion]) -> Bool {
        guard line.contains("☐ ") || line.contains("☒ ") else { return false }
        return questions.contains { q in
            let h = q.header.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return false }
            // A long header can be cut short in the bar; its start is enough.
            let head = String(h.prefix(8))
            return line.contains("☐ " + head) || line.contains("☒ " + head)
        }
    }

    static func parseRow(_ line: String) -> Row? {
        var s = Substring(line)
        let indent = s.prefix(while: { $0 == " " }).count
        s = s.dropFirst(indent)
        var isCursor = false
        if s.first == cursorGlyph {
            isCursor = true
            s = s.dropFirst().drop(while: { $0 == " " })
        }
        if s.trimmingCharacters(in: .whitespaces) == "Submit" {
            return Row(number: nil, isCursor: isCursor, checked: nil, text: "Submit")
        }
        // Rows start at column 0 (`❯ 1.`) or 2 (`  1.`); descriptions are
        // indented 5 or more, so one that starts with `3. ` is not a row.
        guard isCursor || indent <= 3 else { return nil }
        let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        var rest = s.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " || rest.isEmpty else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        var checked: Bool?
        if text.hasPrefix("[✔]") {
            checked = true
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("[ ]") {
            checked = false
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if text.hasSuffix(" ✔") {
            checked = true
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return Row(number: number, isCursor: isCursor, checked: checked, text: text)
    }

    /// The text with every whitespace character removed: wrapping-proof.
    static func squash<S: StringProtocol>(_ s: S) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The `Type something` row's placeholder (single-select draws a period).
    static func isPlaceholder(_ text: String) -> Bool {
        text == "Type something" || text == "Type something."
    }

    // MARK: - Deciding the next key

    /// Whether the call ends on the `Review your answers` step.
    public static func endsInReview(_ questions: [ChatQuestion]) -> Bool {
        questions.count > 1 || questions.contains(where: \.multiSelect)
    }

    /// The next key for `screen`, given that questions before `expected` are
    /// answered. `started` says whether a key was already pressed (a picker
    /// that is gone before any key is "not on screen", not "done").
    public static func decide(
        screen: Screen, questions: [ChatQuestion], answers: [Answer], expected: Int, started: Bool
    ) -> Decision {
        switch screen {
        case .absent:
            if !started { return .fail("The question isn't open in the terminal.") }
            return expected >= questions.count ? .done : .fail("The picker closed before every answer was in.")
        case .unrecognized:
            return .fail("The picker on screen isn't in a shape Crow knows.")
        case .review(let onSubmit, let allAnswered):
            guard expected >= questions.count else {
                return .fail(started ? "The picker skipped to review early." : "The picker is already on its review step.")
            }
            guard allAnswered else { return .fail("The picker says some questions are unanswered.") }
            guard onSubmit else { return .fail("The review step's cursor isn't on Submit answers.") }
            return .step(Step(key: .key("Enter"), expect: .closed))
        case .question(let index, let rows):
            guard index == expected, index < answers.count else {
                return .fail("The picker shows question \(index + 1), expected \(expected + 1).")
            }
            let q = questions[index]
            let a = answers[index]
            return q.multiSelect
                ? decideMulti(q, a, index: index, rows: rows)
                : decideSingle(q, a, index: index, rows: rows)
        }
    }

    private static func decideSingle(_ q: ChatQuestion, _ a: Answer, index: Int, rows: [Row]) -> Decision {
        let n = q.options.count
        if let other = cleanedOther(a.other) {
            guard let row = rows.first(where: { $0.number == n + 1 }) else {
                return .fail("The picker has no Type something row.")
            }
            if !row.isCursor {
                return .step(Step(key: .key(String(n + 1)), expect: .cursor(question: index, row: n + 1)))
            }
            if isPlaceholder(row.text) || row.text.isEmpty {
                return .step(Step(key: .literal(other), expect: .otherTyped(question: index)))
            }
            guard typedMatches(row.text, other) else { return .fail("The Type something row holds other text.") }
            return .step(Step(key: .key("Enter"), expect: .left(question: index)))
        }
        guard let pick = a.selected.first, a.selected.count == 1, pick >= 0, pick < n else {
            return .fail("A single-select question needs exactly one answer.")
        }
        guard n + 1 <= 9 else { return .fail("Too many options to pick by number.") }
        return .step(Step(key: .key(String(pick + 1)), expect: .left(question: index)))
    }

    private static func decideMulti(_ q: ChatQuestion, _ a: Answer, index: Int, rows: [Row]) -> Decision {
        let n = q.options.count
        guard n + 1 <= 9 else { return .fail("Too many options to toggle by number.") }
        let want = Set(a.selected)
        // 1. Make every option row match, one toggle at a time.
        for i in 0..<n {
            guard let row = rows.first(where: { $0.number == i + 1 }), let checked = row.checked else {
                return .fail("Option \(i + 1) has no checkbox on screen.")
            }
            if checked != want.contains(i) {
                return .step(Step(key: .key(String(i + 1)), expect: .checked(question: index, row: i + 1, !checked)))
            }
        }
        // 2. The Type something row.
        guard let otherRow = rows.first(where: { $0.number == n + 1 }), let otherChecked = otherRow.checked else {
            return .fail("The picker has no Type something row.")
        }
        guard let cursor = rows.firstIndex(where: \.isCursor) else { return .fail("No cursor on screen.") }
        let other = cleanedOther(a.other)
        if let other {
            let typed = !isPlaceholder(otherRow.text) && !otherRow.text.isEmpty
            if !typed {
                guard let cursorNumber = rows[cursor].number else {
                    return .step(Step(key: .key("Up"), expect: .cursor(question: index, row: n + 1)))
                }
                if cursorNumber != n + 1 {
                    let key = cursorNumber < n + 1 ? "Down" : "Up"
                    let next = cursorNumber < n + 1 ? cursorNumber + 1 : cursorNumber - 1
                    return .step(Step(key: .key(key), expect: .cursor(question: index, row: next)))
                }
                return .step(Step(key: .literal(other), expect: .otherTyped(question: index)))
            }
            guard typedMatches(otherRow.text, other) else { return .fail("The Type something row holds other text.") }
            guard otherChecked else {
                return .step(Step(key: .key(String(n + 1)), expect: .checked(question: index, row: n + 1, true)))
            }
        } else if otherChecked {
            return .step(Step(key: .key(String(n + 1)), expect: .checked(question: index, row: n + 1, false)))
        }
        guard want.count + (other == nil ? 0 : 1) > 0 else {
            return .fail("A multi-select question needs at least one answer.")
        }
        // 3. Down to the Submit row, then Enter.
        if rows[cursor].isSubmit {
            return .step(Step(key: .key("Enter"), expect: .left(question: index)))
        }
        guard let submitAt = rows.firstIndex(where: \.isSubmit) else { return .fail("The picker has no Submit row.") }
        guard cursor < submitAt else { return .fail("The cursor is below the Submit row.") }
        let next = rows[cursor + 1].number
        return .step(Step(key: .key("Down"), expect: .cursor(question: index, row: next)))
    }

    /// Whether `screen` shows what `expect` asked for.
    public static func satisfied(_ expect: Expectation, by screen: Screen, answers: [Answer]) -> Bool {
        switch expect {
        case .closed:
            return screen == .absent
        case .left(let q):
            switch screen {
            case .question(let i, _): return i > q
            case .review, .absent: return true
            case .unrecognized: return false
            }
        case .cursor(let q, let row):
            guard case .question(let i, let rows) = screen, i == q else { return false }
            return rows.first(where: \.isCursor)?.number == row
        case .checked(let q, let row, let value):
            guard case .question(let i, let rows) = screen, i == q else { return false }
            return rows.first(where: { $0.number == row })?.checked == value
        case .otherTyped(let q):
            guard case .question(let i, let rows) = screen, i == q, q < answers.count,
                  let other = cleanedOther(answers[q].other) else { return false }
            // The row is the one right after the options: the last numbered row
            // before `Chat about this`, i.e. the cursor row after typing.
            guard let row = rows.first(where: \.isCursor), !isPlaceholder(row.text) else { return false }
            return typedMatches(row.text, other)
        }
    }

    /// A long answer wraps or is cut off in its row: what is shown must be a
    /// non-empty start of it.
    static func typedMatches(_ shown: String, _ typed: String) -> Bool {
        let s = squash(shown), t = squash(typed)
        guard !s.isEmpty else { return t.isEmpty }
        return t.hasPrefix(s) || t.hasPrefix(String(s.dropLast()))
    }

    // MARK: - Answers

    /// Cap for one free-text answer.
    public static let maxOtherChars = 2_000

    /// Free text as it can be typed into the single-line field: control
    /// characters (a newline would press Enter) become spaces. Nil when blank.
    public static func cleanedOther(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let mapped = String(raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        let trimmed = mapped.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return String(trimmed.prefix(maxOtherChars))
    }

    /// Why `answers` can't answer `questions`, or nil when they can.
    public static func validate(_ answers: [Answer], for questions: [ChatQuestion]) -> String? {
        guard answers.count == questions.count else { return "Expected \(questions.count) answers, got \(answers.count)." }
        for (i, (q, a)) in zip(questions, answers).enumerated() {
            let n = "Question \(i + 1)"
            if a.selected.contains(where: { $0 < 0 || $0 >= q.options.count }) { return "\(n): no such option." }
            if Set(a.selected).count != a.selected.count { return "\(n): an option is listed twice." }
            let other = cleanedOther(a.other)
            if q.multiSelect {
                if a.selected.isEmpty && other == nil { return "\(n) has no answer." }
            } else if (a.selected.count == 1) == (other != nil) || a.selected.count > 1 {
                return "\(n) needs exactly one answer."
            }
        }
        return nil
    }

    /// The answers as `Header: answer` lines, for the fallback message.
    public static func fallbackMessage(_ answers: [Answer], for questions: [ChatQuestion]) -> String {
        zip(questions, answers).map { q, a in
            let label = q.header.trimmingCharacters(in: .whitespaces).isEmpty ? q.question : q.header
            var parts = a.selected.sorted().compactMap { $0 < q.options.count ? q.options[$0].label : nil }
            if let other = cleanedOther(a.other) { parts.append(other) }
            return "\(label): \(parts.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}
