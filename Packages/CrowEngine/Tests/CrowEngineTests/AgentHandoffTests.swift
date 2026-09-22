import Foundation
import Testing
import CrowCore
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
