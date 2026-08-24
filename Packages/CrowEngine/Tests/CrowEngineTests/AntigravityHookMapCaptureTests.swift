import Foundation
import Testing
@testable import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// CROW-1107: an Antigravity hook records `conversationId → worktree` into the
/// runtime map, and the worktree comes from Crow's **own session ownership** —
/// never the hook payload — so there is no possibility of misattribution. The
/// suite is `.serialized` because the tests share `testMapURLOverride`.
@Suite("antigravity hook conversation map capture", .serialized)
@MainActor
struct AntigravityHookMapCaptureTests {

    private func makeRouter(_ appState: AppState, _ store: JSONStore, devRoot: String) -> CommandRouter {
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        return makeEngineRouter(EngineContext(
            appState: appState, store: store, sessionService: service,
            issueTracker: nil, telemetryPort: nil, devRoot: devRoot,
            hostBridge: NoopHostBridge(), loadConfig: { nil }, applyConfig: { _ in nil }))
    }

    private func makeSessionWithWorktree(_ appState: AppState, under tmp: URL, name: String) -> (Session, String) {
        let session = Session(name: name)
        appState.sessions.append(session)
        let worktreePath = tmp.appendingPathComponent("ws/repo-1").path
        appState.worktrees[session.id] = [
            SessionWorktree(sessionID: session.id, repoName: "repo", repoPath: worktreePath,
                            worktreePath: worktreePath, branch: "feature/x", isPrimary: true),
        ]
        return (session, worktreePath)
    }

    @Test("records the owned worktree, not the payload's workspacePaths")
    func recordsOwnedWorktree() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-agy-capture-\(UUID().uuidString)")
        let mapURL = tmp.appendingPathComponent("map.json")
        AntigravityConversationMap.testMapURLOverride = mapURL
        defer { AntigravityConversationMap.resetForTesting(); try? FileManager.default.removeItem(at: tmp) }

        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let (session, worktreePath) = makeSessionWithWorktree(appState, under: tmp, name: "agy")

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(session.id.uuidString),
                "agent_kind": .string("antigravity"),
                "event_name": .string("PostToolUse"),
                // A payload whose `workspacePaths` point elsewhere — it must be
                // ignored; only `conversationId` is read, and the worktree comes
                // from Crow's session ownership.
                "payload": .object([
                    "conversationId": .string("CONV-XYZ"),
                    "workspacePaths": .array([.string("/attacker/controlled")]),
                    "transcriptPath": .string("/agy/brain/CONV-XYZ/.system_generated/logs/transcript.jsonl"),
                ]),
            ]))
        #expect(response.error == nil)

        let map = AntigravityConversationMap.load(mapURL: mapURL)
        let entry = try #require(map.conversations["CONV-XYZ"])
        #expect(entry.worktreePath == worktreePath)          // from ownership …
        #expect(entry.worktreePath != "/attacker/controlled") // … NOT the payload
        #expect(entry.transcriptPath == "/agy/brain/CONV-XYZ/.system_generated/logs/transcript.jsonl")
    }

    @Test("a non-antigravity hook records nothing")
    func nonAntigravityRecordsNothing() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-agy-capture-\(UUID().uuidString)")
        let mapURL = tmp.appendingPathComponent("map.json")
        AntigravityConversationMap.testMapURLOverride = mapURL
        defer { AntigravityConversationMap.resetForTesting(); try? FileManager.default.removeItem(at: tmp) }

        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let (session, _) = makeSessionWithWorktree(appState, under: tmp, name: "claude")

        let router = makeRouter(appState, store, devRoot: tmp.path)
        _ = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(session.id.uuidString),
                "agent_kind": .string("claude-code"),
                "event_name": .string("PostToolUse"),
                "payload": .object(["conversationId": .string("CONV-XYZ")]),
            ]))
        #expect(AntigravityConversationMap.load(mapURL: mapURL).conversations.isEmpty)
    }
}
