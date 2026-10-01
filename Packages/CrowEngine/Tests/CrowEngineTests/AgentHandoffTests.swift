import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import CrowEngine

@Suite("AgentHandoff prompt")
struct AgentHandoffPromptTests {
    private final class SpyHookConfigWriter: HookConfigWriter, @unchecked Sendable {
        func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws {}
        func removeHookConfig(worktreePath: String) {}
    }

    private struct NoopStateSignalSource: StateSignalSource {
        func transition(
            for event: AgentHookEvent,
            currentActivityState: AgentActivityState,
            currentNotificationType: String?,
            currentLastTopLevelStopAt: Date?
        ) -> AgentStateTransition { AgentStateTransition() }
    }

    private struct StubAgent: CodingAgent {
        let kind: AgentKind
        var displayName: String { kind.rawValue }
        var iconSystemName: String { "sparkles" }
        var supportsRemoteControl: Bool { false }
        var launchCommandToken: String { kind.rawValue }
        let hookConfigWriter: any HookConfigWriter = SpyHookConfigWriter()
        let stateSignalSource: any StateSignalSource = NoopStateSignalSource()
        func findBinary() -> String? { "/usr/bin/true" }
        func autoLaunchCommand(
            session: Session,
            worktreePath: String,
            remoteControlEnabled: Bool,
            autoPermissionMode: Bool,
            telemetryPort: UInt16?
        ) -> String? { nil }
        func generatePrompt(
            session: Session,
            worktrees: [SessionWorktree],
            ticketURL: String?,
            provider: Provider?,
            codeProvider: Provider?
        ) async -> String {
            "# Workspace Context\n\n| Repository | Path | Branch | Description |\n"
        }
        func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) async throws -> String {
            "agent \"\(prompt.prefix(20))\"\n"
        }
        func managerLaunchCommand(
            sessionName: String,
            remoteControlEnabled: Bool,
            autoPermissionMode: Bool,
            telemetryPort: UInt16?,
            conversationID: String?
        ) -> String { launchCommandToken }
    }

    @Test func buildPromptIncludesHandoffHeaderAndNote() async {
        let target = StubAgent(kind: .cursor)
        let session = Session(
            name: "crow-627",
            kind: .work,
            agentKind: .claudeCode,
            ticketURL: "https://github.com/corveil/crow/issues/627"
        )
        let wt = SessionWorktree(
            sessionID: session.id,
            repoName: "crow",
            repoPath: "/tmp/crow",
            worktreePath: "/tmp/crow-wt",
            branch: "feature/crow-627",
            isPrimary: true
        )
        let prompt = await AgentHandoff.buildPrompt(
            from: .claudeCode,
            to: target,
            session: session,
            worktrees: [wt],
            note: "Stopped mid-implement; continue from SessionService"
        )
        #expect(prompt.contains("# Agent Handoff"))
        #expect(prompt.contains("Claude Code") || prompt.contains("claude-code"))
        #expect(prompt.contains("## Handoff note"))
        #expect(prompt.contains("Stopped mid-implement"))
        #expect(prompt.contains("# Workspace Context"))
        #expect(prompt.contains("git status"))
    }

    @Test func buildPromptOmitsNoteSectionWhenEmpty() async {
        let target = StubAgent(kind: .codex)
        let session = Session(name: "s", kind: .work, agentKind: .cursor)
        let prompt = await AgentHandoff.buildPrompt(
            from: .cursor,
            to: target,
            session: session,
            worktrees: [],
            note: "   "
        )
        #expect(prompt.contains("# Agent Handoff"))
        #expect(!prompt.contains("## Handoff note"))
    }
}

