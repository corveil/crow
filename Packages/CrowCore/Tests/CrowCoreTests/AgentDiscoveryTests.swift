import Foundation
import Testing
@testable import CrowCore

// Serialized: these share the process-wide `VerifiedBinaries` /
// `BinaryOverrides` singletons, so running them in parallel would have
// each test tearing down the next one's fixture.
@Suite("AgentDiscovery", .serialized)
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

        /// The full candidate list, most-preferred first — what
        /// `AgentDiscovery.evaluate` walks. Modelled as a list rather than a
        /// single value because the CROW-1058 behavior under test *is* the
        /// walk: a first candidate that fails the probe must not condemn the
        /// ones behind it.
        var candidates: [ResolvedBinary]
        /// Paths the probe accepts. Everything else is rejected, so a fixture
        /// can plant an impostor and a genuine install in the same list.
        var verified: Set<String>
        /// Every path the probe was actually run against, in order — lets a
        /// test assert the walk short-circuits instead of probing everything.
        let probed = Recorder()

        init(candidates: [ResolvedBinary], verified: Set<String>) {
            self.candidates = candidates
            self.verified = verified
        }

        /// Single-candidate convenience for the cases that predate the walk.
        init(resolved: ResolvedBinary?, identity: Bool) {
            self.candidates = resolved.map { [$0] } ?? []
            self.verified = (identity ? resolved.map { Set([$0.path]) } : nil) ?? []
        }

        func resolveBinaryCandidates() -> [ResolvedBinary] { candidates }
        func verifyBinaryIdentity(atPath path: String) async -> Bool {
            probed.record(path)
            return verified.contains(path)
        }

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

    // MARK: - Walking past an impostor (CROW-1058)

    /// The residual CROW-989 documented and left open: grok-build's `agent` sits
    /// earlier on PATH than Cursor's own, so the first candidate is a foreign
    /// binary. Judging the token on that one sample reports Cursor unavailable
    /// even though a genuine install is right behind it. The walk keeps going.
    @Test func probesPastAnImpostorToAGenuineInstallFurtherDownPath() async {
        let agent = StubAgent(
            candidates: [
                ResolvedBinary(path: "/Users/x/.grok/bin/agent", source: .path),
                ResolvedBinary(path: "/Users/x/.local/bin/agent", source: .path),
            ],
            verified: ["/Users/x/.local/bin/agent"]
        )
        #expect(await AgentDiscovery.evaluate(agent)
                == .available(path: "/Users/x/.local/bin/agent", viaOverride: false))
    }

    /// …and the fallback leg is walked the same way, so a hardcoded
    /// `~/.local/bin/agent` (grok-build's mirror) can't strand a genuine
    /// `cursor-agent` listed after it.
    @Test func walkContinuesAcrossPathAndFallbackCandidates() async {
        let agent = StubAgent(
            candidates: [
                ResolvedBinary(path: "/Users/x/.local/bin/agent", source: .path),
                ResolvedBinary(path: "/opt/homebrew/bin/cursor-agent", source: .fallback),
            ],
            verified: ["/opt/homebrew/bin/cursor-agent"]
        )
        #expect(await AgentDiscovery.evaluate(agent)
                == .available(path: "/opt/homebrew/bin/cursor-agent", viaOverride: false))
    }

    /// When nothing verifies, the *most-preferred* candidate is named — it's the
    /// one the pre-CROW-1058 walk would have launched, so it's the path the
    /// operator needs in the boot log.
    @Test func failedProbeReportsTheMostPreferredCandidate() async {
        let agent = StubAgent(
            candidates: [
                ResolvedBinary(path: "/Users/x/.grok/bin/agent", source: .path),
                ResolvedBinary(path: "/usr/local/bin/agent", source: .path),
            ],
            verified: []
        )
        #expect(await AgentDiscovery.evaluate(agent)
                == .unavailableFailedProbe(path: "/Users/x/.grok/bin/agent"))
    }

    /// A healthy install still costs one probe: candidates are ordered
    /// preferred-name-first, so the loop exits on the first spawn and the extra
    /// candidates are never sampled.
    @Test func healthyInstallProbesOnlyTheFirstCandidate() async {
        let agent = StubAgent(
            candidates: [
                ResolvedBinary(path: "/opt/homebrew/bin/cursor-agent", source: .path),
                ResolvedBinary(path: "/Users/x/.grok/bin/agent", source: .path),
            ],
            verified: ["/opt/homebrew/bin/cursor-agent"]
        )
        _ = await AgentDiscovery.evaluate(agent)
        #expect(agent.probed.value == ["/opt/homebrew/bin/cursor-agent"])
    }

    // MARK: - Verified-path pin (CROW-1058)

    /// The pin is what makes launch exec the binary discovery identified — the
    /// half of CROW-1058 that a fresh PATH walk at launch time got wrong.
    @Test func availabilityPinsTheVerifiedPath() async {
        VerifiedBinaries.shared.clear(kind: .grok)
        defer { VerifiedBinaries.shared.clear(kind: .grok) }
        let agent = StubAgent(
            candidates: [
                ResolvedBinary(path: "/Users/x/.grok/bin/agent", source: .path),
                ResolvedBinary(path: "/Users/x/.local/bin/cursor-agent", source: .path),
            ],
            verified: ["/Users/x/.local/bin/cursor-agent"]
        )
        _ = await AgentDiscovery.evaluate(agent)
        // The impostor was first in line; the *verified* path is what's pinned.
        #expect(VerifiedBinaries.shared.path(for: agent.kind) == "/Users/x/.local/bin/cursor-agent")
    }

    /// A re-registration that now fails must not leave the old pin behind for
    /// `launchBinary()` to keep handing out — an uninstall would otherwise keep
    /// launching a path that no longer holds this agent.
    @Test func failedEvaluationClearsAStalePin() async {
        VerifiedBinaries.shared.clear(kind: .grok)
        defer { VerifiedBinaries.shared.clear(kind: .grok) }
        VerifiedBinaries.shared.record(kind: .grok, path: "/stale/grok")
        let agent = StubAgent(resolved: nil, identity: true)
        #expect(await AgentDiscovery.evaluate(agent) == .unavailableNotFound)
        #expect(VerifiedBinaries.shared.path(for: .grok) == nil)
    }

    /// An override pin is authoritative *and* pinned, so launch uses the exact
    /// binary the user named without re-walking.
    @Test func overridePinIsAlsoRecordedForLaunch() async {
        VerifiedBinaries.shared.clear(kind: .grok)
        defer { VerifiedBinaries.shared.clear(kind: .grok) }
        let agent = StubAgent(
            resolved: ResolvedBinary(path: "/pin/grok", source: .override), identity: false)
        _ = await AgentDiscovery.evaluate(agent)
        #expect(VerifiedBinaries.shared.path(for: .grok) == "/pin/grok")
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

/// Records probe calls in order. A class so the `struct` agent can mutate it
/// from a non-mutating protocol method.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var value: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func record(_ p: String) { lock.lock(); defer { lock.unlock() }; paths.append(p) }
}
