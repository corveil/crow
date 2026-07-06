import Foundation
import Testing
@testable import CrowCore

/// The `DaemonStateSnapshot` is the wire contract `crowd` pushes to rich clients
/// (the macOS app) so they rebuild `AppState` from one `get-state` call. These
/// cover the two invariants the client relies on: an `AppState` round-trips
/// through the snapshot (`init(appState:)` → `apply`) preserving render state,
/// and the snapshot survives JSON encode/decode losslessly (CROW-581, Stage 2/3).
@Suite struct DaemonStateSnapshotTests {
    @MainActor
    private func seededAppState() -> (AppState, sessionID: UUID, terminalID: UUID) {
        let state = AppState()
        let sid = UUID(), tid = UUID()
        state.sessions = [Session(id: sid, name: "feat", kind: .work)]
        state.terminals[sid] = [SessionTerminal(
            id: tid, sessionID: sid, name: "Claude Code", cwd: "/tmp",
            command: nil, isManaged: true, tmuxBinding: nil)]
        state.links[sid] = [SessionLink(sessionID: sid, label: "PR", url: "https://x/pull/1", linkType: .pr)]
        state.terminalReadiness[tid] = .agentLaunched
        state.remoteControlActiveTerminals = [tid]
        state.remoteControlEnabled = true
        state.activeTerminalID[sid] = tid
        return (state, sid, tid)
    }

    @Test @MainActor func roundTripsRenderStateThroughSnapshot() {
        let (src, sid, tid) = seededAppState()
        let snapshot = DaemonStateSnapshot(appState: src)

        let dst = AppState()
        dst.apply(snapshot)

        #expect(dst.sessions.map(\.id) == [sid])
        #expect(dst.terminals[sid]?.map(\.id) == [tid])
        #expect(dst.links[sid]?.first?.linkType == .pr)
        #expect(dst.terminalReadiness[tid] == .agentLaunched)
        #expect(dst.remoteControlActiveTerminals == [tid])
        #expect(dst.remoteControlEnabled)
        #expect(dst.activeTerminalID[sid] == tid)
    }

    @Test @MainActor func encodesAndDecodesLosslessly() throws {
        let (src, sid, tid) = seededAppState()
        let snapshot = DaemonStateSnapshot(appState: src)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DaemonStateSnapshot.self, from: data)

        #expect(decoded.sessions.map(\.id) == [sid])
        #expect(decoded.terminals.map(\.id) == [tid])
        #expect(decoded.terminalReadiness[tid.uuidString] == .agentLaunched)
        #expect(decoded.remoteControlActiveTerminals == [tid.uuidString])
        #expect(decoded.activeTerminalID[sid.uuidString] == tid.uuidString)
    }
}
