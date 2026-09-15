import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import Foundation
import Testing
@testable import CrowDaemon

@Suite struct TuiHandlerTests {

    @MainActor
    private func harness(terminals: Int = 1) -> (CommandRouter, TuiRecorder, UUID, [UUID]) {
        let sid = UUID()
        let state = AppState()
        state.sessions = [Session(id: sid, name: "tui", kind: .work)]
        var tids: [UUID] = []
        var terms: [SessionTerminal] = []
        for i in 0..<terminals {
            let tid = UUID()
            tids.append(tid)
            terms.append(SessionTerminal(
                id: tid, sessionID: sid, name: i == 0 ? "Agent" : "Shell", cwd: "/tmp",
                tmuxBinding: TmuxBinding(
                    socketPath: "/tmp/sock", sessionName: "crow-cockpit", windowIndex: i + 1)))
        }
        state.terminals[sid] = terms
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-tui-rpc-\(UUID().uuidString)", isDirectory: true)
        let recorder = TuiRecorder(root: root, tmux: .noop, samplerInterval: 60)
        let router = makeCommandRouter(
            appState: state, store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, tuiRecorder: recorder)
        return (router, recorder, sid, tids)
    }

    @MainActor
    private func call(
        _ router: CommandRouter, _ method: String, _ params: [String: JSONValue] = [:]
    ) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    @Test @MainActor func startTwiceReusesTheSameId() async throws {
        let (router, _, sid, tids) = harness()
        let first = await call(router, "tui-record-start", [
            "session_id": .string(sid.uuidString),
            "terminal_id": .string(tids[0].uuidString),
        ])
        let id = try #require(first.result?["recording_id"]?.stringValue)
        #expect(first.result?["reused"]?.boolValue == false)
        #expect(first.result?["pty_source"]?.stringValue == "none")
        let second = await call(router, "tui-record-start", [
            "session_id": .string(sid.uuidString),
            "terminal_id": .string(tids[0].uuidString),
        ])
        #expect(second.result?["recording_id"]?.stringValue == id)
        #expect(second.result?["reused"]?.boolValue == true)
    }

    @Test @MainActor func startWithoutTerminalIdOnSingletonIsAccepted() async {
        let (router, _, sid, _) = harness(terminals: 1)
        let resp = await call(router, "tui-record-start", ["session_id": .string(sid.uuidString)])
        #expect(resp.error == nil)
        #expect(resp.result?["recording_id"]?.stringValue != nil)
    }

    @Test @MainActor func startWithoutTerminalIdOnMultiTerminalIsRejected() async {
        let (router, _, sid, _) = harness(terminals: 2)
        let resp = await call(router, "tui-record-start", ["session_id": .string(sid.uuidString)])
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }

    @Test @MainActor func stopMarkDeleteRequireRecordingId() async {
        let (router, _, _, _) = harness()
        for method in ["tui-record-stop", "tui-record-mark", "tui-record-delete"] {
            let resp = await call(router, method, [:])
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(method)")
        }
    }

    @Test @MainActor func getReturnsDirAndReportAfterStop() async throws {
        let (router, _, sid, tids) = harness()
        let started = await call(router, "tui-record-start", [
            "session_id": .string(sid.uuidString),
            "terminal_id": .string(tids[0].uuidString),
        ])
        let id = try #require(started.result?["recording_id"]?.stringValue)
        _ = await call(router, "tui-record-stop", ["recording_id": .string(id)])
        let got = await call(router, "tui-record-get", ["recording_id": .string(id)])
        #expect(got.result?["dir"]?.stringValue != nil)
        #expect(got.result?["status"]?.stringValue == "sealed")
        #expect(got.result?["report"] != nil)
    }
}
