import Foundation
import Testing
@testable import CrowCore

@Suite("AgentDiscovery")
struct AgentDiscoveryTests {
    private final class NoopHookConfigWriter: HookConfigWriter, @unchecked Sendable {
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

    /// A `CodingAgent` whose binary resolution and identity probe are fully
    /// controllable, so `AgentDiscovery.evaluate` — the registration decision —
    /// is tested without touching PATH or spawning a subprocess (CROW-911 review:
    /// the decision used to live inside a `private static` local and had no test).
    private struct StubAgent: CodingAgent {
        let kind: AgentKind = .grok
        var displayName: String { "Stub" }
        var iconSystemName: String { "sparkles" }
        var supportsRemoteControl: Bool { false }
        var launchCommandToken: String { "stub" }
        let hookConfigWriter: any HookConfigWriter = NoopHookConfigWriter()
        let stateSignalSource: any StateSignalSource = NoopStateSignalSource()

        var resolved: ResolvedBinary?
        var identity: Bool

        func resolveBinary() -> ResolvedBinary? { resolved }
        func verifyBinaryIdentity(atPath path: String) async -> Bool { identity }

        func autoLaunchCommand(
            session: Session, worktreePath: String, remoteControlEnabled: Bool,
            autoPermissionMode: Bool, telemetryPort: UInt16?
        ) -> String? { nil }
        func generatePrompt(
            session: Session, worktrees: [SessionWorktree], ticketURL: String?,
            provider: Provider?, codeProvider: Provider?
        ) async -> String { "" }
        func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) async throws -> String { "" }
        func managerLaunchCommand(
            sessionName: String, remoteControlEnabled: Bool,
            autoPermissionMode: Bool, telemetryPort: UInt16?
        ) -> String { "stub" }
    }

    @Test func notFoundWhenBinaryDoesNotResolve() async {
        let agent = StubAgent(resolved: nil, identity: true)
        #expect(await AgentDiscovery.evaluate(agent) == .unavailableNotFound)
    }

    @Test func overridePinIsAvailableWithoutProbing() async {
        // An explicit `.override` pin is authoritative — available even though
        // the probe would reject it (`identity: false` must not be consulted).
        let agent = StubAgent(
            resolved: ResolvedBinary(path: "/pin/grok", source: .override),
            identity: false
        )
        #expect(await AgentDiscovery.evaluate(agent) == .available(path: "/pin/grok", viaOverride: true))
    }

    @Test func pathMatchPassingProbeIsAvailable() async {
        let agent = StubAgent(
            resolved: ResolvedBinary(path: "/usr/bin/grok", source: .path),
            identity: true
        )
        #expect(await AgentDiscovery.evaluate(agent) == .available(path: "/usr/bin/grok", viaOverride: false))
    }

    @Test func pathMatchFailingProbeIsUnavailable() async {
        // The CROW-911 false positive: a foreign `grok` resolved on PATH fails
        // the probe → reported unavailable rather than launchable.
        let agent = StubAgent(
            resolved: ResolvedBinary(path: "/usr/bin/grok", source: .path),
            identity: false
        )
        #expect(await AgentDiscovery.evaluate(agent) == .unavailableFailedProbe(path: "/usr/bin/grok"))
    }

    @Test func fallbackMatchIsProbedNotTrusted() async {
        // A `.fallback` match is treated like `.path` — probed, not trusted like
        // an override.
        let agent = StubAgent(
            resolved: ResolvedBinary(path: "/opt/grok", source: .fallback),
            identity: false
        )
        #expect(await AgentDiscovery.evaluate(agent) == .unavailableFailedProbe(path: "/opt/grok"))
    }
}
