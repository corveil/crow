import Foundation
import Testing
@testable import CrowCore

/// The resolution + identity machinery shared by every colliding-token adapter
/// (CROW-989). `AgentDiscoveryTests` covers the availability *decision*; this
/// covers the two pieces that decision is built from — which binary name wins,
/// and how a probe reads a binary's output.
@Suite("Binary resolution and identity")
struct BinaryResolutionTests {

    // MARK: - Token preference

    /// The acceptance criterion from CROW-989: with a foreign binary occupying
    /// the ambiguous alias *earlier* on PATH, the preferred name still wins.
    /// Token-major means PATH order can't decide this.
    @Test func preferredTokenWinsOverAnEarlierForeignAlias() {
        // Simulates the reported machine: grok-build owns `~/.grok/bin/agent`
        // ahead of Cursor's `~/.local/bin/{agent,cursor-agent}` on PATH.
        let path: [String: String] = [
            "agent": "/Users/x/.grok/bin/agent",
            "cursor-agent": "/Users/x/.local/bin/cursor-agent",
        ]
        let resolved = BinaryTokenResolver.firstOnPath(
            tokens: ["cursor-agent", "agent"], lookup: { path[$0] })
        #expect(resolved == "/Users/x/.local/bin/cursor-agent")
    }

    /// …and reordering PATH so the foreign binary comes later doesn't change the
    /// answer either. The lookup closure *is* the PATH walk, so swapping which
    /// absolute path each name maps to is the same experiment as reordering PATH:
    /// the result depends on the name, never on install order.
    @Test func reorderingPathDoesNotChangeTheSelection() {
        let grokFirst: [String: String] = [
            "agent": "/Users/x/.grok/bin/agent",
            "cursor-agent": "/opt/homebrew/bin/cursor-agent",
        ]
        let cursorFirst: [String: String] = [
            "agent": "/Users/x/.local/bin/agent",
            "cursor-agent": "/opt/homebrew/bin/cursor-agent",
        ]
        let tokens = ["cursor-agent", "agent"]
        #expect(BinaryTokenResolver.firstOnPath(tokens: tokens, lookup: { grokFirst[$0] })
                == BinaryTokenResolver.firstOnPath(tokens: tokens, lookup: { cursorFirst[$0] }))
    }

    /// A legacy install that only ships the alias still resolves — the fallback
    /// leg of the same walk (CROW-989 acceptance: "an install with only the
    /// legacy `agent` name still works").
    @Test func aliasResolvesWhenPreferredNameIsAbsent() {
        let path = ["agent": "/usr/local/bin/agent"]
        let resolved = BinaryTokenResolver.firstOnPath(
            tokens: ["cursor-agent", "agent"], lookup: { path[$0] })
        #expect(resolved == "/usr/local/bin/agent")
    }

    @Test func noTokenResolvesToNil() {
        #expect(BinaryTokenResolver.firstOnPath(
            tokens: ["cursor-agent", "agent"], lookup: { _ in nil }) == nil)
    }

    /// A single-token agent walks exactly once — the pre-CROW-989 behavior every
    /// non-colliding adapter still gets.
    @Test func singleTokenWalksOnce() {
        var probed: [String] = []
        _ = BinaryTokenResolver.firstOnPath(tokens: ["claude"], lookup: {
            probed.append($0); return nil
        })
        #expect(probed == ["claude"])
    }

    // MARK: - binaryTokens composition

    @Test func binaryTokensDefaultsToTheLoneLaunchToken() {
        #expect(StubAgent().binaryTokens == ["stub"])
    }

    @Test func binaryTokensPutsAliasesAfterThePreferredToken() {
        var a = StubAgent()
        a.aliases = ["legacy", "older"]
        #expect(a.binaryTokens == ["stub", "legacy", "older"])
    }

    // MARK: - Identity probe

    @Test func probeMatchesOnAnySingleMarker() async {
        let runner = FakeProbeRunner(outputs: ["--help": "Options:\n  --approve-mcps  Approve MCPs"])
        #expect(await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help"],
            markers: ["--approve-mcps", "--trust"], runner: runner))
    }

    /// Markers are matched case-insensitively (the probe lowercases the output),
    /// so a binary that shouts its env-var names still identifies.
    @Test func probeIsCaseInsensitive() async {
        let runner = FakeProbeRunner(outputs: ["--help": "Set CURSOR_API_KEY to authenticate"])
        #expect(await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help"],
            markers: ["cursor_api_key"], runner: runner))
    }

    @Test func probeRejectsOutputWithNoMarker() async {
        let runner = FakeProbeRunner(outputs: ["--help": "Usage: something-else [OPTIONS]"])
        #expect(await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help"],
            markers: ["--approve-mcps"], runner: runner) == false)
    }

    /// A binary that prints nothing (or a spawn failure that yields `""`) can't
    /// be identified, so it's rejected.
    @Test func probeRejectsEmptyOutput() async {
        #expect(await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help", "--version"],
            markers: ["--approve-mcps"], runner: FakeProbeRunner(outputs: [:])) == false)
    }

    /// A foreign binary may exit non-zero yet still print the text that
    /// identifies it; the probe merges stdout+stderr and matches regardless of
    /// exit status.
    @Test func probeToleratesNonZeroExit() async {
        let runner = FakeProbeRunner(
            outputs: ["--help": "supports --approve-mcps"], failing: ["--help"])
        #expect(await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help"],
            markers: ["--approve-mcps"], runner: runner))
    }

    /// Later args are only spawned when earlier ones don't match — a genuine
    /// install costs one subprocess, not one per arg.
    @Test func probeShortCircuitsOnTheFirstMatchingArg() async {
        let runner = FakeProbeRunner(outputs: ["--help": "--approve-mcps", "--version": "1.0"])
        _ = await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help", "--version"],
            markers: ["--approve-mcps"], runner: runner)
        #expect(runner.probed.value == ["--help"])
    }

    /// The #912 Red, at the shared layer: a binary that never exits and ignores
    /// cancellation must not stall boot. The timeout is a *hard* bound on the
    /// awaiting task, so this returns at the cap rather than hanging. A tiny
    /// injected timeout keeps the test instant.
    @Test func probeHardBoundsAgainstNeverCompletingRunner() async {
        let out = await BinaryIdentityProbe.run(
            "/bin/x", "--help", runner: NeverRunner(), timeoutNanos: 50_000_000)
        #expect(out == "")
    }

    /// …and a timed-out leg yields no marker rather than a false positive.
    @Test func timedOutProbeDoesNotMatch() async {
        #expect(await BinaryIdentityProbe.matches(
            path: "/bin/x", args: ["--help"], markers: ["--approve-mcps"],
            runner: NeverRunner(), timeoutNanos: 50_000_000) == false)
    }
}

