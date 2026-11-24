import Foundation
import Testing
@testable import CrowCore

/// Claude `AskUserQuestion` in the Chat transcript (CROW-1512). The lines are
/// hand-written to the shapes Claude Code 2.1.331 persisted for a probe session
/// (2026-11-23): the call's `input.questions`, the answered result's text plus
/// its structured `toolUseResult.answers`, and the declined result
/// (`is_error`, `toolUseResult` a bare string). Never read from a live
/// `~/.claude` (ADR 0012).
@Suite struct ChatTranscriptQuestionTests {
    private func parse(_ s: String) -> [ChatEvent] {
        ChatTranscript.parse(Data(s.utf8), format: .claude)
    }

    static let singleSelectCall = #"""
    {"type":"assistant","isSidechain":false,"timestamp":"T1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which pet?","header":"Pet","multiSelect":false,"options":[{"label":"Cat","description":"meow"},{"label":"Dog","description":"woof"}]}]}}],"stop_reason":"tool_use"}}
    """#

    @Test func singleSelectCallCarriesItsQuestion() {
        let events = parse(Self.singleSelectCall)
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.kind == .toolCall)
        #expect(e.toolName == "AskUserQuestion")
        #expect(e.toolID == "toolu_q1")
        // A readable summary, not the input JSON.
        #expect(e.text == "Which pet?")
        #expect(e.questions == [
            ChatQuestion(question: "Which pet?", header: "Pet", multiSelect: false, options: [
                .init(label: "Cat", description: "meow"), .init(label: "Dog", description: "woof"),
            ]),
        ])
    }

    @Test func multiSelectAndSeveralQuestions() {
        let line = #"""
        {"type":"assistant","isSidechain":false,"timestamp":"T1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q2","name":"AskUserQuestion","input":{"questions":[{"question":"Which color?","header":"Color","multiSelect":false,"options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"},{"label":"Green","description":"natural"}]},{"question":"Which toppings?","header":"Toppings","multiSelect":true,"options":[{"label":"Cheese","description":"dairy"},{"label":"Olives","description":"salty"},{"label":"Basil","description":"fresh"}]}]},"caller":{"type":"direct"}}],"stop_reason":"tool_use"}}
        """#
        let e = parse(line)[0]
        #expect(e.text == "Which color? (+1 more)")
        let qs = e.questions ?? []
        #expect(qs.count == 2)
        #expect(qs[0].multiSelect == false)
        #expect(qs[1].multiSelect == true)
        #expect(qs[1].header == "Toppings")
        #expect(qs[1].options.map(\.label) == ["Cheese", "Olives", "Basil"])
        #expect(qs[1].options.map(\.description) == ["dairy", "salty", "fresh"])
    }

    @Test func answeredResultCarriesTheStructuredAnswers() {
        let line = #"""
        {"type":"user","isSidechain":false,"timestamp":"T2","message":{"role":"user","content":[{"type":"tool_result","content":"The user answered: \"Which color?\"=\"Teal\", \"Which toppings?\"=\"Cheese, Basil, Ham\". Read the answers carefully — they may request clarification, changes, or that you not proceed — and follow what they actually say.","tool_use_id":"toolu_q2"}]},"toolUseResult":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiSelect":false},{"question":"Which toppings?","header":"Toppings","options":[{"label":"Cheese","description":"dairy"},{"label":"Basil","description":"fresh"}],"multiSelect":true}],"answers":{"Which color?":"Teal","Which toppings?":"Cheese, Basil, Ham"},"annotations":{}}}
        """#
        let e = parse(line)[0]
        #expect(e.kind == .toolResult)
        #expect(e.toolID == "toolu_q2")
        #expect(!e.isError)
        #expect(e.answers == ["Which color?": "Teal", "Which toppings?": "Cheese, Basil, Ham"])
        // Echoed, so a result whose call fell before the tail window can still render.
        #expect(e.questions?.map(\.header) == ["Color", "Toppings"])
        #expect(e.text.hasPrefix("The user answered:"))
    }

    @Test func declinedResultHasNoAnswers() {
        let line = #"""
        {"type":"user","isSidechain":false,"timestamp":"T2","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.","is_error":true,"tool_use_id":"toolu_q1"}]},"toolUseResult":"User rejected tool use"}
        """#
        let e = parse(line)[0]
        #expect(e.kind == .toolResult)
        #expect(e.isError)
        #expect(e.answers == nil)
        #expect(e.questions == nil)
        #expect(e.text.hasPrefix("The user doesn't want to proceed"))
    }

    @Test func otherToolsKeepTheirSummaryAndCarryNoQuestions() {
        let line = #"""
        {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls","questions":[{"question":"q","options":[{"label":"x"}]}]}}]}}
        {"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"ok","tool_use_id":"t"}]},"toolUseResult":{"stdout":"ok","stderr":""}}
        """#
        let events = parse(line)
        #expect(events[0].text == "ls")
        #expect(events[0].questions == nil)
        #expect(events[1].answers == nil)
    }

    @Test func malformedQuestionsFallBackToTheJSONSummary() {
        // No options: nothing to draw a card from.
        let line = #"""
        {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"AskUserQuestion","input":{"questions":[{"question":"Why?","header":"H","options":[]}]}}]}}
        """#
        let e = parse(line)[0]
        #expect(e.questions == nil)
        #expect(e.text.hasPrefix("{"))
    }

    @Test func questionAndOptionCountsAreCapped() {
        let opts = (0..<20).map { ["label": "o\($0)", "description": ""] }
        let qs = (0..<20).map { ["question": "q\($0)?", "header": "h", "multiSelect": false, "options": opts] as [String: Any] }
        let parsed = ChatQuestion.parse(qs) ?? []
        #expect(parsed.count == ChatQuestion.maxQuestions)
        #expect(parsed[0].options.count == ChatQuestion.maxOptions)
    }
}
