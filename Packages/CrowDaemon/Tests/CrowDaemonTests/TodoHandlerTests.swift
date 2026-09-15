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

    @Test @MainActor func ticketWhenAlreadyLinkedDoesNotFileAgain() async {
        let (router, _) = harness()
        let added = await call(router, "todo-add", ["text": .string("already filed")])
        let id = added.result?["todo"]?.objectValue?["id"]?.stringValue ?? ""
        _ = await call(router, "todo-link", [
            "todo_id": .string(id),
            "type": .string("ticket"),
            "url": .string("https://github.com/corveil/crow/issues/1"),
        ])
        let resp = await call(router, "todo-ticket", [
            "todo_id": .string(id),
            "workspace": .string("Corveil"),
        ])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("already has a ticket") == true)
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

    // MARK: - Ticket filing (CROW-1259)

    @MainActor
    private func ticketHarness(
        config: AppConfig,
        createTask: (@Sendable (String, String, String) async throws -> (url: String, number: Int))? = nil,
        listWorkspaceRepos: (@Sendable (WorkspaceInfo) async -> WorkspaceRepoListing)? = nil
    ) throws -> (CommandRouter, String) {
        let devRoot = tempDevRoot()
        try ConfigStore.saveConfig(config, devRoot: devRoot)
        let store = JSONStore.temporary()
        let handlers = makeTodoHandlers(
            appState: AppState(), store: store, sessionService: nil, devRoot: devRoot,
            createTask: createTask, listWorkspaceRepos: listWorkspaceRepos)
        return (CommandRouter(handlers: handlers), devRoot)
    }

    @Test @MainActor func ticketGlobOnlySucceedsWhenRepoIsSupplied() async throws {
        let (router, devRoot) = try ticketHarness(
            config: AppConfig(workspaces: [
                WorkspaceInfo(name: "corveil", alwaysInclude: ["corveil/*"]),
            ]),
            createTask: { repo, _, _ in
                #expect(repo == "corveil/crow")
                return (url: "https://github.com/corveil/crow/issues/1259", number: 1259)
            })
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let added = await call(router, "todo-add", ["text": .string("scratch ticket dropdown")])
        let id = try #require(added.result?["todo"]?.objectValue?["id"]?.stringValue)
        let resp = await call(router, "todo-ticket", [
            "todo_id": .string(id),
            "workspace": .string("corveil"),
            "repo": .string("corveil/crow"),
        ])
        #expect(resp.error == nil)
        #expect(resp.result?["ticket_url"]?.stringValue
            == "https://github.com/corveil/crow/issues/1259")
        #expect(resp.result?["todo"]?.objectValue?["state"]?.stringValue == "ticketed")
    }

    @Test @MainActor func ticketGlobOnlyWithoutRepoStillRequiresIt() async throws {
        let (router, devRoot) = try ticketHarness(
            config: AppConfig(workspaces: [
                WorkspaceInfo(name: "corveil", alwaysInclude: ["corveil/*"]),
            ]),
            createTask: { _, _, _ in
                Issue.record("must not file when repo is missing")
                return (url: "https://example.invalid/1", number: 1)
            })
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let added = await call(router, "todo-add", ["text": .string("needs a repo")])
        let id = try #require(added.result?["todo"]?.objectValue?["id"]?.stringValue)
        let resp = await call(router, "todo-ticket", [
            "todo_id": .string(id),
            "workspace": .string("corveil"),
        ])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("repo is required") == true)
    }

    @Test @MainActor func ticketUnmatchedRepoRefuses() async throws {
        let (router, devRoot) = try ticketHarness(
            config: AppConfig(workspaces: [
                WorkspaceInfo(name: "corveil", alwaysInclude: ["corveil/*"]),
            ]))
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let added = await call(router, "todo-add", ["text": .string("stranger")])
        let id = try #require(added.result?["todo"]?.objectValue?["id"]?.stringValue)
        let resp = await call(router, "todo-ticket", [
            "todo_id": .string(id),
            "workspace": .string("corveil"),
            "repo": .string("stranger/repo"),
        ])
        #expect(resp.error != nil)
        #expect(resp.error?.message.contains("no workspace matches repo") == true)
    }

    @Test @MainActor func listWorkspaceReposExpandsGlobsAndStampsWorkspace() async throws {
        let (router, devRoot) = try ticketHarness(
            config: AppConfig(workspaces: [
                WorkspaceInfo(name: "corveil", alwaysInclude: ["corveil/*"]),
                WorkspaceInfo(name: "Acme", alwaysInclude: ["acme/widget"]),
            ]),
            listWorkspaceRepos: { workspace in
                if workspace.name == "corveil" {
                    return WorkspaceRepoListing(
                        repos: ["corveil/crow", "corveil/corveil"], invalidSpecs: [])
                }
                return WorkspaceRepoListing(repos: workspace.alwaysInclude, invalidSpecs: [])
            })
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call(router, "list-workspace-repos")
        let repos = resp.result?["repos"]?.arrayValue ?? []
        let slugs = repos.compactMap { $0.objectValue?["slug"]?.stringValue }
        #expect(slugs.contains("corveil/crow"))
        #expect(slugs.contains("acme/widget"))
        let crow = repos.first { $0.objectValue?["slug"]?.stringValue == "corveil/crow" }
        #expect(crow?.objectValue?["workspace"]?.stringValue == "corveil")
        #expect(resp.result?["count"]?.intValue == slugs.count)
    }

    @Test @MainActor func listWorkspaceReposDropsSlugsThatMatchNoWorkspace() async throws {
        let (router, devRoot) = try ticketHarness(
            config: AppConfig(workspaces: [
                WorkspaceInfo(name: "Acme", alwaysInclude: ["acme/widget"]),
            ]),
            listWorkspaceRepos: { _ in
                WorkspaceRepoListing(repos: ["acme/widget", "stranger/repo"], invalidSpecs: [])
            })
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call(router, "list-workspace-repos")
        let slugs = (resp.result?["repos"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["slug"]?.stringValue }
        #expect(slugs == ["acme/widget"])
    }
}
