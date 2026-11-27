import Foundation
import Testing
import CrowClaude
import CrowCore
import CrowPersistence
@testable import CrowEngine

/// CROW-1527: the launch-time warning for a Claude auto-mode session whose
/// settings turn on `blockReadsOutsideWorkingDirectories`. The settings files
/// are in-memory fixtures; the operator's real home is never read.
@Suite("ClaudeOutsideReadsNotifier")
@MainActor
struct ClaudeOutsideReadsNotifierTests {
    static let home = "/fixture-home"
    static let cwd = "/fixture-devroot/ws/repo-1-thing"
    static let userSettings = "\(home)/.claude/settings.json"
    static let localSettings = "\(cwd)/.claude/settings.local.json"
    static let on = Data(#"{"permissions":{"blockReadsOutsideWorkingDirectories":true}}"#.utf8)
    static let off = Data(#"{"permissions":{"blockReadsOutsideWorkingDirectories":false}}"#.utf8)
    static let autoLaunch = "claude --permission-mode auto --rc --name 'job'\n"
    static let manualLaunch = "claude --rc --name 'work' --continue\n"

    /// Settings files keyed by path, editable between launches.
    final class Files {
        var contents: [String: Data] = [:]
        var reads: [String] = []
    }

    static func notifier(_ files: Files) -> ClaudeOutsideReadsNotifier {
        ClaudeOutsideReadsNotifier(io: .init(
            userClaudeDir: { "\(home)/.claude" },
            readFile: { path in
                files.reads.append(path)
                return files.contents[path]
            }))
    }

    @Test func warnsForClaudeAutoModeWithTheSettingOn() {
        let files = Files()
        files.contents[Self.userSettings] = Self.on
        let finding = Self.notifier(files).check(
            sessionID: UUID(), agentKind: .claudeCode, command: Self.autoLaunch, cwd: Self.cwd)
        #expect(finding == .init(path: Self.userSettings))
    }

    @Test func silentWhenTheSettingIsOff() {
        let files = Files()
        files.contents[Self.userSettings] = Self.off
        #expect(Self.notifier(files).check(
            sessionID: UUID(), agentKind: .claudeCode, command: Self.autoLaunch, cwd: Self.cwd) == nil)
    }

