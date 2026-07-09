import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Locks down which terminals receive a `/rename` slash command when a session
/// is renamed (#354). The selection is driven by `remoteControlActiveTerminals`
/// — the set of terminals launched with `--rc` — and NOT by `isManaged`, since
/// Manager terminals are RC-active without carrying the `isManaged` flag.
@Suite("SessionService.remoteControlRenameTargets")
struct RemoteControlRenameTargetTests {

    private func terminal(_ id: UUID, isManaged: Bool = false) -> SessionTerminal {
        SessionTerminal(id: id, sessionID: UUID(), cwd: "/tmp", isManaged: isManaged)
    }

    @Test
    func returnsRemoteControlTerminal() {
        let rc = UUID()
        let terminals = [terminal(rc)]
        let targets = SessionService.remoteControlRenameTargets(
            terminals: terminals, rcActiveTerminals: [rc]
        )
        #expect(targets.map(\.id) == [rc])
    }

    @Test
    func returnsEmptyWhenNoRemoteControlTerminal() {
        let terminals = [terminal(UUID()), terminal(UUID())]
        let targets = SessionService.remoteControlRenameTargets(
            terminals: terminals, rcActiveTerminals: []
        )
        #expect(targets.isEmpty)
    }

    /// Manager terminals run Claude with `--rc` but are created without the
    /// `isManaged` flag — they must still be selected, otherwise renaming a
    /// non-primary Manager session (#354's primary case) wouldn't sync.
    @Test
    func selectsRemoteControlTerminalEvenWhenNotManaged() {
        let rc = UUID()
        let terminals = [terminal(rc, isManaged: false)]
        let targets = SessionService.remoteControlRenameTargets(
            terminals: terminals, rcActiveTerminals: [rc]
        )
        #expect(targets.map(\.id) == [rc])
    }

    @Test
    func filtersToOnlyRemoteControlTerminals() {
        let rc = UUID()
        let plainShell = UUID()
        let terminals = [terminal(plainShell), terminal(rc)]
        let targets = SessionService.remoteControlRenameTargets(
            terminals: terminals, rcActiveTerminals: [rc]
        )
        #expect(targets.map(\.id) == [rc])
    }
}

/// CROW-629: Manager rename forwards `/rename` by agent capability, not by
/// `--rc` bookkeeping. Cursor/Codex/OpenCode Managers never enter
/// `remoteControlActiveTerminals` (no `--rc` flag) but still expose `/rename`.
@Suite("SessionService.agentRenameTargets")
struct AgentRenameTargetTests {

    private func terminal(_ id: UUID, sessionID: UUID = UUID()) -> SessionTerminal {
        SessionTerminal(id: id, sessionID: sessionID, cwd: "/tmp", isManaged: false)
    }

    @Test
    func managerReturnsAllTerminalsWhenRenameSupported() {
        let session = Session(name: "Manager", kind: .manager, agentKind: .cursor)
        let a = UUID()
        let b = UUID()
        let terminals = [terminal(a, sessionID: session.id), terminal(b, sessionID: session.id)]
        let targets = SessionService.agentRenameTargets(
            session: session,
            terminals: terminals,
            rcActiveTerminals: [],
            supportsRename: true
        )
        #expect(targets.map(\.id) == [a, b])
    }

    @Test
    func managerReturnsEmptyWhenRenameUnsupported() {
        let session = Session(name: "Manager", kind: .manager, agentKind: .cursor)
        let terminals = [terminal(UUID(), sessionID: session.id)]
        let targets = SessionService.agentRenameTargets(
            session: session,
            terminals: terminals,
            rcActiveTerminals: [],
            supportsRename: false
        )
        #expect(targets.isEmpty)
    }

    @Test
    func workerStaysRemoteControlGated() {
        let session = Session(name: "work", kind: .work, agentKind: .claudeCode)
        let rc = UUID()
        let plain = UUID()
        let terminals = [terminal(plain, sessionID: session.id), terminal(rc, sessionID: session.id)]
        let targets = SessionService.agentRenameTargets(
            session: session,
            terminals: terminals,
            rcActiveTerminals: [rc],
            supportsRename: true
        )
        #expect(targets.map(\.id) == [rc])
    }

    @Test
    func workerReturnsEmptyWithoutRemoteControlEvenWhenRenameSupported() {
        let session = Session(name: "work", kind: .work, agentKind: .cursor)
        let terminals = [terminal(UUID(), sessionID: session.id)]
        let targets = SessionService.agentRenameTargets(
            session: session,
            terminals: terminals,
            rcActiveTerminals: [],
            supportsRename: true
        )
        #expect(targets.isEmpty)
    }
}
