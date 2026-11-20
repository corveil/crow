import CrowCore
import CrowTerminal
import Foundation

/// Pre-expiry compaction (CROW-1493): once a minute, type `/compact` into
/// each large Claude Code session that has sat idle long enough but whose
/// prompt cache is still warm. Off unless `contextCompaction.autoCompact`.
///
/// The decision is ``AutoCompactPolicy``. Readiness is `agent_state`, from
/// the same ``AgentStateReport`` derivation `get-session` and
/// `crow send --wait-ready` use, so there is one idle detector. Right before
/// sending, the composer is read from the pane (``ClaudeComposer``) and the
/// session is skipped unless it is visibly empty.
@MainActor
public final class AutoCompactController {
    /// The tmux side, injectable for tests.
    public struct IO {
        /// The agent pane's visible rows with SGR escapes, or nil.
        public var captureComposer: @MainActor (SessionTerminal) -> String?
        /// Type the text into the pane (a bracketed paste; the trailing
        /// newline submits).
        public var send: @MainActor (SessionTerminal, String) throws -> Void
        /// One read of every pane's foreground command, for `agent_state`.
        public var paneCommands: @MainActor () -> [UUID: String]?

        public init(
            captureComposer: @escaping @MainActor (SessionTerminal) -> String?,
            send: @escaping @MainActor (SessionTerminal, String) throws -> Void,
            paneCommands: @escaping @MainActor () -> [UUID: String]?
        ) {
            self.captureComposer = captureComposer
            self.send = send
            self.paneCommands = paneCommands
        }

        public static var live: IO {
            IO(
                captureComposer: { TmuxBackend.shared.captureVisibleText(id: $0.id, escapes: true) },
                send: { try TerminalRouter.deliver($0, text: $1) },
                paneCommands: { TerminalRouter.paneCurrentCommands() })
        }
    }

    /// What one tick did for one session, for the log and for tests.
    public struct Outcome: Equatable, Sendable {
        public var sessionID: UUID
        public var verdict: AutoCompactPolicy.Verdict
        /// The composer state, when the policy got as far as reading it.
        public var composer: ClaudeComposer.State?
        public var sent: Bool
    }

    /// The text sent. Claude Code's built-in; the newline submits it.
    public static let command = "/compact\n"
    /// At most this many sends per tick, so a dozen sessions crossing the idle
    /// mark together don't all hit the API in the same second.
    public static let maxSendsPerTick = 2

    private let appState: AppState
    private let settingsProvider: () -> ContextCompactionSettings
    private let io: IO
    private let snapshotProvider: @Sendable ([SessionContextReport.Source]) async
        -> [UUID: (ContextSnapshot, SessionContextReport.Located)]
    /// Per session, the `lastRequestAt` Crow already compacted for. In memory:
    /// a `crowd` restart can at most retry one compaction, which the
    /// transcript's compaction boundary then stops anyway.
    private var attempted: [UUID: Date] = [:]
    /// Skip reasons already logged per session, so a session sitting below the
    /// threshold doesn't write a line every minute.
    private var lastLogged: [UUID: String] = [:]

    public init(
        appState: AppState,
        settingsProvider: @escaping () -> ContextCompactionSettings,
        io: IO = .live,
        snapshotProvider: (@Sendable ([SessionContextReport.Source]) async
            -> [UUID: (ContextSnapshot, SessionContextReport.Located)])? = nil
    ) {
        self.appState = appState
        self.settingsProvider = settingsProvider
        self.io = io
        // Off the MainActor: file reads wedge the RPC surface otherwise (#892).
        self.snapshotProvider = snapshotProvider ?? { sources in
            await Task.detached { SessionContextReport.snapshots(for: sources) }.value
        }
    }

    /// One pass. Returns what happened per candidate session.
    @discardableResult
    public func tick(now: Date = Date()) async -> [Outcome] {
        let settings = settingsProvider()
        guard settings.autoCompact else { return [] }
        let sources = appState.sessions
            .filter { $0.agentKind == .claudeCode }
            .compactMap { SessionContextReport.source(for: $0, appState: appState) }
        guard !sources.isEmpty else { return [] }
        let snapshots = await snapshotProvider(sources)

        let paneCommands = io.paneCommands()
        var outcomes: [Outcome] = []
        var sends = 0
        for source in sources {
            guard let session = appState.sessions.first(where: { $0.id == source.sessionID }) else { continue }
            let hit = snapshots[source.sessionID]
            let state = AgentReadiness.state(
                AgentStateReport.inputs(for: session, appState: appState, paneCommands: paneCommands), now: now)
            let inputs = AutoCompactPolicy.Inputs(
                agentKind: session.agentKind, status: session.status, agentState: state,
                snapshot: hit?.0, lastAttemptFor: attempted[session.id])
            var outcome = Outcome(
                sessionID: session.id,
                verdict: AutoCompactPolicy.evaluate(inputs, settings: settings, now: now),
                composer: nil, sent: false)
            if outcome.verdict == .compact, sends < Self.maxSendsPerTick,
               let terminal = AgentStateReport.agentTerminal(for: session, appState: appState) {
                let composer = io.captureComposer(terminal).map(ClaudeComposer.state(ofCapture:)) ?? .notFound
                outcome.composer = composer
                if composer == .empty, let lastRequest = hit?.0.lastRequestAt {
                    // Recorded before sending: a failed paste must not be
                    // retried every minute into a pane that isn't taking it.
                    attempted[session.id] = lastRequest
                    do {
                        try io.send(terminal, Self.command)
                        appState.hookState(for: session.id).crowCompactionRequestedAt = now
                        outcome.sent = true
                        sends += 1
                    } catch {
                        CrowLog.automation("auto-compact: send to \(session.name) failed: \(error)")
                    }
                }
            }
            log(outcome, session: session, tokens: hit?.0.tokens, idle: hit?.0.idleSeconds(now: now))
            outcomes.append(outcome)
        }
        // Forget sessions that are gone.
        let live = Set(appState.sessions.map(\.id))
        attempted = attempted.filter { live.contains($0.key) }
        lastLogged = lastLogged.filter { live.contains($0.key) }
        return outcomes
    }

    private func log(_ outcome: Outcome, session: Session, tokens: Int?, idle: TimeInterval?) {
        let what: String
        switch outcome.verdict {
        case .skip(let reason):
            // The everyday skips aren't news.
            if [.belowThreshold, .notIdleLongEnough, .noTranscript].contains(reason) {
                lastLogged[session.id] = nil
                return
            }
            what = "skip \(reason.rawValue)"
        case .compact:
            if outcome.sent {
                what = "sent /compact"
            } else if let composer = outcome.composer {
                what = "skip composer_\(composer.rawValue)"
            } else {
                what = "deferred (send cap)"
            }
        }
        guard outcome.sent || lastLogged[session.id] != what else { return }
        lastLogged[session.id] = outcome.sent ? nil : what
        let tokenText = tokens.map(String.init) ?? "?"
        let idleText = idle.map { "\(Int($0 / 60))m" } ?? "?"
        CrowLog.automation(
            "auto-compact: \(session.name) (\(session.id.uuidString)) tokens=\(tokenText) idle=\(idleText): \(what)")
    }
}
