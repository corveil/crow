import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// `get-session-terminal-preview` handler coverage (CROW-976).
@Suite struct SessionTerminalPreviewHandlerTests {

    @MainActor
    private func router(
        appState: AppState = AppState(),
        cockpit: TerminalCockpit? = nil
    ) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: cockpit)
    }

    @MainActor
    private func preview(
        _ params: [String: JSONValue],
        appState: AppState = AppState(),
        cockpit: TerminalCockpit? = nil
    ) async -> JSONRPCResponse {
        await router(appState: appState, cockpit: cockpit)
            .handle(request: JSONRPCRequest(
                id: 1, method: "get-session-terminal-preview", params: params))
    }

    // MARK: - Param validation

    @Test @MainActor func rejectsMissingSessionID() async {
        let resp = await preview([:])
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }

    @Test @MainActor func rejectsMalformedSessionID() async {
        let resp = await preview(["session_id": .string("not-a-uuid")])
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }

    // MARK: - Best-effort null paths

    @Test @MainActor func returnsNullWithoutCockpit() async {
        let sid = UUID()
        let resp = await preview(["session_id": .string(sid.uuidString)])
        #expect(resp.error == nil)
        #expect(resp.result?["preview"] == .null)
    }

    @Test @MainActor func returnsNullWhenNoTmuxBinding() async {
        let sid = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(sessionID: sid, name: "Shell", cwd: "/tmp"),
        ]
        let cockpit = TerminalCockpit { _ in "should not be called" }
        let resp = await preview(
            ["session_id": .string(sid.uuidString)], appState: state, cockpit: cockpit)
        #expect(resp.error == nil)
        #expect(resp.result?["preview"] == .null)
    }

    // MARK: - Happy path

    @Test @MainActor func returnsPreviewForBoundPane() async {
        let sid = UUID()
        let tid = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(
                id: tid, sessionID: sid, name: "Agent", cwd: "/repo",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 3)),
        ]
        let cockpit = TerminalCockpit { idx in
            #expect(idx == 3)
            return "line one\nline two"
        }
        let resp = await preview(
            ["session_id": .string(sid.uuidString)], appState: state, cockpit: cockpit)
        #expect(resp.error == nil)
        #expect(resp.result?["preview"] == .string("line one\nline two"))
    }

    // MARK: - Window selection

    @Test @MainActor func prefersActiveTerminalWindow() async {
        let sid = UUID()
        let first = UUID()
        let active = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(
                id: first, sessionID: sid, name: "First", cwd: "/a",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 1)),
            SessionTerminal(
                id: active, sessionID: sid, name: "Active", cwd: "/b",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 7)),
        ]
        state.activeTerminalID[sid] = active
        #expect(state.terminalPreviewWindowIndex(for: sid) == 7)

        let cockpit = TerminalCockpit { idx in
            #expect(idx == 7)
            return "active pane"
        }
        let resp = await preview(
            ["session_id": .string(sid.uuidString)], appState: state, cockpit: cockpit)
        #expect(resp.result?["preview"] == .string("active pane"))
    }

    @Test @MainActor func fallsBackToFirstBoundTerminal() async {
        let sid = UUID()
        let first = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(sessionID: sid, name: "Shell", cwd: "/tmp"),
            SessionTerminal(
                id: first, sessionID: sid, name: "Agent", cwd: "/repo",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 2)),
        ]
        #expect(state.terminalPreviewWindowIndex(for: sid) == 2)
    }

    @Test @MainActor func fallsBackWhenActiveTerminalHasNoBinding() async {
        let sid = UUID()
        let shell = UUID()
        let agent = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(id: shell, sessionID: sid, name: "Shell", cwd: "/tmp"),
            SessionTerminal(
                id: agent, sessionID: sid, name: "Agent", cwd: "/repo",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 5)),
        ]
        state.activeTerminalID[sid] = shell
        #expect(state.terminalPreviewWindowIndex(for: sid) == 5)

        let cockpit = TerminalCockpit { idx in
            #expect(idx == 5)
            return "agent pane"
        }
        let resp = await preview(
            ["session_id": .string(sid.uuidString)], appState: state, cockpit: cockpit)
        #expect(resp.result?["preview"] == .string("agent pane"))
    }

    @Test @MainActor func watchIndexPrefersManagedTerminal() {
        let sid = UUID()
        let shell = UUID()
        let managed = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(
                id: shell, sessionID: sid, name: "Shell", cwd: "/tmp",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 1)),
            SessionTerminal(
                id: managed, sessionID: sid, name: "Claude Code", cwd: "/repo",
                isManaged: true,
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 9)),
        ]
        state.activeTerminalID[sid] = shell
        #expect(state.terminalPreviewWindowIndex(for: sid) == 1)
        #expect(state.terminalWatchWindowIndex(for: sid) == 9)
    }

    @Test @MainActor func watchIndexFallsBackWhenNothingIsManaged() {
        let sid = UUID()
        let first = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(
                id: first, sessionID: sid, name: "Manager", cwd: "/tmp",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 4)),
        ]
        #expect(state.terminalWatchWindowIndex(for: sid) == 4)
    }
}

