import CrowCore
import CrowTerminal
import Foundation

/// Types the web Chat question card's answers into a Claude Code
/// `AskUserQuestion` picker (CROW-1512).
///
/// The picker in the agent's tmux pane is what the tool is waiting on, so the
/// answers go in as key presses. ``AskUserQuestionPicker`` reads the screen and
/// picks the next key; this loop presses it, then re-captures until the screen
/// shows what that key should have done. Every key is checked: nothing is sent
/// before the picker for this very call is confirmed on screen, and nothing is
/// sent blind after a key whose effect didn't show.
///
/// When a check fails with the picker still up (a shape this Claude Code
/// version draws differently, a key that didn't land), it falls back: Esc
/// dismisses the picker, and the answers go to the agent as a plain message of
/// `Header: answer` lines through the same paste path as `send`. If the picker
/// was never on screen, nothing is pressed at all and the call fails — Esc
/// into an agent that moved on would interrupt it.
@MainActor
enum AskUserQuestionDriver {
    struct IO: Sendable {
        var capture: @MainActor @Sendable (UUID) -> String?
        var pressKey: @MainActor @Sendable (UUID, String) throws -> Void
        var typeText: @MainActor @Sendable (UUID, String) throws -> Void
        var paste: @MainActor @Sendable (UUID, String) throws -> Void
        var sleep: @Sendable (TimeInterval) async -> Void
        var now: @Sendable () -> Date

        /// Visible rows only. A picker taller than the pane leaves older
        /// frames in the scrollback (CROW-1519): the TUI never rewrites
        /// lines that scrolled off, so scrollback would show a stale tab
        /// bar, question or checkbox. The reader matches a cut frame from
        /// what is in view instead.
        static let live = IO(
            capture: { TmuxBackend.shared.captureVisibleText(id: $0) },
            pressKey: { try TmuxBackend.shared.sendKeys(id: $0, keys: [$1]) },
            typeText: { try TmuxBackend.shared.sendLiteral(id: $0, text: $1) },
            paste: { try TmuxBackend.shared.sendText(id: $0, text: $1) },
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
            now: { Date() })
    }

    enum Outcome: Equatable {
        /// Typed into the picker, which closed.
        case picker
        /// The picker was dismissed and the answers sent as a message.
        case fallback(reason: String)
    }

    struct Failure: Error, Equatable {
        var message: String
    }

    /// Pause after each key, so the TUI redraws before the next capture.
    static let keyGap: TimeInterval = 0.25
    /// How long one key's effect may take to show.
    static let stepTimeout: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.15
    /// More keys than any 4×4 call needs (a toggle per option, a few cursor
    /// moves and a confirm per question, plus the review Enter).
    static let maxSteps = 80
    static let maxEscapes = 3

    static func answer(
        terminalID: UUID, questions: [ChatQuestion], answers: [AskUserQuestionPicker.Answer], io: IO = .live
    ) async throws -> Outcome {
        var expected = 0
        var started = false
        guard var screen = read(io, terminalID, questions) else {
            throw Failure(message: "Crow couldn't read the agent's terminal.")
        }
        for _ in 0..<maxSteps {
            let decision = AskUserQuestionPicker.decide(
                screen: screen, questions: questions, answers: answers, expected: expected, started: started)
            switch decision {
            case .done:
                CrowLog.info("[AskUserQuestion] terminal=\(terminalID): answered in the picker")
                return .picker
            case .fail(let reason):
                // Never on screen, nothing pressed: leave the pane alone.
                if !started && screen == .absent { throw Failure(message: reason) }
                return try await fallBack(terminalID, questions, answers, reason: reason, io: io)
            case .step(let step):
                do {
                    switch step.key {
                    case .key(let k): try io.pressKey(terminalID, k)
                    case .literal(let t): try io.typeText(terminalID, t)
                    }
                } catch {
                    return try await fallBack(terminalID, questions, answers, reason: "A key didn't reach the terminal: \(error)", io: io)
                }
                started = true
                await io.sleep(keyGap)
                guard let next = await waitFor(step.expect, terminalID, questions, answers, io) else {
                    return try await fallBack(
                        terminalID, questions, answers,
                        reason: "The picker didn't respond as expected (\(describe(step.key))).", io: io)
                }
                if case .left = step.expect { expected += 1 }
                screen = next
            }
        }
        return try await fallBack(terminalID, questions, answers, reason: "Too many key presses.", io: io)
    }

    /// Nil when the pane can't be read: never mistaken for "no picker", so an
    /// unreadable pane is neither answered nor pasted into.
    private static func read(_ io: IO, _ id: UUID, _ questions: [ChatQuestion]) -> AskUserQuestionPicker.Screen? {
        guard let text = io.capture(id) else { return nil }
        return AskUserQuestionPicker.read(text, questions: questions)
    }

    /// Re-capture until `expect` holds; nil on timeout.
    private static func waitFor(
        _ expect: AskUserQuestionPicker.Expectation, _ id: UUID, _ questions: [ChatQuestion],
        _ answers: [AskUserQuestionPicker.Answer], _ io: IO
    ) async -> AskUserQuestionPicker.Screen? {
        let deadline = io.now().addingTimeInterval(stepTimeout)
        while true {
            if let screen = read(io, id, questions),
               AskUserQuestionPicker.satisfied(expect, by: screen, answers: answers) { return screen }
            if io.now() >= deadline { return nil }
            await io.sleep(pollInterval)
        }
    }

    /// Esc until the picker is gone, then send the answers as a message.
    private static func fallBack(
        _ id: UUID, _ questions: [ChatQuestion], _ answers: [AskUserQuestionPicker.Answer],
        reason: String, io: IO
    ) async throws -> Outcome {
        CrowLog.info("[AskUserQuestion] terminal=\(id): falling back to a message: \(reason)")
        var closed = false
        for _ in 0..<maxEscapes {
            guard let screen = read(io, id, questions) else { await io.sleep(keyGap); continue }
            if screen == .absent { closed = true; break }
            do { try io.pressKey(id, "Escape") } catch { break }
            await io.sleep(keyGap)
            if await waitFor(.closed, id, questions, answers, io) != nil { closed = true; break }
        }
        guard closed else {
            throw Failure(message: "\(reason) Crow couldn't dismiss the picker either; answer it in the terminal.")
        }
        let message = AskUserQuestionPicker.fallbackMessage(answers, for: questions)
        do {
            // Trailing newline = Enter after the bracketed paste, like `send`.
            try io.paste(id, message + "\n")
        } catch {
            throw Failure(message: "\(reason) The picker was dismissed, but the answers didn't reach the terminal: \(error)")
        }
        return .fallback(reason: reason)
    }

    private static func describe(_ key: AskUserQuestionPicker.Key) -> String {
        switch key {
        case .key(let k): return "key \(k)"
        case .literal: return "typed text"
        }
    }
}
