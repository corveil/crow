import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import Foundation
import Testing
@testable import CrowDaemon

/// `reorder-manager` permutes extra Managers in the live session array and the
/// store, and refuses to move the primary (CROW-1294). Page reload reads this
/// same array back through `list-sessions`.
@Suite("reorder-manager") struct ReorderManagerRPCTests {
    private let primary = AppState.managerSessionID
    private let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let c = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let work = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!

    @MainActor
    private func seeded() -> (CommandRouter, AppState, JSONStore) {
        let appState = AppState()
        let store = JSONStore.temporary()
        let sessions = [
            Session(id: b, name: "B", kind: .manager),
            Session(id: primary, name: "Primary", kind: .manager),
            Session(id: work, name: "Work", kind: .work),
            Session(id: a, name: "A", kind: .manager),
            Session(id: c, name: "C", kind: .manager),
        ]
        appState.sessions = sessions
        store.mutate { $0.sessions = sessions }
        let router = makeCommandRouter(
            appState: appState, store: store, git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)
        return (router, appState, store)
    }

    private func names(_ sessions: [Session]) -> [String] { sessions.map(\.name) }

    @Test @MainActor func dropAboveAnotherExtraPersistsAndKeepsThePrimary() async {
        let (router, appState, store) = seeded()
        let resp = await router.handle(request: JSONRPCRequest(
            id: 1, method: "reorder-manager",
            params: [
                "session_id": .string(c.uuidString),
                "before_id": .string(b.uuidString),
            ]))
        #expect(resp.error == nil)
        // Extras were B, A, C. C moves to sit immediately before B → C, B, A.
        // Primary stays at index 1. Work stays between the extra slots.
        #expect(names(appState.sessions) == ["C", "Primary", "Work", "B", "A"])
        #expect(names(store.data.sessions) == names(appState.sessions))
        #expect(appState.sessions[1].id == primary)

        let listed = await router.handle(request: JSONRPCRequest(id: 2, method: "list-sessions"))
        let rows = listed.result?["sessions"]?.arrayValue ?? []
        let listedNames = rows.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(listedNames == ["C", "Primary", "Work", "B", "A"])
        let primaryRow = rows.first { $0.objectValue?["name"]?.stringValue == "Primary" }
        let movedRow = rows.first { $0.objectValue?["name"]?.stringValue == "C" }
        #expect(primaryRow?.objectValue?["is_primary_manager"]?.boolValue == true)
        #expect(movedRow?.objectValue?["is_primary_manager"]?.boolValue == false)
        let order = resp.result?["order"]?.arrayValue?.compactMap(\.stringValue)
        #expect(order == [c, b, a].map(\.uuidString))
    }

    @Test @MainActor func dropBelowUsesAfterAndANewManagerStaysLast() async {
        let (router, appState, store) = seeded()
        let resp = await router.handle(request: JSONRPCRequest(
            id: 1, method: "reorder-manager",
            params: [
                "session_id": .string(b.uuidString),
                "after_id": .string(a.uuidString),
            ]))
        #expect(resp.error == nil)
        // B, A, C with B moved to sit after A → A, B, C. C was already last
        // and was not the row being moved, so it stays at the end.
        #expect(names(appState.sessions) == ["A", "Primary", "Work", "B", "C"])
        #expect(names(store.data.sessions) == names(appState.sessions))
    }

    @Test @MainActor func primaryCannotBeMovedOrUsedAsADropTarget() async {
        let (router, appState, _) = seeded()
        let move = await router.handle(request: JSONRPCRequest(
            id: 1, method: "reorder-manager",
            params: [
                "session_id": .string(primary.uuidString),
                "before_id": .string(a.uuidString),
            ]))
        #expect(move.error?.code == RPCErrorCode.applicationError)
        #expect(move.error?.message.contains("cannot be reordered") == true)

        let onto = await router.handle(request: JSONRPCRequest(
            id: 2, method: "reorder-manager",
            params: [
                "session_id": .string(a.uuidString),
                "before_id": .string(primary.uuidString),
            ]))
        #expect(onto.error?.code == RPCErrorCode.applicationError)
        #expect(onto.error?.message.contains("not a drop target") == true)
        #expect(names(appState.sessions) == ["B", "Primary", "Work", "A", "C"])
    }

    @Test @MainActor func workSessionAndMissingAnchorAreRejected() async {
        let (router, appState, _) = seeded()
        let workMove = await router.handle(request: JSONRPCRequest(
            id: 1, method: "reorder-manager",
            params: [
                "session_id": .string(work.uuidString),
                "before_id": .string(a.uuidString),
            ]))
        #expect(workMove.error?.code == RPCErrorCode.applicationError)

        let neither = await router.handle(request: JSONRPCRequest(
            id: 2, method: "reorder-manager",
            params: ["session_id": .string(a.uuidString)]))
        #expect(neither.error?.code == RPCErrorCode.invalidParams)

        let both = await router.handle(request: JSONRPCRequest(
            id: 3, method: "reorder-manager",
            params: [
                "session_id": .string(a.uuidString),
                "before_id": .string(b.uuidString),
                "after_id": .string(c.uuidString),
            ]))
        #expect(both.error?.code == RPCErrorCode.invalidParams)
        #expect(names(appState.sessions) == ["B", "Primary", "Work", "A", "C"])
    }
}