@Suite("AgentHandoff Manager prompt (CROW-1283)")
struct AgentHandoffManagerPromptTests {
    @Test func managerBriefNamesPriorAgentAndOrchestration() {
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .claudeCode,
            to: .cursor,
            note: "Handing off — continue the review sweep",
            devRoot: "/Users/dev/root"
        )
        // Manager-specific brief, NOT the worktree git brief.
        #expect(prompt.contains("# Manager Agent Handoff"))
        #expect(prompt.contains("Claude Code") || prompt.contains("claude-code"))
        #expect(prompt.contains("orchestration"))
        #expect(prompt.contains("crow"))
        #expect(prompt.contains("/Users/dev/root"))
        #expect(prompt.contains("## Handoff note"))
        #expect(prompt.contains("continue the review sweep"))
        // The worktree brief's git orientation must not leak into a Manager
        // handoff — a Manager has no worktree to inspect.
        #expect(!prompt.contains("git status"))
        #expect(!prompt.contains("# Workspace Context"))
    }

    @Test func managerBriefOmitsNoteAndDevRootWhenAbsent() {
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .cursor, to: .claudeCode, note: "   ", devRoot: nil)
        #expect(prompt.contains("# Manager Agent Handoff"))
        #expect(!prompt.contains("## Handoff note"))
        #expect(!prompt.contains("Dev root:"))
        // Empty context omits every optional section (CROW-1314).
        #expect(!prompt.contains("## Session"))
        #expect(!prompt.contains("## Originating Scratch item"))
        #expect(!prompt.contains("## Prior agent transcript"))
        #expect(!prompt.contains("## Recent terminal scrollback"))
        #expect(!prompt.contains("git status"))
    }

    @Test func managerBriefIncludesSessionTicketAndLinks() {
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .claudeCode, to: .cursor, note: nil, devRoot: "/dev",
            context: ManagerHandoffContext(
                sessionName: "PacVue",
                ticketURL: "https://github.com/corveil/crow/issues/1314",
                ticketTitle: "Manager handoff context",
                links: [
                    ManagerHandoffLink(
                        label: "Issue #1314",
                        url: "https://github.com/corveil/crow/issues/1314",
                        type: "ticket"),
                ]
            ))
        #expect(prompt.contains("## Session"))
        #expect(prompt.contains("Name: PacVue"))
        #expect(prompt.contains("Ticket: Manager handoff context — https://github.com/corveil/crow/issues/1314"))
        #expect(prompt.contains("Issue #1314 (ticket): https://github.com/corveil/crow/issues/1314"))
    }

    @Test func managerBriefIncludesOriginatingScratchAndCapsIt() {
        let huge = String(repeating: "a", count: AgentHandoff.scratchTextMaxCharacters + 40)
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .grok, to: .cursor, note: nil, devRoot: nil,
            context: ManagerHandoffContext(
                scratch: ManagerHandoffScratch(
                    text: huge,
                    note: "Look at the identity directory.",
                    tags: ["handoff", "manager"],
                    state: "exploring")
            ))
        #expect(prompt.contains("## Originating Scratch item"))
        #expect(prompt.contains("State: exploring"))
        #expect(prompt.contains("### Notes"))
        #expect(prompt.contains("Look at the identity directory."))
        #expect(prompt.contains("Tags: handoff, manager"))
        #expect(prompt.contains("…"))
        #expect(!prompt.contains(huge))
    }

    @Test func managerBriefOmitsBlankScratch() {
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .cursor, to: .claudeCode, note: nil, devRoot: nil,
            context: ManagerHandoffContext(
                scratch: ManagerHandoffScratch(text: "  ", note: "", tags: [" "], state: "exploring")
            ))
        #expect(!prompt.contains("## Originating Scratch item"))
    }

    @Test func originatingScratchMatchesLinkedSession() {
        let sessionID = UUID()
        let other = UUID()
        let older = TodoItem(
            text: "older ask",
            state: .exploring,
            links: [TodoLink(type: .session, sessionID: sessionID, label: "Manager")],
            updatedAt: Date(timeIntervalSince1970: 1))
        let newer = TodoItem(
            text: "switch agent should resume",
            note: "from the prior agent",
            tags: ["crow"],
            state: .ticketed,
            links: [TodoLink(type: .session, sessionID: sessionID, label: "Manager")],
            updatedAt: Date(timeIntervalSince1970: 10))
        let unrelated = TodoItem(
            text: "someone else",
            links: [TodoLink(type: .session, sessionID: other, label: "Other")])
        let scratch = AgentHandoff.originatingScratch(
            in: [older, unrelated, newer], sessionID: sessionID)
        #expect(scratch?.text == "switch agent should resume")
        #expect(scratch?.note == "from the prior agent")
        #expect(scratch?.tags == ["crow"])
        #expect(scratch?.state == "ticketed")
        #expect(AgentHandoff.originatingScratch(in: [unrelated], sessionID: sessionID) == nil)
        #expect(AgentHandoff.originatingScratch(in: nil, sessionID: sessionID) == nil)
    }

    @Test func managerBriefPointsAtTranscript() {
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .claudeCode, to: .cursor, note: nil, devRoot: nil,
            context: ManagerHandoffContext(
                transcriptPath: "/Users/dev/.claude/projects/-Users-dev/.jsonl"
            ))
        #expect(prompt.contains("## Prior agent transcript"))
        #expect(prompt.contains("Read this file to see where the previous agent left off:"))
        #expect(prompt.contains("/Users/dev/.claude/projects/-Users-dev/.jsonl"))
    }

    @Test func managerBriefIncludesScrollbackTailAndCapsLines() {
        let total = AgentHandoff.scrollbackMaxLines + 40
        let lines = (0..<total).map { "LINE-\($0)" }
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .cursor, to: .grok, note: nil, devRoot: nil,
            context: ManagerHandoffContext(scrollback: lines.joined(separator: "\n") + "\n\n")
        )
        let firstKept = total - AgentHandoff.scrollbackMaxLines
        #expect(prompt.contains("## Recent terminal scrollback"))
        #expect(prompt.contains("Last lines from the previous agent's pane:"))
        #expect(prompt.contains("LINE-\(total - 1)"))
        #expect(prompt.contains("LINE-\(firstKept)"))
        #expect(!prompt.contains("LINE-\(firstKept - 1)"))
        #expect(!prompt.contains("LINE-0"))
    }

    @Test func managerBriefOmitsBlankScrollback() {
        let prompt = AgentHandoff.buildManagerPrompt(
            from: .cursor, to: .claudeCode, note: nil, devRoot: nil,
            context: ManagerHandoffContext(scrollback: "  \n\t\n  ")
        )
        #expect(!prompt.contains("## Recent terminal scrollback"))
    }

    /// The primary Manager (fixed id) is the only Manager refused handoff; any
    /// other Manager id is an extra Manager that hands off (CROW-1283).
    @Test func onlyPrimaryManagerIdIsFixed() {
        #expect(AppState.managerSessionID == UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let extra = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        #expect(extra.id != AppState.managerSessionID)
        #expect(extra.isManager)
    }
}