// MARK: - Multi-candidate walk (CROW-1058)

// Serialized: these share the process-wide `VerifiedBinaries` /
// `BinaryOverrides` singletons, so running them in parallel would have
// each test tearing down the next one's fixture.
@Suite("Binary candidates and launch selection", .serialized)
struct LaunchBinarySelectionTests {

    /// `allOnPath` keeps the token-major preference order of `firstOnPath` while
    /// surfacing the runners-up — every `cursor-agent` hit precedes every
    /// `agent` hit, regardless of where each sits in PATH.
    @Test func allOnPathIsTokenMajorAndKeepsEveryHit() {
        let path: [String: [String]] = [
            "cursor-agent": ["/opt/homebrew/bin/cursor-agent", "/Users/x/.local/bin/cursor-agent"],
            "agent": ["/Users/x/.grok/bin/agent", "/Users/x/.local/bin/agent"],
        ]
        #expect(BinaryTokenResolver.allOnPath(
            tokens: ["cursor-agent", "agent"], lookup: { path[$0] ?? [] }) == [
                "/opt/homebrew/bin/cursor-agent",
                "/Users/x/.local/bin/cursor-agent",
                "/Users/x/.grok/bin/agent",
                "/Users/x/.local/bin/agent",
            ])
    }

    /// The same absolute path reached under two token names (Cursor symlinks
    /// both into one directory) is probed once, not twice.
    @Test func allOnPathDeDuplicatesSharedPaths() {
        let shared = ["/usr/local/bin/agent"]
        #expect(BinaryTokenResolver.allOnPath(
            tokens: ["cursor-agent", "agent"],
            lookup: { $0 == "agent" ? shared : shared }) == shared)
    }

    @Test func allOnPathReturnsEmptyWhenNothingResolves() {
        #expect(BinaryTokenResolver.allOnPath(
            tokens: ["cursor-agent", "agent"], lookup: { _ in [] }).isEmpty)
    }

    // MARK: - launchBinary()

    /// **The CROW-1058 assertion.** Launch must exec the binary discovery
    /// verified, not whatever a fresh walk turns up — those can differ, and when
    /// they did, a Cursor session came up running grok-build.
    @Test func launchPrefersTheVerifiedPathOverAFreshResolution() {
        VerifiedBinaries.shared.clear(kind: .cursor)
        defer { VerifiedBinaries.shared.clear(kind: .cursor) }
        VerifiedBinaries.shared.record(kind: .cursor, path: "/bin/sh")
        var agent = StubAgent()
        agent.aliases = ["agent"]
        agent.candidates = [ResolvedBinary(path: "/Users/x/.grok/bin/agent", source: .path)]
        #expect(agent.launchBinary() == "/bin/sh")
    }

    // NB: "an explicit `defaults.binaries.cursor` pin still outranks the verified
    // path" is asserted in `CursorAgentTests`, not here. `BinaryOverrides.shared`
    // is process-wide and `BinaryOverridesTests` — a sibling suite that runs in
    // parallel with this one — resets it, so a fixture built on it would flake
    // in this package. There it is also the stronger assertion: it reads the
    // real Cursor launch text rather than a stub's resolution.

    /// A pin that no longer points at an executable (upgrade, uninstall) is
    /// dropped rather than interpolated into the pane as a dead path.
    @Test func launchIgnoresAVerifiedPathThatIsGone() {
        VerifiedBinaries.shared.clear(kind: .cursor)
        defer { VerifiedBinaries.shared.clear(kind: .cursor) }
        VerifiedBinaries.shared.record(kind: .cursor, path: "/tmp/crow1058-does-not-exist")
        var agent = StubAgent()
        agent.candidates = [ResolvedBinary(path: "/usr/bin/true", source: .path)]
        #expect(agent.launchBinary() == "/usr/bin/true")
    }

    /// With nothing verified, an agent that declares an alias will not launch a
    /// path named after that alias — `…/bin/agent` is precisely the colliding
    /// name, and "no launch" is the required outcome, not "launch it anyway".
    @Test func launchRefusesAnUnverifiedAliasNamedBinary() {
        VerifiedBinaries.shared.clear(kind: .cursor)
        defer { VerifiedBinaries.shared.clear(kind: .cursor) }
        var agent = StubAgent()
        agent.aliases = ["agent"]
        agent.candidates = [ResolvedBinary(path: "/Users/x/.grok/bin/agent", source: .path)]
        #expect(agent.launchBinary() == nil)
    }

    /// …but the unambiguous preferred name is still launchable unverified, so a
    /// genuine install on a host where the probe never ran (a unit test, a
    /// registration-free embedding) isn't grounded.
    @Test func launchAcceptsAnUnverifiedPreferredNameBinary() {
        VerifiedBinaries.shared.clear(kind: .cursor)
        defer { VerifiedBinaries.shared.clear(kind: .cursor) }
        var agent = StubAgent()
        agent.aliases = ["agent"]
        agent.candidates = [ResolvedBinary(path: "/usr/local/bin/stub", source: .path)]
        #expect(agent.launchBinary() == "/usr/local/bin/stub")
    }

    /// An agent with no alias declares its token unambiguous, so the narrowing
    /// never applies — every conformer but Cursor keeps the old behavior byte
    /// for byte, whatever its binary is named.
    @Test func launchLeavesAliasFreeAgentsAlone() {
        VerifiedBinaries.shared.clear(kind: .cursor)
        defer { VerifiedBinaries.shared.clear(kind: .cursor) }
        var agent = StubAgent()  // no aliases
        agent.candidates = [ResolvedBinary(path: "/opt/weird/place/renamed", source: .fallback)]
        #expect(agent.launchBinary() == "/opt/weird/place/renamed")
    }

    @Test func launchReturnsNilWhenNothingResolvesAtAll() {
        VerifiedBinaries.shared.clear(kind: .cursor)
        defer { VerifiedBinaries.shared.clear(kind: .cursor) }
        #expect(StubAgent().launchBinary() == nil)
    }

    /// `resolveBinary()` is still the head of the candidate list — the selection
    /// CROW-1058 preserves while widening what discovery may probe.
    @Test func resolveBinaryIsTheHeadOfTheCandidateList() {
        var agent = StubAgent()
        agent.candidates = [
            ResolvedBinary(path: "/first", source: .path),
            ResolvedBinary(path: "/second", source: .path),
        ]
        #expect(agent.resolveBinary() == ResolvedBinary(path: "/first", source: .path))
        #expect(agent.findBinary() == "/first")
    }
}

