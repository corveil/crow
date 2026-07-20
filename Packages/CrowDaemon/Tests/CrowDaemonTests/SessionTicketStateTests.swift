import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// #792: `list-sessions` carries the linked issue's open/closed state so the web
/// sidebar can color the ticket pill purple once the issue is closed — parity
/// with the merged-PR pill. The state is joined from the board
/// (`AppState.assignedIssue(for:)`), the same source the label pills already use.
@Suite struct SessionTicketStateTests {
    @MainActor
    private func router(_ appState: AppState) -> CommandRouter {
        makeCommandRouter(
            appState: appState,
            store: JSONStore.temporary(),
            git: GitManager(),
            devRoot: NSTemporaryDirectory(),
            cockpit: nil)
    }

    private func issue(_ number: Int, state: String) -> AssignedIssue {
        AssignedIssue(
            id: "github:corveil/crow#\(number)",
            number: number,
            title: "Issue \(number)",
            state: state,
            url: "https://github.com/corveil/crow/issues/\(number)",
            repo: "corveil/crow",
            provider: .github)
    }

    private func sessions(_ result: [String: JSONValue]?) -> [[String: JSONValue]] {
        (result?["sessions"]?.arrayValue ?? []).compactMap { $0.objectValue }
    }

    @Test @MainActor func emitsClosedAndOpenTicketState() async {
        let appState = AppState()
        let closed = Session(name: "closed-one", ticketURL: "https://github.com/corveil/crow/issues/1")
        let open = Session(name: "open-one", ticketURL: "https://github.com/corveil/crow/issues/2")
        appState.sessions = [closed, open]
        appState.assignedIssues = [issue(1, state: "closed"), issue(2, state: "open")]

        let resp = await router(appState).handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(resp.error == nil)
        let rows = sessions(resp.result)
        let closedRow = rows.first { $0["id"]?.stringValue == closed.id.uuidString }
        let openRow = rows.first { $0["id"]?.stringValue == open.id.uuidString }
        #expect(closedRow?["ticket_state"]?.stringValue == "closed")
        #expect(openRow?["ticket_state"]?.stringValue == "open")
        // No regression to the fields the pill already renders from.
        #expect(closedRow?["ticket_badge"]?.stringValue == "Issue")
        #expect(closedRow?["ticket_url"]?.stringValue == "https://github.com/corveil/crow/issues/1")
    }

    @Test @MainActor func ticketStateIsNullWithoutAMatchingBoardIssue() async {
        let appState = AppState()
        // Linked to a ticket the board doesn't know about, and one with no ticket.
        appState.sessions = [
            Session(name: "unknown-ticket", ticketURL: "https://github.com/corveil/crow/issues/99"),
            Session(name: "no-ticket"),
        ]
        appState.assignedIssues = [issue(1, state: "closed")]

        let resp = await router(appState).handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(resp.error == nil)
        for row in sessions(resp.result) {
            #expect(row["ticket_state"] == JSONValue.null)
        }
    }
}
