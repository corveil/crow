import Foundation
import Testing
@testable import CrowCore

// #834: `registeredKind` is the single registry gate every session-creation
// surface (new-session + web/daemon create-manager) funnels a caller-supplied
// `AgentKind` through, replacing the per-surface asymmetry where only the web
// `create-manager` (CROW-593) validated. An unregistered/unknown kind or `nil`
// returns `nil` so the caller falls back to its own configured default.
//
// The registered-kind passthrough is asserted at the surface level in
// CrowEngineTests / CrowDaemonTests, where a real `ClaudeCodeAgent` is
// registered — CrowCore has no concrete `CodingAgent` to register here.

@Suite("AgentRegistry.registeredKind gate")
struct AgentRegistryResolverTests {

    @Test func rejectsAnUnregisteredKind() {
        // A kind value no shipped agent claims — misses even if the process-wide
        // registry has been populated by another test.
        let unknown = AgentKind(rawValue: "crow-834-unregistered-resolver")
        #expect(AgentRegistry.shared.agent(for: unknown) == nil)
        #expect(AgentRegistry.shared.registeredKind(unknown) == nil)
    }

    @Test func passesThroughNil() {
        // No request → no gate decision to make; the caller supplies the default.
        #expect(AgentRegistry.shared.registeredKind(nil) == nil)
    }
}

@Suite("AgentRegistry.usesAlternateScreen")
struct AgentRegistryScrollCapabilityTests {

    private struct StubAgent: CodingAgent {
        let kind: AgentKind
        var usesAlternateScreen: Bool
        var displayName: String { kind.rawValue }
        var iconSystemName: String { "sparkles" }
        var supportsRemoteControl: Bool { false }
        var launchCommandToken: String { kind.rawValue }
        let hookConfigWriter: any HookConfigWriter = NoopHookConfigWriter()
        let stateSignalSource: any StateSignalSource = NoopStateSignalSource()
        func autoLaunchCommand(
            session: Session, worktreePath: String, remoteControlEnabled: Bool,
            autoPermissionMode: Bool, telemetryPort: UInt16?
        ) -> String? { nil }
        func generatePrompt(
            session: Session, worktrees: [SessionWorktree], ticketURL: String?,
            provider: Provider?, codeProvider: Provider?
        ) async -> String { "" }
        func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) async throws -> String { "" }
    }

    private struct NoopHookConfigWriter: HookConfigWriter {
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

    @Test func unknownKindKeepsTheAltScreenPath() {
        let registry = AgentRegistry()
        #expect(registry.usesAlternateScreen(for: nil) == true)
        #expect(registry.usesAlternateScreen(for: AgentKind(rawValue: "crow-1008-unknown")) == true)
    }

    @Test func readsTheDeclaredCapabilityFromKnownAgents() {
        let registry = AgentRegistry()
        let claude = AgentKind(rawValue: "crow-1008-claude")
        let cursor = AgentKind(rawValue: "crow-1008-cursor")
        registry.registerKnown(
            StubAgent(kind: claude, usesAlternateScreen: true), available: true)
        registry.registerKnown(
            StubAgent(kind: cursor, usesAlternateScreen: false), available: false)
        #expect(registry.usesAlternateScreen(for: claude) == true)
        // Unavailable still has a declared scroll model.
        #expect(registry.usesAlternateScreen(for: cursor) == false)
    }
}