@Suite("Extra Manager handoff panes (CROW-1297)")
struct ExtraManagerHandoffPaneTests {
    /// The regression: `createManagerTerminal` builds the agent row with a
    /// launch command and the default `isManaged: false`. Filtering teardown
    /// on `isManaged` kept that pane and appended a second window.
    @Test func replacesUnmanagedAgentPaneAndKeepsCommandlessShell() {
        let session = Session(name: "Manager 2", kind: .manager, agentKind: .cursor)
        let agent = SessionTerminal(
            sessionID: session.id, name: session.name, cwd: "/dev/root",
            command: "cursor-agent")
        let shell = SessionTerminal(
            sessionID: session.id, name: "Shell", cwd: "/dev/root")
        #expect(!agent.isManaged)
        #expect(agent.isAgentSurface(session: session))
        #expect(shell.command == nil)
        #expect(!shell.isAgentSurface(session: session))

        let (replace, keep) = ManagerSessionController.extraManagerHandoffSplit(
            terminals: [agent, shell], session: session)
        #expect(replace.map(\.id) == [agent.id])
        #expect(keep.map(\.id) == [shell.id])
    }

    /// `isAgentSurface` also matches a managed row. A command-less Shell does
    /// not, even when it sits beside one.
    @Test func managedRowIsReplacedAndCommandlessShellIsKept() {
        let session = Session(name: "Manager 2", kind: .manager, agentKind: .grok)
        let managed = SessionTerminal(
            sessionID: session.id, name: "Agent", cwd: "/identity",
            command: nil, isManaged: true)
        let shell = SessionTerminal(
            sessionID: session.id, name: "Shell", cwd: "/identity")
        let (replace, keep) = ManagerSessionController.extraManagerHandoffSplit(
            terminals: [shell, managed], session: session)
        #expect(replace.map(\.id) == [managed.id])
        #expect(keep.map(\.id) == [shell.id])
    }

    /// The primary Manager stays on Settings + `restartManager`. The refusal
    /// is the id check, before any agent binary lookup.
    @MainActor
    @Test func primaryManagerHandoffIsRefused() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-handoff-primary-\(UUID().uuidString)")
        let appState = AppState()
        let service = SessionService(
            store: JSONStore(directory: tmp), appState: appState, hostBridge: NoopHostBridge())
        let primary = Session(
            id: AppState.managerSessionID, name: "Manager",
            kind: .manager, agentKind: .cursor)
        appState.sessions.append(primary)
        await #expect(throws: AgentHandoffError.managerNotSupported) {
            try await service.handoffAgent(sessionID: primary.id, to: .grok)
        }
    }
}

@Suite("Harness transcript locator (CROW-1314)")
struct HarnessTranscriptLocatorTests {
    private func roots(in dir: URL) -> HarnessTranscriptLocator.Roots {
        HarnessTranscriptLocator.Roots(
            claudeProjectsDir: dir.appendingPathComponent("claude").path,
            grokSessionsDir: dir.appendingPathComponent("grok").path,
            codexSessionsDir: dir.appendingPathComponent("codex").path,
            antigravityBrainDir: dir.appendingPathComponent("agy").path,
            museSessionsDir: dir.appendingPathComponent("muse").path
        )
    }

    /// `/var` and `/private/var` are the same file. Directory listings
    /// realpath the temp dir; `URL` built from `NSTemporaryDirectory()` may not.
    private func sameFile(_ found: String?, _ expected: String) -> Bool {
        guard let found else { return false }
        let a = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        return a == b
    }

