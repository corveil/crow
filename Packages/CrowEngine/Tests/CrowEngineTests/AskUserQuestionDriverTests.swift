import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// `AskUserQuestionDriver` against a simulated picker that follows the key
/// map recorded from Claude Code 2.1.331 (see `AskUserQuestionPicker`) and
/// draws its screens in the same shape. No tmux, no clock: sleeps advance a
/// fake time.
@Suite("AskUserQuestion driver")
@MainActor
struct AskUserQuestionDriverTests {
    typealias Answer = AskUserQuestionPicker.Answer

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

    /// The picker, as observed.
    final class FakePicker: @unchecked Sendable {
        struct Q { var picked: Int?; var checked: Set<Int> = []; var other = ""; var otherOn = false; var cursor = 1 }
        let questions: [ChatQuestion]
        var tab = 0
        var state: [Q]
        var reviewing = false
        var closed = false
        var declined = false
        var answers: [String: String]?
        var keys: [String] = []
        var pasted: [String] = []
        var now = Date(timeIntervalSince1970: 0)
        /// Ignore this key once (a key that doesn't land).
        var dropKey: String?
        /// Above the picker, as in the pane.
        var above = "❯ please ask me\n────"

        init(_ questions: [ChatQuestion], open: Bool = true) {
            self.questions = questions
            self.state = questions.map { _ in Q() }
            self.closed = !open
        }

        var io: AskUserQuestionDriver.IO {
            AskUserQuestionDriver.IO(
                capture: { [self] _ in render() },
                pressKey: { [self] _, k in keys.append(k); press(k) },
                typeText: { [self] _, t in keys.append("type:\(t)"); type(t) },
                paste: { [self] _, t in pasted.append(t) },
                sleep: { _ in },
                now: { [self] in now = now.addingTimeInterval(0.2); return now })
        }

        private var n: Int { questions[tab].options.count }

        func press(_ k: String) {
            if dropKey == k { dropKey = nil; return }
            guard !closed else { return }
            if k == "Escape" { closed = true; declined = true; return }
            if reviewing {
                if k == "Enter" { submit() }
                return
            }
            let q = questions[tab]
            if let d = Int(k), d >= 1, d <= n + 1 {
                if q.multiSelect {
                    if d <= n { state[tab].checked.formSymmetricDifference([d - 1]) } else { state[tab].otherOn.toggle() }
                } else if d <= n {
                    state[tab].picked = d - 1; state[tab].other = ""; advance()
                } else {
                    state[tab].cursor = n + 1
                }
                return
            }
            let last = q.multiSelect ? n + 2 : n + 1 // multi: n+2 is Submit
            switch k {
            case "Down": state[tab].cursor = min(last, state[tab].cursor + 1)
            case "Up": state[tab].cursor = max(1, state[tab].cursor - 1)
            case "Enter":
                let c = state[tab].cursor
                if q.multiSelect {
                    if c == n + 2 { advance() } else if c <= n { state[tab].checked.formSymmetricDifference([c - 1]) }
                } else if c <= n {
                    state[tab].picked = c - 1; advance()
                } else if !state[tab].other.isEmpty {
                    state[tab].picked = nil; advance()
                }
            default: break
            }
        }

        func type(_ t: String) {
            guard !closed, !reviewing, state[tab].cursor == n + 1 else { return }
            state[tab].other += t
            if questions[tab].multiSelect { state[tab].otherOn = true }
        }

        private func advance() {
            if tab + 1 < questions.count { tab += 1; return }
            if AskUserQuestionPicker.endsInReview(questions) { reviewing = true } else { submit() }
        }

        private func answer(_ i: Int) -> String {
            let q = questions[i], s = state[i]
            if q.multiSelect {
                var parts = s.checked.sorted().map { q.options[$0].label }
                if s.otherOn, !s.other.isEmpty { parts.append(s.other) }
                return parts.joined(separator: ", ")
            }
            return s.picked.map { q.options[$0].label } ?? s.other
        }

        private func submit() {
            closed = true
            answers = Dictionary(uniqueKeysWithValues: questions.indices.map { (questions[$0].question, answer($0)) })
        }

        func render() -> String {
            if closed { return above + "\n⏺ done\n❯ \n" }
            var out = [above, ""]
            let lone = questions.count == 1 && !questions[0].multiSelect
            let boxes = questions.indices.map { i in
                (i < tab || reviewing ? "☒ " : "☐ ") + questions[i].header
            }.joined(separator: "  ")
            out.append(lone ? " " + boxes : "←  " + boxes + "  ✔ Submit  →")
            out.append("")
            if reviewing {
                out += ["Review your answers", ""]
                for i in questions.indices { out += [" ● " + questions[i].question, "   → " + answer(i)] }
                out += ["", "❯ 1. Submit answers", "  2. Cancel"]
                return out.joined(separator: "\n")
            }
            let q = questions[tab], s = state[tab]
            out += [q.question, ""]
            for (i, o) in q.options.enumerated() {
                let cur = s.cursor == i + 1 ? "❯ " : "  "
                if q.multiSelect {
                    out.append("\(cur)\(i + 1). [\(s.checked.contains(i) ? "✔" : " ")] \(o.label)")
                    out.append("         \(o.description)")
                } else {
                    out.append("\(cur)\(i + 1). \(o.label)\(s.picked == i ? " ✔" : "")")
                    out.append("     \(o.description)")
                }
            }
            let cur = s.cursor == n + 1 ? "❯ " : "  "
            if q.multiSelect {
                out.append("\(cur)\(n + 1). [\(s.otherOn ? "✔" : " ")] \(s.other.isEmpty ? "Type something" : s.other)")
                out.append((s.cursor == n + 2 ? "❯    " : "     ") + "Submit")
            } else {
                out.append("\(cur)\(n + 1). \(s.other.isEmpty ? "Type something." : s.other)")
            }
            out += ["────", "  \(n + 2). Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
            return out.joined(separator: "\n")
        }
    }

