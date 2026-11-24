import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// The Chat view's RPCs through the real engine router. Session folders are
/// temp directories; nothing reads a live transcript (ADR 0012).
@Suite("Chat RPCs")
@MainActor
struct ChatRPCTests {
    private struct Fixture {
        let appState: AppState
        let router: CommandRouter
        let tmp: URL
    }

    private func fixture() throws -> Fixture {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-chat-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        let ctx = EngineContext(
            appState: appState, store: store, sessionService: service, issueTracker: nil,
            telemetryPort: nil, devRoot: tmp.path, hostBridge: NoopHostBridge(),
            loadConfig: { nil }, applyConfig: { _ in nil })
        return Fixture(appState: appState, router: makeEngineRouter(ctx), tmp: tmp)
    }

    /// A session whose primary worktree is a temp dir holding one project skill.
    private func addSession(
        _ f: Fixture, kind: SessionKind, agent: AgentKind = .claudeCode, skill: String
    ) throws -> Session {
        let session = Session(name: "chat-\(kind.rawValue)", kind: kind, agentKind: agent)
        let dir = f.tmp.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let skillDir = dir.appendingPathComponent(".claude/skills/\(skill)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try Data("---\ndescription: project skill\n---\n".utf8)
            .write(to: skillDir.appendingPathComponent("SKILL.md"))
        f.appState.sessions.append(session)
        f.appState.worktrees[session.id] = [
            SessionWorktree(sessionID: session.id, repoName: "repo", repoPath: dir.path,
                            worktreePath: dir.path, branch: "feature/x", isPrimary: true),
        ]
        return session
    }

    private func call(_ f: Fixture, _ method: String, _ session: Session) async -> JSONRPCResponse {
        await f.router.handle(request: JSONRPCRequest(
            id: 1, method: method, params: ["session_id": .string(session.id.uuidString)]))
    }

    private func names(_ r: JSONRPCResponse) -> [String] {
        guard case .array(let items)? = r.result?["commands"] else { return [] }
        return items.compactMap { item in
            if case .object(let o) = item, case .string(let n)? = o["name"] { return n }
            return nil
        }
    }

    @Test("list-chat-commands hides a review worktree's project skills")
    func reviewSessionsListNoProjectCommands() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let marker = "crow-test-skill-\(UUID().uuidString.prefix(8).lowercased())"
        let work = try addSession(f, kind: .work, skill: marker)
        let review = try addSession(f, kind: .review, skill: marker)

        let workNames = names(await call(f, "list-chat-commands", work))
        let reviewNames = names(await call(f, "list-chat-commands", review))
        #expect(workNames.contains(marker))
        #expect(!reviewNames.contains(marker))
        #expect(reviewNames.contains("compact"))
    }

    @Test("list-chat-commands is Claude-only")
    func commandsAreClaudeOnly() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let codex = try addSession(f, kind: .work, agent: .codex, skill: "x")
        let r = await call(f, "list-chat-commands", codex)
        #expect(r.result?["supported"] == .bool(false))
        #expect(names(r).isEmpty)
    }

    @Test("get-session-transcript explains an unsupported harness instead of failing")
    func transcriptForUnsupportedHarness() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let cursor = try addSession(f, kind: .work, agent: .cursor, skill: "x")
        let r = await call(f, "get-session-transcript", cursor)
        #expect(r.error == nil)
        #expect(r.result?["supported"] == .bool(false))
        #expect(r.result?["events"] == .array([]))
        #expect(r.result?["driver"] == nil)
    }

    // MARK: answer-question (CROW-1512)

    /// A Claude session whose agent terminal's cwd maps to a temp projects dir
    /// holding `transcript`, plus handlers wired to `picker`.
    private func questionFixture(
        _ f: Fixture, transcript: String, picker: AskUserQuestionDriverTests.FakePicker,
        agent: AgentKind = .claudeCode
    ) throws -> (Session, [String: CommandRouter.Handler]) {
        let session = Session(name: "ask", kind: .work, agentKind: agent)
        let cwd = f.tmp.appendingPathComponent("wt-\(session.id.uuidString)").path
        let projects = f.tmp.appendingPathComponent("projects", isDirectory: true)
        let dir = projects.appendingPathComponent(AgentLogSource.posixPathSlug(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(transcript.utf8).write(to: dir.appendingPathComponent("conv.jsonl"))
        f.appState.sessions.append(session)
        f.appState.terminals[session.id] = [
            SessionTerminal(sessionID: session.id, name: "Claude Code", cwd: cwd, isManaged: true),
        ]
        var roots = HarnessTranscriptLocator.Roots.live
        roots.claudeProjectsDir = projects.path
        return (session, makeEngineChatHandlers(appState: f.appState, questionIO: picker.io, transcriptRoots: roots))
    }

    private static let petCall = #"""
    {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_pet","name":"AskUserQuestion","input":{"questions":[{"question":"Which pet?","header":"Pet","multiSelect":false,"options":[{"label":"Cat","description":"meow"},{"label":"Dog","description":"woof"}]}]}}]}}

    """#

    private func answer(
        _ handlers: [String: CommandRouter.Handler], _ session: Session, _ answers: JSONValue,
        tool: String = "toolu_pet"
    ) async throws -> [String: JSONValue] {
        try await handlers["answer-question"]!([
            "session_id": .string(session.id.uuidString), "tool_id": .string(tool), "answers": answers,
        ])
    }

    @Test("answer-question plans the keys against the transcript's questions")
    func answerQuestionTypesIntoThePicker() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let picker = AskUserQuestionDriverTests.FakePicker([AskUserQuestionDriverTests.pet])
        let (session, handlers) = try questionFixture(f, transcript: Self.petCall, picker: picker)
        let r = try await answer(handlers, session, .array([.object(["selected": .array([.int(1)])])]))
        #expect(r["delivered"] == .string("picker"))
        #expect(picker.answers == ["Which pet?": "Dog"])
    }

    @Test("answer-question refuses an answered call, a bad answer, and other harnesses")
    func answerQuestionGuards() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let answered = Self.petCall + #"""
        {"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"ok","tool_use_id":"toolu_pet"}]},"toolUseResult":{"answers":{"Which pet?":"Cat"}}}

        """#
        let picker = AskUserQuestionDriverTests.FakePicker([AskUserQuestionDriverTests.pet])
        let one: JSONValue = .array([.object(["selected": .array([.int(0)])])])

        let (s1, h1) = try questionFixture(f, transcript: answered, picker: picker)
        await #expect(throws: RPCError.self) { _ = try await self.answer(h1, s1, one) }

        let (s2, h2) = try questionFixture(f, transcript: Self.petCall, picker: picker)
        await #expect(throws: RPCError.self) { _ = try await self.answer(h2, s2, .array([.object(["selected": .array([.int(5)])])])) }
        await #expect(throws: RPCError.self) { _ = try await self.answer(h2, s2, one, tool: "toolu_missing") }

        let (s3, h3) = try questionFixture(f, transcript: Self.petCall, picker: picker, agent: .codex)
        await #expect(throws: RPCError.self) { _ = try await self.answer(h3, s3, one) }
        #expect(picker.keys.isEmpty)
    }
}
