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
