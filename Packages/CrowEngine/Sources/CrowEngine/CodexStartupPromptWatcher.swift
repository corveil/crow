import Foundation
import CrowCodex
import CrowCore
import CrowTerminal

/// Watches a freshly launched Codex pane for the startup screens Crow answers
/// (CROW-1410, CROW-1425): the model-migration prompt and, on Codex 0.167+,
/// the read-only model-provider notice on a resumed thread.
///
/// Codex has no config key that hides either screen ahead of time (see
/// ``CodexStartupNotices``), and they block unattended launches. So for a few
/// minutes after Crow types a Codex launch into a pane, this polls the pane's
/// visible rows once a second and acts on
/// ``CodexStartupNotices/response(toScreen:)``:
///
/// - `.answer` sends the screen's keys. On the migration prompt that is `2`,
///   then Enter, which keeps the current model; Codex records the
///   acknowledgment in its own config, as it would for the operator. On the
///   provider notice it is `n` (start fresh), the fresh TUI Codex 0.166 opened
///   on its own. Neither choice loses anything Crow relies on, so Crow makes
///   them unattended. If a screen is still up on the next poll (a key was
///   lost), it answers again, at most ``maxAnswers`` times per screen.
/// - `.needsOperator` (the migration screen with no keep-current option) is
///   reported once through `onNeedsOperator` and left alone, because every
///   answer switches the model.
///
/// The watch ends once the provider notice has been answered and cleared (no
/// startup screen follows it), when the window goes away, or after ``budget``.
/// Answering the migration prompt doesn't end it: Codex resumes the thread
/// after that prompt, so the provider notice can still come up. It is armed at every place a Codex launch is typed
/// into a pane, keyed on ``CodexStartupNotices/isCodexLaunch(_:)``, so it
/// covers `setup.sh` work sessions, jobs, reviews, handoffs, and Managers alike.
@MainActor
final class CodexStartupPromptWatcher {
    /// The pane operations the watch needs. Injected so tests can drive it
    /// without tmux.
    struct IO {
        var capture: @MainActor (UUID) -> String?
        var sendKeys: @MainActor (UUID, [String]) throws -> Void
        var isAlive: @MainActor (UUID) -> Bool
        var sleep: @Sendable (TimeInterval) async -> Void

        static let live = IO(
            capture: { TmuxBackend.shared.captureVisibleText(id: $0) },
            sendKeys: { try TmuxBackend.shared.sendKeys(id: $0, keys: $1) },
            isAlive: { TmuxBackend.shared.isRegistered(id: $0) },
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    }

    /// Long enough to cover a slow shell start (the readiness watch alone
    /// allows 30s) plus Codex's startup catalog fetch.
    static let budget: TimeInterval = 180
    static let pollInterval: TimeInterval = 1
    /// Pause between the `2` and the Enter, so Codex redraws the highlight
    /// before the confirm arrives.
    static let keyGap: TimeInterval = 0.3
    static let maxAnswers = 3

    private let io: IO
    private let onNeedsOperator: @MainActor (UUID, String) -> Void
    private var watches: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(io: IO = .live, onNeedsOperator: @escaping @MainActor (UUID, String) -> Void) {
        self.io = io
        self.onNeedsOperator = onNeedsOperator
    }

    /// Start watching `terminalID` if `command` is a Crow-built Codex launch.
    /// Re-arming a terminal replaces its previous watch.
    func arm(terminalID: UUID, command: String?) {
        guard let command, CodexStartupNotices.isCodexLaunch(command) else { return }
        watches[terminalID]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            await self?.watch(terminalID: terminalID)
            self?.finish(terminalID: terminalID, token: token)
        }
        watches[terminalID] = (token, task)
    }

    var activeTerminalIDs: Set<UUID> { Set(watches.keys) }

    /// Drop the bookkeeping for a finished watch, unless a newer one replaced it.
    private func finish(terminalID: UUID, token: UUID) {
        if watches[terminalID]?.token == token { watches[terminalID] = nil }
    }

    /// Run the watch to completion. Internal so tests can await it directly.
    func watch(terminalID: UUID) async {
        var answers: [CodexStartupNotices.Screen: Int] = [:]
        var lastAnswered: CodexStartupNotices.Screen?
        var reportedOperator = false
        let polls = Int(Self.budget / Self.pollInterval)
        for _ in 0..<polls {
            await io.sleep(Self.pollInterval)
            if Task.isCancelled || !io.isAlive(terminalID) { return }
            guard let screen = io.capture(terminalID) else { continue }
            switch CodexStartupNotices.response(toScreen: screen) {
            case .answer(let keys, let kind):
                let count = answers[kind, default: 0]
                guard count < Self.maxAnswers else {
                    CrowLog.info("[CodexStartupPrompt] terminal=\(terminalID): \(kind.rawValue) still up after \(count) answers; leaving it for the operator")
                    onNeedsOperator(terminalID, "Codex's \(kind.rawValue) did not accept Crow's answer")
                    return
                }
                answers[kind] = count + 1
                lastAnswered = kind
                CrowLog.info("[CodexStartupPrompt] terminal=\(terminalID): answering the \(kind.rawValue) with \(Self.choice(for: kind)) (attempt \(count + 1))")
                await press(keys, terminalID: terminalID)
            case .needsOperator(let reason):
                if !reportedOperator {
                    reportedOperator = true
                    CrowLog.info("[CodexStartupPrompt] terminal=\(terminalID): \(reason); waiting for the operator")
                    onNeedsOperator(terminalID, reason)
                }
            case nil:
                // The provider notice is the last startup screen Codex draws, so
                // once an answer to it has taken, the watch is done. After the
                // migration prompt the thread is still being resumed, and the
                // notice can follow, so the watch runs on.
                if lastAnswered?.isLastStartupScreen == true { return }
            }
        }
    }

    /// The option an answer picks, for the log line.
    private static func choice(for screen: CodexStartupNotices.Screen) -> String {
        switch screen {
        case .modelMigration: return "\"Use existing model\""
        case .providerNotice: return "\"start fresh\" (n), as Codex 0.166 did on its own"
        }
    }

    private func press(_ keys: [String], terminalID: UUID) async {
        for (index, key) in keys.enumerated() {
            if index > 0 { await io.sleep(Self.keyGap) }
            do {
                try io.sendKeys(terminalID, [key])
            } catch {
                CrowLog.info("[CodexStartupPrompt] terminal=\(terminalID): send-keys failed: \(error)")
                return
            }
        }
    }
}

// MARK: - SessionService facade

extension SessionService {
    /// Arm the Codex startup-prompt watch for `terminalID` when `command` is a
    /// Codex launch (CROW-1410). Call it wherever a launch command is typed
    /// into a pane; it is a no-op for every other agent.
    func armCodexStartupPromptWatch(terminalID: UUID, command: String?) {
        codexStartupPrompts.arm(terminalID: terminalID, command: command)
    }

    /// Show a session whose Codex pane is stuck on a prompt Crow won't answer
    /// as waiting on the operator, the same state a permission prompt sets.
    func markCodexPromptNeedsOperator(terminalID: UUID, reason: String) {
        guard let sessionID = appState.terminals.first(where: { _, terminals in
            terminals.contains(where: { $0.id == terminalID })
        })?.key else { return }
        CrowLog.info("[SessionService] session \(sessionID) is waiting on a Codex startup prompt: \(reason)")
        appState.hookState(for: sessionID).activityState = .waiting
    }
}
