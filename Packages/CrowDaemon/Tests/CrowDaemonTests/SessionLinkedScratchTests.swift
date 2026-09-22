import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// CROW-1288: a Manager opened from Scratch carries the linked open item on
/// `list-sessions`, so the session header can offer "Mark Scratch Done".
/// Done items are omitted (the control goes away). Work sessions stay bare —
/// `todo work` links them, and that surface already has its own completion actions.
@Suite struct SessionLinkedScratchTests {
    @MainActor
    private func router(_ appState: AppState, store: JSONStore) -> CommandRouter {
        makeCommandRouter(
            appState: appState,
            store: store,
            git: GitManager(),
            devRoot: NSTemporaryDirectory(),
            cockpit: nil)
    }

    private func rows(_ result: [String: JSONValue]?) -> [[String: JSONValue]] {
        (result?["sessions"]?.arrayValue ?? []).compactMap { $0.objectValue }
    }

    @Test @MainActor func managerCarriesTheNewestOpenScratch() async {
        let appState = AppState()
        let store = JSONStore.temporary()
        let manager = Session(name: "from scratch", kind: .manager)
        let plain = Session(name: "unlinked", kind: .manager)
        appState.sessions = [manager, plain]

        let older = TodoItem(
            text: "older note",
            state: .exploring,
            links: [TodoLink(type: .session, sessionID: manager.id, label: "from scratch")],
            updatedAt: Date(timeIntervalSince1970: 10))
        let newer = TodoItem(
            text: "look at the top bar",
            state: .parked,
            links: [TodoLink(type: .session, sessionID: manager.id, label: "from scratch")],
            updatedAt: Date(timeIntervalSince1970: 20))
        let finished = TodoItem(
            text: "already done",
            state: .done,
            links: [TodoLink(type: .session, sessionID: manager.id, label: "from scratch")],
            updatedAt: Date(timeIntervalSince1970: 30))
        let repo = TodoRepository(store: store)
        repo.save(older)
        repo.save(newer)
        repo.save(finished)

        let resp = await router(appState, store: store)
            .handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(resp.error == nil)
        let listed = rows(resp.result)
        let linked = listed.first { $0["id"]?.stringValue == manager.id.uuidString }
        let scratch = linked?["linked_scratch"]?.objectValue
        #expect(scratch?["id"]?.stringValue == newer.id.uuidString)
        #expect(scratch?["text"]?.stringValue == "look at the top bar")
        #expect(scratch?["state"]?.stringValue == "parked")

        let bare = listed.first { $0["id"]?.stringValue == plain.id.uuidString }
        #expect(bare?["linked_scratch"] == nil)
    }

    @Test @MainActor func omitsDoneScratchAndWorkSessions() async {
        let appState = AppState()
        let store = JSONStore.temporary()
        let manager = Session(name: "finished manager", kind: .manager)
        let work = Session(name: "work", kind: .work)
        appState.sessions = [manager, work]

        let repo = TodoRepository(store: store)
        repo.save(TodoItem(
            text: "shipped",
            state: .done,
            links: [TodoLink(type: .session, sessionID: manager.id, label: "finished manager")]))
        repo.save(TodoItem(
            text: "working item",
            state: .working,
            links: [TodoLink(type: .session, sessionID: work.id, label: "work")]))

        let resp = await router(appState, store: store)
            .handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(resp.error == nil)
        for row in rows(resp.result) {
            #expect(row["linked_scratch"] == nil)
        }
    }
}
