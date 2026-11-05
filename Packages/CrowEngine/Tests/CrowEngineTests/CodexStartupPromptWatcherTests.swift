import Foundation
import Testing
@testable import CrowEngine

/// CROW-1410: the watch that answers Codex's model-migration screen.
@MainActor
@Suite("CodexStartupPromptWatcher")
struct CodexStartupPromptWatcherTests {
    static let migration = """
          Crow New is here.

        › 1. Try new model
          2. Use existing model

          enter/esc confirm · ⌃c quit
        """
    static let composer = """
        › Ask Codex to do anything

          Crow Old default · /tmp/proj
        """
    static let noOptOut = """
          GPT-5.4 is no longer available

          enter/esc continue · ⌃c quit
        """

    /// A fake pane: plays `screens` in order (repeating the last), records keys.
    final class Pane {
        var screens: [String?]
        var keys: [[String]] = []
        var alive = true
        var captures = 0
        init(_ screens: [String?]) { self.screens = screens }
        func next() -> String? {
            captures += 1
            return screens.count > 1 ? screens.removeFirst() : screens.first ?? nil
        }
    }

    func watcher(_ pane: Pane, operatorCalls: @escaping @MainActor (String) -> Void = { _ in })
        -> CodexStartupPromptWatcher {
        CodexStartupPromptWatcher(
            io: .init(
                capture: { _ in pane.next() },
                sendKeys: { _, keys in pane.keys.append(keys) },
                isAlive: { _ in pane.alive },
                sleep: { _ in }),
            onNeedsOperator: { _, reason in operatorCalls(reason) })
    }

    @Test func answersMigrationOnceAndStops() async {
        let pane = Pane([nil, "$ codex", Self.migration, Self.composer])
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.keys == [["2"], ["Enter"]])
        // Stopped at the first clean screen after the answer, not at the budget.
        #expect(pane.captures == 4)
    }

    @Test func reanswersALostKeypressButGivesUp() async {
        var reasons: [String] = []
        let pane = Pane([Self.migration])
        await watcher(pane, operatorCalls: { reasons.append($0) }).watch(terminalID: UUID())
        #expect(pane.keys.count == CodexStartupPromptWatcher.maxAnswers * 2)
        #expect(reasons.count == 1)
    }

    @Test func noOptOutIsReportedOnceAndNeverAnswered() async {
        var reasons: [String] = []
        let pane = Pane([Self.noOptOut, Self.noOptOut, Self.composer])
        await watcher(pane, operatorCalls: { reasons.append($0) }).watch(terminalID: UUID())
        #expect(pane.keys.isEmpty)
        #expect(reasons.count == 1)
        #expect(pane.captures == 3)
    }

    @Test func sessionWithoutPromptSendsNothing() async {
        let pane = Pane([Self.composer])
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.keys.isEmpty)
        #expect(pane.captures == Int(CodexStartupPromptWatcher.budget / CodexStartupPromptWatcher.pollInterval))
    }

    @Test func closedWindowEndsTheWatch() async {
        let pane = Pane([Self.migration])
        pane.alive = false
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.captures == 0)
        #expect(pane.keys.isEmpty)
    }

    @Test func armsOnlyForCodexLaunches() {
        let w = watcher(Pane([Self.composer]))
        let claude = UUID(), codex = UUID()
        w.arm(terminalID: claude, command: "claude --continue")
        w.arm(terminalID: UUID(), command: nil)
        w.arm(terminalID: codex, command: "codex -c check_for_update_on_startup=false --no-alt-screen")
        #expect(w.activeTerminalIDs == [codex])
    }
}
