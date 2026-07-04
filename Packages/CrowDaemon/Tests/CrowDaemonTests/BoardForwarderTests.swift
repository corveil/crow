import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// Board RPCs (Ticket Board / Reviews / Allowlist) forward to the desktop app,
/// whose live `AppState` holds the data. This suite pins the **app-down**
/// contract — no tmux/app/socket needed — so the web UI degrades gracefully:
/// reads return an empty board, actions surface an application error.
@Suite struct BoardForwarderTests {
    /// A router with `forwardSocket: nil` — i.e. the app isn't reachable.
    @MainActor
    private func offlineRouter() -> CommandRouter {
        makeCommandRouter(
            appState: AppState(),
            store: JSONStore(),
            git: GitManager(),
            devRoot: NSTemporaryDirectory(),
            cockpit: nil,
            forwardSocket: nil)
    }

    @Test @MainActor func readBoardsReturnEmptyWhenAppDown() async {
        let router = offlineRouter()

        let tickets = await router.handle(request: JSONRPCRequest(id: 1, method: "list-tickets"))
        #expect(tickets.error == nil)
        #expect(tickets.result?["issues"]?.arrayValue?.isEmpty == true)
        #expect(tickets.result?["done_last_24h"]?.intValue == 0)

        let reviews = await router.handle(request: JSONRPCRequest(id: 2, method: "list-reviews"))
        #expect(reviews.error == nil)
        #expect(reviews.result?["reviews"]?.arrayValue?.isEmpty == true)

        let allow = await router.handle(request: JSONRPCRequest(id: 3, method: "list-allowlist"))
        #expect(allow.error == nil)
        #expect(allow.result?["entries"]?.arrayValue?.isEmpty == true)

        let live = await router.handle(request: JSONRPCRequest(id: 4, method: "list-sessions-live"))
        #expect(live.error == nil)
        #expect(live.result?["sessions"]?.objectValue?.isEmpty == true)
    }

    @Test @MainActor func boardActionsErrorWhenAppDown() async {
        let router = offlineRouter()
        let actions = [
            "work-on-issue", "start-review", "promote-allowlist", "refresh-tickets", "refresh-allowlist",
            "create-manager", "mark-in-review", "mark-issue-done", "complete-session",
            "set-session-active", "add-merge-label",
        ]
        for method in actions {
            let resp = await router.handle(request: JSONRPCRequest(id: 1, method: method))
            #expect(resp.error != nil, "\(method) should error when the app is down")
            #expect(resp.error?.code == RPCErrorCode.applicationError, "\(method) should be an application error")
        }
    }
}
