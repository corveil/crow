import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import CrowEngine
@testable import CrowDaemon

/// End-to-end coverage of the `todo-*` handlers (CROW-1231) against a real
/// injected `JSONStore`. Promotion verbs that need tmux or a provider are
/// asserted only for their missing-capability errors here.
@Suite struct TodoHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-todo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func harness() -> (CommandRouter, JSONStore) {
        let store = JSONStore.temporary()
        let router = makeCommandRouter(
            appState: AppState(), store: store, git: GitManager(),
            devRoot: tempDevRoot(), cockpit: nil)
        return (router, store)
    }

    @MainActor
    private func call(
        _ router: CommandRouter, _ method: String, _ params: [String: JSONValue] = [:]
    ) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    @Test @MainActor func addListGetEditDoneReopen() async throws {
        let (router, store) = harness()

        let added = await call(router, "todo-add", [
            "text": .string("native scratch"),
            "note": .string("before a ticket"),
            "tags": .array([.string("crow")]),
            "priority": .string("p2"),
        ])
        let id = try #require(added.result?["todo"]?.objectValue?["id"]?.stringValue)
        #expect(added.result?["todo"]?.objectValue?["state"]?.stringValue == "captured")
        #expect(store.data.todos?.count == 1)

        let listed = await call(router, "todo-list")
        #expect(listed.result?["todos"]?.arrayValue?.count == 1)

        let got = await call(router, "todo-get", ["todo_id": .string(id)])
        #expect(got.result?["todo"]?.objectValue?["text"]?.stringValue == "native scratch")

        let edited = await call(router, "todo-edit", [
            "todo_id": .string(id),
            "text": .string("changed"),
            "add_tags": .array([.string("cli")]),
        ])
        #expect(edited.result?["todo"]?.objectValue?["text"]?.stringValue == "changed")

        let done = await call(router, "todo-done", ["todo_id": .string(id)])
        #expect(done.result?["todo"]?.objectValue?["state"]?.stringValue == "done")

        let reopened = await call(router, "todo-reopen", ["todo_id": .string(id)])
        #expect(reopened.result?["todo"]?.objectValue?["state"]?.stringValue == "captured")
    }

    @Test @MainActor func parkDropDeleteAndLink() async throws {
        let (router, _) = harness()
        let added = await call(router, "todo-add", ["text": .string("park me")])
        let id = try #require(added.result?["todo"]?.objectValue?["id"]?.stringValue)

        #expect((await call(router, "todo-park", ["todo_id": .string(id)]))
            .result?["todo"]?.objectValue?["state"]?.stringValue == "parked")
        #expect((await call(router, "todo-drop", ["todo_id": .string(id)]))
            .result?["todo"]?.objectValue?["state"]?.stringValue == "dropped")

        let sessionID = UUID().uuidString
        let linked = await call(router, "todo-link", [
            "todo_id": .string(id),
            "type": .string("session"),
            "session_id": .string(sessionID),
            "label": .string("explore"),
        ])
        let links = linked.result?["todo"]?.objectValue?["links"]?.arrayValue ?? []
        #expect(links.count == 1)
        #expect(links.first?.objectValue?["session_id"]?.stringValue == sessionID)

        let deleted = await call(router, "todo-delete", ["todo_id": .string(id)])
        #expect(deleted.result?["deleted"]?.boolValue == true)
        let listed = await call(router, "todo-list")
        #expect(listed.result?["todos"]?.arrayValue?.isEmpty == true)
    }

    @Test @MainActor func exploreWithoutTmuxErrors() async {
        let (router, _) = harness()
        let added = await call(router, "todo-add", ["text": .string("explore me")])
        let id = added.result?["todo"]?.objectValue?["id"]?.stringValue ?? ""
        let resp = await call(router, "todo-explore", ["todo_id": .string(id)])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("tmux") == true)
    }

    @Test @MainActor func workWithoutTicketErrors() async {
        let (router, _) = harness()
        let added = await call(router, "todo-add", ["text": .string("no ticket")])
        let id = added.result?["todo"]?.objectValue?["id"]?.stringValue ?? ""
        let resp = await call(router, "todo-work", ["todo_id": .string(id)])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("ticket") == true)
    }

    @Test @MainActor func talkWithoutExploreErrors() async {
        let (router, _) = harness()
        let added = await call(router, "todo-add", ["text": .string("no manager")])
        let id = added.result?["todo"]?.objectValue?["id"]?.stringValue ?? ""
        let resp = await call(router, "todo-talk", [
            "todo_id": .string(id),
            "text": .string("hello"),
        ])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("Explore") == true)
    }

    @Test @MainActor func missingTodoIsAnError() async {
        let (router, _) = harness()
        let resp = await call(router, "todo-get", ["todo_id": .string(UUID().uuidString)])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("not found") == true)
    }

    @Test @MainActor func listFiltersByState() async throws {
        let (router, _) = harness()
        _ = await call(router, "todo-add", ["text": .string("open")])
        let parked = await call(router, "todo-add", ["text": .string("later")])
        let id = try #require(parked.result?["todo"]?.objectValue?["id"]?.stringValue)
        _ = await call(router, "todo-park", ["todo_id": .string(id)])

        let filtered = await call(router, "todo-list", ["state": .string("parked")])
        #expect(filtered.result?["todos"]?.arrayValue?.count == 1)
        #expect(filtered.result?["todos"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "later")
    }
}