    @Test func claudeOnlyAndAutoModeOnly() {
        let files = Files()
        files.contents[Self.userSettings] = Self.on
        let notifier = Self.notifier(files)
        // A manual-mode Claude launch prompts for everything anyway.
        #expect(notifier.check(
            sessionID: UUID(), agentKind: .claudeCode, command: Self.manualLaunch, cwd: Self.cwd) == nil)
        // Other harnesses don't read Claude's settings.
        for kind in [AgentKind.codex, .cursor, .openCode] {
            #expect(notifier.check(
                sessionID: UUID(), agentKind: kind, command: Self.autoLaunch, cwd: Self.cwd) == nil)
        }
        #expect(notifier.check(
            sessionID: UUID(), agentKind: nil, command: Self.autoLaunch, cwd: Self.cwd) == nil)
        // None of those launches read a settings file.
        #expect(files.reads.isEmpty)
    }

    @Test func warnsOncePerSessionAndFile() {
        let files = Files()
        files.contents[Self.userSettings] = Self.on
        let notifier = Self.notifier(files)
        let session = UUID()
        func launch(_ id: UUID = session) -> ClaudeOutsideReadsBlock.Finding? {
            notifier.check(sessionID: id, agentKind: .claudeCode, command: Self.autoLaunch, cwd: Self.cwd)
        }
        #expect(launch() != nil)
        // A relaunch of the same session stays quiet.
        #expect(launch() == nil)
        // Another session gets its own warning.
        #expect(launch(UUID()) != nil)
        // The setting moving to a more specific file is new information.
        files.contents[Self.localSettings] = Self.on
        #expect(launch() == .init(path: Self.localSettings))
        #expect(launch() == nil)
    }

    @Test func turningTheSettingOffRearmsTheWarning() {
        let files = Files()
        files.contents[Self.userSettings] = Self.on
        let notifier = Self.notifier(files)
        let session = UUID()
        func launch() -> ClaudeOutsideReadsBlock.Finding? {
            notifier.check(sessionID: session, agentKind: .claudeCode, command: Self.autoLaunch, cwd: Self.cwd)
        }
        #expect(launch() != nil)
        files.contents[Self.userSettings] = Self.off
        #expect(launch() == nil)
        files.contents[Self.userSettings] = Self.on
        #expect(launch() != nil)
    }

    @Test func malformedSettingsAreSilent() {
        let files = Files()
        files.contents[Self.userSettings] = Data("{\"permissions\":".utf8)
        files.contents[Self.localSettings] = Data("nope".utf8)
        #expect(Self.notifier(files).check(
            sessionID: UUID(), agentKind: .claudeCode, command: Self.autoLaunch, cwd: Self.cwd) == nil)
    }

    // MARK: - SessionService wiring

    private func makeService(files: Files) -> (SessionService, AppState) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1527-\(UUID().uuidString)")
        let appState = AppState()
        let service = SessionService(
            store: JSONStore(directory: tmp), appState: appState, hostBridge: NoopHostBridge())
        service.claudeOutsideReads = Self.notifier(files)
        return (service, appState)
    }

    @Test func launchCheckReportsTheSessionAndItsTerminalCwd() {
        let files = Files()
        files.contents[Self.localSettings] = Self.on
        let (service, appState) = makeService(files: files)
        let session = Session(name: "nightly-job", kind: .job, agentKind: .claudeCode)
        let terminal = SessionTerminal(sessionID: session.id, cwd: Self.cwd, command: Self.autoLaunch)
        appState.sessions = [session]
        appState.terminals[session.id] = [terminal]
        var reported: [(UUID, ClaudeOutsideReadsBlock.Finding)] = []
        service.onClaudeOutsideReadsBlocked = { reported.append(($0.id, $1)) }

        service.armAgentStartupChecks(terminalID: terminal.id, command: Self.autoLaunch)
        service.armAgentStartupChecks(terminalID: terminal.id, command: Self.autoLaunch)

        #expect(reported.count == 1)
        #expect(reported.first?.0 == session.id)
        #expect(reported.first?.1 == .init(path: Self.localSettings))
    }

    /// Review of #1536: `prepareTerminal` runs the checks before its caller
    /// (`createManagerTerminal`, `restartManager`) stores the row in
    /// `appState.terminals`. The check must use the row it was handed, not
    /// look it up.
    @Test func prepareTerminalWarnsBeforeTheRowIsStored() throws {
        let files = Files()
        files.contents[Self.localSettings] = Self.on
        let (service, appState) = makeService(files: files)
        service.terminalRegistrar = { _ in
            TmuxBinding(socketPath: "/nonexistent/tmux.sock", sessionName: "crow-cockpit", windowIndex: 1)
        }
        let manager = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        appState.sessions = [manager]
        var reported: [(UUID, ClaudeOutsideReadsBlock.Finding)] = []
        service.onClaudeOutsideReadsBlocked = { reported.append(($0.id, $1)) }

        let raw = SessionTerminal(
            sessionID: manager.id, name: manager.name, cwd: Self.cwd, command: Self.autoLaunch)
        #expect(appState.terminals[manager.id] == nil)
        _ = service.prepareTerminal(raw, trackReadiness: false)

        #expect(reported.count == 1)
        #expect(reported.first?.0 == manager.id)
        #expect(reported.first?.1 == .init(path: Self.localSettings))
    }

    @Test func prepareTerminalWithoutAPasteDoesNotWarn() {
        // A seeded Manager skips the paste here; its launch is checked later,
        // from the deferred-launch path, once the row is stored.
        let files = Files()
        files.contents[Self.localSettings] = Self.on
        let (service, appState) = makeService(files: files)
        service.terminalRegistrar = { _ in
            TmuxBinding(socketPath: "/nonexistent/tmux.sock", sessionName: "crow-cockpit", windowIndex: 1)
        }
        let manager = Session(name: "Explore", kind: .manager, agentKind: .claudeCode)
        appState.sessions = [manager]
        var reported = 0
        service.onClaudeOutsideReadsBlocked = { _, _ in reported += 1 }

        _ = service.prepareTerminal(
            SessionTerminal(sessionID: manager.id, cwd: Self.cwd, command: Self.autoLaunch),
            trackReadiness: true, pasteCommand: false)

        #expect(reported == 0)
    }

    /// The terminal-id facade serves launch sites whose row is already stored
    /// (`launchAgent`, deferred paste, hydrate). An id it can't resolve, or a
    /// non-Claude session, reports nothing.
    @Test func launchCheckIgnoresUnknownTerminalsAndOtherAgents() {
        let files = Files()
        files.contents[Self.userSettings] = Self.on
        let (service, appState) = makeService(files: files)
        let codex = Session(name: "codex-job", kind: .job, agentKind: .codex)
        let terminal = SessionTerminal(sessionID: codex.id, cwd: Self.cwd, command: Self.autoLaunch)
        appState.sessions = [codex]
        appState.terminals[codex.id] = [terminal]
        var reported = 0
        service.onClaudeOutsideReadsBlocked = { _, _ in reported += 1 }

        service.armAgentStartupChecks(terminalID: terminal.id, command: Self.autoLaunch)
        service.armAgentStartupChecks(terminalID: UUID(), command: Self.autoLaunch)

        #expect(reported == 0)
    }
}
