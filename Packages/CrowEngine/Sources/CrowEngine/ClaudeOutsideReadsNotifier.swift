import Foundation
import CrowClaude
import CrowCore

/// Warns when a Claude auto-mode session launches with
/// `permissions.blockReadsOutsideWorkingDirectories` on (CROW-1527).
///
/// Since Claude Code 2.1.327 that setting puts an ask dialog in front of Bash
/// commands that name an outside path, and an unattended session stalls there
/// (``ClaudeOutsideReadsBlock``). Crow can't answer the dialog honestly, so it
/// reports the setting at launch instead. It checks the same launch sites that
/// arm ``CodexStartupPromptWatcher``, through
/// ``SessionService/armAgentStartupChecks(terminalID:command:)``.
///
/// Claude sessions in auto mode only: the command must carry
/// ``ClaudeOutsideReadsBlock/autoModeFlag`` and the session's agent must be
/// Claude Code. It only reads the three settings files and never writes them.
///
/// One warning per session and settings file while the daemon runs. Restarting
/// a session or launching a batch of jobs doesn't repeat it. A launch that
/// finds the setting off clears the session's entry, so if the setting comes
/// back later, the next launch warns again.
@MainActor
final class ClaudeOutsideReadsNotifier {
    /// The file reads the check needs. Injected so tests can point it at
    /// fixtures instead of the operator's real home.
    struct IO {
        var homeDirectory: @MainActor () -> String
        var readFile: @MainActor (String) -> Data?

        static let live = IO(
            homeDirectory: { FileManager.default.homeDirectoryForCurrentUser.path },
            readFile: { ClaudeOutsideReadsBlock.readFileIfPresent($0) })
    }

    private let io: IO
    /// The settings file each session was last warned about.
    private var warned: [UUID: String] = [:]

    init(io: IO = .live) {
        self.io = io
    }

    /// The finding to warn about for this launch, or nil when there is nothing
    /// to report: not a Claude auto-mode launch, the setting is off, or this
    /// session was already warned about the same file.
    func check(
        sessionID: UUID,
        agentKind: AgentKind?,
        command: String?,
        cwd: String
    ) -> ClaudeOutsideReadsBlock.Finding? {
        guard agentKind == .claudeCode, ClaudeOutsideReadsBlock.isAutoModeLaunch(command) else { return nil }
        guard let finding = ClaudeOutsideReadsBlock.check(
            home: io.homeDirectory(), cwd: cwd, readFile: { self.io.readFile($0) })
        else {
            warned[sessionID] = nil
            return nil
        }
        guard warned[sessionID] != finding.path else { return nil }
        warned[sessionID] = finding.path
        return finding
    }
}

// MARK: - SessionService facade

extension SessionService {
    /// The launch-time checks for a command Crow just typed into a pane. Call
    /// it wherever a launch command is typed into a pane. Each check is a no-op
    /// for agents it doesn't cover.
    ///
    /// - Codex: answer the startup screens (CROW-1410).
    /// - Claude in auto mode: warn when `blockReadsOutsideWorkingDirectories` is
    ///   on (CROW-1527).
    func armAgentStartupChecks(terminalID: UUID, command: String?) {
        codexStartupPrompts.arm(terminalID: terminalID, command: command)
        checkClaudeOutsideReads(terminalID: terminalID, command: command)
    }

    /// Report a Claude auto-mode launch whose settings block outside reads,
    /// through the log and ``onClaudeOutsideReadsBlocked``.
    func checkClaudeOutsideReads(terminalID: UUID, command: String?) {
        // Cheap guard first, so non-auto launches never look anything up.
        guard ClaudeOutsideReadsBlock.isAutoModeLaunch(command),
              let (sessionID, terminal) = appState.terminals.lazy.compactMap({ sessionID, terminals in
                  terminals.first(where: { $0.id == terminalID }).map { (sessionID, $0) }
              }).first,
              let session = appState.sessions.first(where: { $0.id == sessionID })
        else { return }
        guard let finding = claudeOutsideReads.check(
            sessionID: sessionID, agentKind: session.agentKind, command: command, cwd: terminal.cwd)
        else { return }
        CrowLog.info("[ClaudeOutsideReads] session \(sessionID) (\(session.name)): \(finding.message)")
        onClaudeOutsideReadsBlocked?(session, finding)
    }
}