    private func write(_ path: String, _ body: String = "{}\n") throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func claudePathUsesProjectSlugAndOmitsAMissingFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1314-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cwd = "/Users/dev/.crow/managers/ABC"
        let slug = AgentLogSource.posixPathSlug(cwd)
        let id = "11111111-1111-1111-1111-111111111111"
        let file = dir.appendingPathComponent("claude").appendingPathComponent(slug)
            .appendingPathComponent("\(id).jsonl").path
        try write(file, "{\"type\":\"user\"}\n")
        let roots = roots(in: dir)
        #expect(HarnessTranscriptLocator.path(
            kind: .claudeCode, conversationID: id, cwd: cwd, roots: roots) == file)
        #expect(HarnessTranscriptLocator.path(
            kind: .claudeCode, conversationID: "missing", cwd: cwd, roots: roots) == nil)
        #expect(HarnessTranscriptLocator.path(
            kind: .claudeCode, conversationID: "../\(id)", cwd: cwd, roots: roots) == nil)
    }

    @Test func grokAntigravityCursorCodexAndMuseResolve() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let dir = tmp.appendingPathComponent("crow-1314-locate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let roots = roots(in: dir)
        let cwd = "/Users/dev/work"
        let id = "22222222-2222-2222-2222-222222222222"

        let grok = dir.appendingPathComponent("grok")
            .appendingPathComponent(GrokSessionDir.encode(cwd))
            .appendingPathComponent(id)
            .appendingPathComponent("chat_history.jsonl").path
        try write(grok)
        #expect(sameFile(HarnessTranscriptLocator.path(
            kind: .grok, conversationID: id, cwd: cwd, roots: roots), grok))

        let agy = dir.appendingPathComponent("agy")
            .appendingPathComponent(id)
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
            .appendingPathComponent("transcript_full.jsonl").path
        try write(agy)
        #expect(sameFile(HarnessTranscriptLocator.path(
            kind: .antigravity, conversationID: id, cwd: cwd, roots: roots), agy))

        // Cursor's on-disk chat is `store.db`, a SQLite blob store. A path to
        // that file is not a transcript, so Cursor is omitted like OpenCode.
        #expect(HarnessTranscriptLocator.path(
            kind: .cursor, conversationID: id, cwd: cwd, roots: roots) == nil)

        let rollout = dir
            .appendingPathComponent("codex/2026/09/30/rollout-2026-09-30T00-00-00-\(id).jsonl").path
        try write(rollout)
        #expect(sameFile(HarnessTranscriptLocator.path(
            kind: .codex, conversationID: id, cwd: cwd, roots: roots), rollout))

        let journal = dir.appendingPathComponent("muse/2026/09/30/\(id)/session.jsonl").path
        try write(journal)
        #expect(sameFile(HarnessTranscriptLocator.path(
            kind: .muse, conversationID: id, cwd: cwd, roots: roots), journal))

        #expect(HarnessTranscriptLocator.path(
            kind: .openCode, conversationID: id, cwd: cwd, roots: roots) == nil)
        #expect(HarnessTranscriptLocator.path(
            kind: .claudeCode, conversationID: nil, cwd: cwd, roots: roots) == nil)
        #expect(HarnessTranscriptLocator.path(
            kind: .claudeCode, conversationID: "   ", cwd: cwd, roots: roots) == nil)
    }

    @Test func handoffPromptPathDoesNotOverwriteExploreSeed() throws {
        let session = Session(name: "Scratch", kind: .manager, agentKind: .cursor)
        let explore = TodoRPC.explorePromptPath(sessionID: session.id)
        let handoff = TodoRPC.handoffPromptPath(sessionID: session.id)
        #expect(explore != handoff)
        try "explore brief".write(toFile: explore, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: explore)
            try? FileManager.default.removeItem(atPath: handoff)
        }
        let cmd = try #require(ManagerSessionController.exploreSeedLaunchCommand(
            session: session,
            baseCommand: "claude",
            prompt: "handoff brief",
            promptPath: handoff))
        #expect(cmd.contains(handoff))
        #expect(!cmd.contains(explore))
        let exploreBody = try String(contentsOfFile: explore, encoding: .utf8)
        let handoffBody = try String(contentsOfFile: handoff, encoding: .utf8)
        #expect(exploreBody == "explore brief")
        #expect(handoffBody == "handoff brief")
    }
}

@Suite("AgentHandoffError")
struct AgentHandoffErrorTests {
    @Test func descriptionsAreUseful() {
        #expect(AgentHandoffError.sessionNotFound.localizedDescription.contains("Session"))
        #expect(AgentHandoffError.managerNotSupported.localizedDescription.contains("Manager"))
        #expect(AgentHandoffError.sameAgent.localizedDescription.contains("already"))
        #expect(AgentHandoffError.agentBinaryMissing("cursor").localizedDescription.contains("cursor"))
        #expect(AgentHandoffError.noWorktree.localizedDescription.contains("worktree"))
    }
}
