import Foundation
import Testing
@testable import CrowEngine

/// CROW-1410: the watch that answers Codex's model-migration screen.
/// CROW-1425: and the 0.167 read-only provider notice.
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

    static let providerNotice = """
          🔒  Model provider unavailable
              This chat uses model provider “crow-corveil”, which is no longer configured. Restore this provider’s configuration to continue.

          c continue in new chat · n start fresh · esc other chats
        """

    static var polls: Int { Int(CodexStartupPromptWatcher.budget / CodexStartupPromptWatcher.pollInterval) }

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

    @Test func answersMigrationOnceAndKeepsWatching() async {
        let pane = Pane([nil, "$ codex", Self.migration, Self.composer])
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.keys == [["2"], ["Enter"]])
        // The provider notice can still follow the migration prompt, so a clean
        // screen after the migration answer doesn't end the watch (CROW-1425).
        #expect(pane.captures == Self.polls)
    }

    @Test func answersProviderNoticeWithStartFreshAndStops() async {
        let pane = Pane([nil, "$ codex", Self.providerNotice, Self.composer])
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.keys == [["n"]])
        // Nothing follows the provider notice: stopped at the first clean screen.
        #expect(pane.captures == 4)
    }

    /// The order Codex draws them on a resume: migration first, then the
    /// resumed thread's notice. Each gets its own answer.
    @Test func answersMigrationThenProviderNotice() async {
        let pane = Pane([Self.migration, "  >_ OpenAI Codex", Self.providerNotice, Self.composer])
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.keys == [["2"], ["Enter"], ["n"]])
        #expect(pane.captures == 4)
    }

    @Test func lostStartFreshIsRetriedPerScreenBudget() async {
        var reasons: [String] = []
        let pane = Pane([Self.migration, Self.providerNotice])
        await watcher(pane, operatorCalls: { reasons.append($0) }).watch(terminalID: UUID())
        // One migration answer, then the notice gets its own full retry budget.
        #expect(pane.keys == [["2"], ["Enter"]]
            + Array(repeating: ["n"], count: CodexStartupPromptWatcher.maxAnswers))
        #expect(reasons.count == 1)
        #expect(reasons.first?.contains("model-provider notice") == true)
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
        // The operator's answer is a migration answer too; the provider notice
        // can still follow it, so the watch runs on.
        #expect(pane.captures == Self.polls)
    }

    @Test func sessionWithoutPromptSendsNothing() async {
        let pane = Pane([Self.composer])
        await watcher(pane).watch(terminalID: UUID())
        #expect(pane.keys.isEmpty)
        #expect(pane.captures == Self.polls)
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