/// `list-session-terminal-snapshots` handler coverage (CROW-1153).
@Suite struct SessionTerminalSnapshotHandlerTests {

    @MainActor
    private func router(
        appState: AppState = AppState(),
        cockpit: TerminalCockpit? = nil
    ) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: cockpit)
    }

    @MainActor
    private func snapshots(
        _ params: [String: JSONValue],
        appState: AppState = AppState(),
        cockpit: TerminalCockpit? = nil
    ) async -> JSONRPCResponse {
        await router(appState: appState, cockpit: cockpit)
            .handle(request: JSONRPCRequest(
                id: 1, method: "list-session-terminal-snapshots", params: params))
    }

    @Test @MainActor func emptyIdsReturnsEmptyObject() async {
        let resp = await snapshots([:])
        #expect(resp.error == nil)
        #expect(resp.result?["snapshots"] == .object([:]))
    }

    @Test @MainActor func missingCockpitNullsEachId() async {
        let sid = UUID()
        let resp = await snapshots(["session_ids": .array([.string(sid.uuidString)])])
        #expect(resp.error == nil)
        #expect(resp.result?["snapshots"] == .object([sid.uuidString: .null]))
    }

    @Test @MainActor func returnsSnapshotForBoundManagedPane() async {
        let sid = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(
                sessionID: sid, name: "Agent", cwd: "/repo", isManaged: true,
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 3)),
        ]
        let cockpit = TerminalCockpit(
            previewCapture: { _ in nil },
            snapshotCapture: { idx in
                #expect(idx == 3)
                return GridPaneSnapshot(snapshot: "\u{1b}[Hframe", cols: 80, rows: 24)
            })
        let resp = await snapshots(
            ["session_ids": .array([.string(sid.uuidString)])],
            appState: state, cockpit: cockpit)
        #expect(resp.error == nil)
        let row = resp.result?["snapshots"]?.objectValue?[sid.uuidString]?.objectValue
        #expect(row?["snapshot"] == .string("\u{1b}[Hframe"))
        #expect(row?["cols"] == .int(80))
        #expect(row?["rows"] == .int(24))
    }

    @Test @MainActor func capsAtSixteenIds() async {
        let ids = (0..<20).map { _ in UUID() }
        var state = AppState()
        for (i, sid) in ids.enumerated() {
            state.terminals[sid] = [
                SessionTerminal(
                    sessionID: sid, name: "T", cwd: "/tmp", isManaged: true,
                    tmuxBinding: TmuxBinding(
                        socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: i)),
            ]
        }
        let cockpit = TerminalCockpit(
            previewCapture: { _ in nil },
            snapshotCapture: { _ in GridPaneSnapshot(snapshot: "x", cols: 40, rows: 12) })
        let resp = await snapshots(
            ["session_ids": .array(ids.map { .string($0.uuidString) })],
            appState: state, cockpit: cockpit)
        #expect(resp.error == nil)
        #expect(resp.result?["snapshots"]?.objectValue?.count == 16)
    }

    @Test @MainActor func skipsMalformedIds() async {
        let sid = UUID()
        var state = AppState()
        state.terminals[sid] = [
            SessionTerminal(
                sessionID: sid, name: "Agent", cwd: "/repo",
                tmuxBinding: TmuxBinding(socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: 2)),
        ]
        let cockpit = TerminalCockpit(
            previewCapture: { _ in nil },
            snapshotCapture: { _ in GridPaneSnapshot(snapshot: "ok", cols: 8, rows: 4) })
        let resp = await snapshots(
            ["session_ids": .array([.string("nope"), .string(sid.uuidString)])],
            appState: state, cockpit: cockpit)
        let obj = resp.result?["snapshots"]?.objectValue ?? [:]
        #expect(obj["nope"] == nil)
        #expect(obj[sid.uuidString]?.objectValue?["snapshot"] == .string("ok"))
    }
}