// MARK: - Fixtures

/// Canned probe responder keyed by the probe arg, recording which args were
/// actually spawned so short-circuiting is observable. Args listed in `failing`
/// throw `.nonZeroExit` carrying their output (a binary that exits non-zero but
/// still prints).
private struct FakeProbeRunner: ShellRunner {
    let outputs: [String: String]
    var failing: Set<String> = []
    let probed = Recorder()

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var args: [String] = []
        var value: [String] { lock.lock(); defer { lock.unlock() }; return args }
        func record(_ a: String) { lock.lock(); defer { lock.unlock() }; args.append(a) }
    }

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        let arg = args.dropFirst().first ?? ""
        probed.record(arg)
        let out = outputs[arg] ?? ""
        if failing.contains(arg) { throw ShellRunnerError.nonZeroExit(exitCode: 2, output: out) }
        return out
    }
}

/// A `ShellRunner` that never completes and ignores cancellation. Uses an
/// *unsafe* continuation deliberately: the leak (never resumed) is the intended
/// scenario, so a checked continuation would only emit a misuse diagnostic.
private struct NeverRunner: ShellRunner {
    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return ""  // unreachable
    }
}

/// Minimal conformer for exercising the `binaryTokens` default composition.
private struct StubAgent: CodingAgent {
    var aliases: [String] = []
    /// Overrides the PATH walk so `launchBinary()`'s fallback leg is
    /// exercisable without a real install.
    var candidates: [ResolvedBinary] = []

    func resolveBinaryCandidates() -> [ResolvedBinary] { candidates }

    let kind: AgentKind = .cursor
    var displayName: String { "Stub" }
    var iconSystemName: String { "sparkles" }
    var supportsRemoteControl: Bool { false }
    var launchCommandToken: String { "stub" }
    var alternateLaunchCommandTokens: [String] { aliases }
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
