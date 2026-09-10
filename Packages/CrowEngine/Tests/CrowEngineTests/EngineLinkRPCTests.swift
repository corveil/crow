import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// CROW-1220: `add-link --type pr` must not stack extras. Automation uses
/// `links.first(where: { $0.linkType == .pr })` (#946).
@Suite("add-link idempotency")
@MainActor
struct EngineLinkRPCTests {
    private func harness() throws -> (CommandRouter, AppState, JSONStore, UUID) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-add-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        let session = Session(name: "link-idempotency")
        appState.sessions.append(session)
        let ctx = EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: tmp.path,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        )
        return (makeEngineRouter(ctx), appState, store, session.id)
    }

    private func add(
        _ router: CommandRouter,
        sessionID: UUID,
        label: String,
        url: String,
        type: String
    ) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(
            id: 1, method: "add-link",
            params: [
                "session_id": .string(sessionID.uuidString),
                "label": .string(label),
                "url": .string(url),
                "type": .string(type),
            ]))
    }

    @Test("first PR link is stored")
    func firstPRIsStored() async throws {
        let (router, appState, _, sessionID) = try harness()
        let url = "https://github.com/corveil/crow/pull/1220"
        let response = await add(router, sessionID: sessionID, label: "PR #1220", url: url, type: "pr")
        #expect(response.error == nil)
        #expect(response.result?["skipped"] == .bool(false))
        let id = try #require(response.result?["link_id"]?.stringValue)
        #expect(UUID(uuidString: id) != nil)
        let links = appState.links(for: sessionID)
        #expect(links.count == 1)
        #expect(links[0].linkType == .pr)
        #expect(links[0].url == url)
    }

    @Test("same PR URL is skipped")
    func duplicateURLIsSkipped() async throws {
        let (router, appState, _, sessionID) = try harness()
        let url = "https://github.com/corveil/crow/pull/1220"
        let first = await add(router, sessionID: sessionID, label: "PR #1220", url: url, type: "pr")
        let firstID = try #require(first.result?["link_id"]?.stringValue)
        let second = await add(router, sessionID: sessionID, label: "PR #1220 again", url: url, type: "pr")
        #expect(second.error == nil)
        #expect(second.result?["skipped"] == .bool(true))
        #expect(second.result?["link_id"]?.stringValue == firstID)
        #expect(appState.links(for: sessionID).count == 1)
    }

    @Test("a second PR URL is skipped when a .pr already exists")
    func secondPRTypeIsSkipped() async throws {
        let (router, appState, _, sessionID) = try harness()
        let first = await add(
            router, sessionID: sessionID, label: "PR #1",
            url: "https://github.com/corveil/crow/pull/1", type: "pr")
        let firstID = try #require(first.result?["link_id"]?.stringValue)
        let second = await add(
            router, sessionID: sessionID, label: "PR #2",
            url: "https://github.com/corveil/crow/pull/2", type: "pr")
        #expect(second.result?["skipped"] == .bool(true))
        #expect(second.result?["link_id"]?.stringValue == firstID)
        #expect(appState.links(for: sessionID).count == 1)
        #expect(appState.links(for: sessionID)[0].url == "https://github.com/corveil/crow/pull/1")
    }

    @Test("non-PR links with distinct URLs still append")
    func customLinksAreNotCollapsed() async throws {
        let (router, appState, _, sessionID) = try harness()
        let a = await add(
            router, sessionID: sessionID, label: "Docs",
            url: "https://example.com/a", type: "custom")
        let b = await add(
            router, sessionID: sessionID, label: "Other",
            url: "https://example.com/b", type: "custom")
        #expect(a.result?["skipped"] == .bool(false))
        #expect(b.result?["skipped"] == .bool(false))
        #expect(appState.links(for: sessionID).count == 2)
    }

    @Test("duplicate URL of any type is skipped")
    func duplicateCustomURLIsSkipped() async throws {
        let (router, appState, _, sessionID) = try harness()
        let url = "https://example.com/same"
        let first = await add(router, sessionID: sessionID, label: "A", url: url, type: "custom")
        let firstID = try #require(first.result?["link_id"]?.stringValue)
        let second = await add(router, sessionID: sessionID, label: "B", url: url, type: "ticket")
        #expect(second.result?["skipped"] == .bool(true))
        #expect(second.result?["link_id"]?.stringValue == firstID)
        #expect(appState.links(for: sessionID).count == 1)
    }
}