    private func run(_ p: FakePicker, _ answers: [Answer]) async throws -> AskUserQuestionDriver.Outcome {
        try await AskUserQuestionDriver.answer(terminalID: UUID(), questions: p.questions, answers: answers, io: p.io)
    }

    @Test("single-select and multi-select across two questions, through review")
    func twoQuestions() async throws {
        let p = FakePicker([Self.color, Self.toppings])
        let out = try await run(p, [Answer(selected: [1]), Answer(selected: [0, 2])])
        #expect(out == .picker)
        #expect(p.answers == ["Which color?": "Blue", "Which toppings?": "Cheese, Basil"])
        #expect(p.keys == ["2", "1", "3", "Down", "Down", "Down", "Down", "Enter", "Enter"])
        #expect(p.pasted.isEmpty)
    }

    @Test("Other text in a single-select and a multi-select question")
    func otherText() async throws {
        let p = FakePicker([Self.color, Self.toppings])
        let out = try await run(p, [Answer(other: "Teal"), Answer(selected: [0], other: "Enter C-c")])
        #expect(out == .picker)
        #expect(p.answers == ["Which color?": "Teal", "Which toppings?": "Cheese, Enter C-c"])
        // Typed literally, never as key names.
        #expect(p.keys.contains("type:Teal"))
        #expect(p.keys.contains("type:Enter C-c"))
    }

    @Test("a lone single-select question submits on its digit")
    func loneQuestion() async throws {
        let p = FakePicker([Self.pet])
        #expect(try await run(p, [Answer(selected: [1])]) == .picker)
        #expect(p.answers == ["Which pet?": "Dog"])
        #expect(p.keys == ["2"])
    }

    @Test("a picker already partly ticked in the terminal is corrected, not toggled blindly")
    func partlyTicked() async throws {
        let p = FakePicker([Self.toppings])
        p.state[0].checked = [1]
        #expect(try await run(p, [Answer(selected: [0])]) == .picker)
        #expect(p.answers == ["Which toppings?": "Cheese"])
    }

    @Test("no picker on screen: nothing is pressed and the call fails")
    func notOnScreen() async throws {
        let p = FakePicker([Self.pet], open: false)
        await #expect(throws: AskUserQuestionDriver.Failure.self) {
            try await run(p, [Answer(selected: [0])])
        }
        #expect(p.keys.isEmpty)
        #expect(p.pasted.isEmpty)
    }

    @Test("a key that doesn't land: Esc, then the answers as a message")
    func fallback() async throws {
        let p = FakePicker([Self.color, Self.toppings])
        p.dropKey = "3" // the Basil toggle never shows
        let out = try await run(p, [Answer(selected: [1]), Answer(selected: [0, 2], other: "Ham")])
        guard case .fallback = out else { Issue.record("expected the fallback, got \(out)"); return }
        #expect(p.declined)
        #expect(p.keys.last == "Escape")
        #expect(p.pasted == ["Color: Blue\nToppings: Cheese, Basil, Ham\n"])
    }

    @Test("a picker that won't close: the call fails and nothing is pasted")
    func cannotDismiss() async throws {
        let p = FakePicker([Self.color, Self.toppings])
        p.dropKey = "1"
        // Swallows every Esc too.
        let io = p.io
        var stubborn = io
        stubborn.pressKey = { id, k in if k != "Escape" { try io.pressKey(id, k) } }
        await #expect(throws: AskUserQuestionDriver.Failure.self) {
            try await AskUserQuestionDriver.answer(
                terminalID: UUID(), questions: p.questions,
                answers: [Answer(selected: [1]), Answer(selected: [0])], io: stubborn)
        }
        #expect(p.pasted.isEmpty)
    }

    @Test("an unreadable pane is never taken for a closed picker")
    func unreadablePane() async throws {
        let p = FakePicker([Self.color, Self.toppings])
        var io = p.io
        io.capture = { _ in nil }
        await #expect(throws: AskUserQuestionDriver.Failure.self) {
            try await AskUserQuestionDriver.answer(
                terminalID: UUID(), questions: p.questions,
                answers: [Answer(selected: [1]), Answer(selected: [0])], io: io)
        }
        #expect(p.keys.isEmpty)
        #expect(p.pasted.isEmpty)
    }
}
