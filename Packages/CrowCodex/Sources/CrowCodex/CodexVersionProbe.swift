import Foundation
import CrowCore

/// Decides whether the installed `codex` is new enough for Crow to declare
/// `"async": true` on its hook entries (CROW-999).
///
/// ## Why this is version-gated
///
/// Codex's hook engine parses `async` on every build, but only honors it from
/// **0.148.0**. Before that, `discovery.rs` logged *"async hooks are not
/// supported yet"* and **skipped the entry entirely** for every event except
/// `SessionEnd` — so an `async: true` Crow writes on an older build doesn't
/// degrade to synchronous, it deletes the hook. Crow's session-state detection
/// runs on those hooks, so the card would simply stop updating. That is why
/// `CodexHookConfigWriter.asyncEvents` was empty for so long, and why the gate
/// here is fail-closed: every uncertain answer (no binary, spawn failure,
/// timeout, unparseable banner) yields sync-only, which is always correct and
/// only costs latency.
///
/// From 0.148.0 the same file computes `runs_async = async && event !=
/// SessionEnd` and tags the handler `HookExecutionMode::Async`, so async is
/// honored for every event Crow registers (Crow registers no `SessionEnd`
/// hook; `SessionEnd` is downgraded to sync with a warning rather than
/// skipped).
///
/// ## Why pre-releases don't qualify
///
/// Async landed partway through the 0.148 alpha series (`0.148.0-alpha.9`),
/// so `0.148.0-alpha.1` is a build that would silently drop the hooks.
/// `AgentSemVer` orders any pre-release below its release, so the `>=` here
/// rejects all of `0.148.0-*` — conservative, standard, and self-correcting
/// once the stable ships.
public enum CodexVersionProbe {
    /// First Codex release whose hook engine honors `async: true` for the
    /// events Crow registers. Verified against upstream
    /// `codex-rs/hooks/src/engine/discovery.rs` on `main` (2026-08-13): the
    /// "not supported yet" skip is gone and `runs_async` flows into
    /// `HookExecutionMode::Async`.
    public static let minimumAsyncHookVersion = AgentSemVer(0, 148, 0)

    /// Flag Crow passes `codex` to read its version. Cheap and side-effect-free.
    static let versionArgument = "--version"

    /// The probe's verdict plus what it saw, so boot can log *why*.
    public struct AsyncHookSupport: Sendable, Equatable {
        /// Whether `CodexHookConfigWriter` may emit `async: true`.
        public let supported: Bool
        /// The parsed version, or `nil` when the banner couldn't be read.
        public let detected: AgentSemVer?

        /// Fail-closed verdict for "we never got to ask" — no Codex
        /// registered, or no binary resolved.
        public static let unsupported = AsyncHookSupport(supported: false, detected: nil)

        /// One line for the daemon boot log, naming the version and the pin so
        /// a stale gate is diagnosable without a rebuild.
        public var logLine: String {
            guard let detected else {
                return "sync-only (version unreadable; needs >= \(minimumAsyncHookVersion.displayString))"
            }
            return supported
                ? "async enabled (codex \(detected.displayString) >= \(minimumAsyncHookVersion.displayString))"
                : "sync-only (codex \(detected.displayString) < \(minimumAsyncHookVersion.displayString))"
        }
    }

    /// The pure decision, split out from the subprocess so the gate is unit
    /// tested without a `codex` on the box. `output` is the merged
    /// stdout+stderr of `codex --version` — `""` for a spawn failure or a
    /// timeout, which parses to `nil` and lands on sync-only.
    static func decide(versionOutput output: String) -> AsyncHookSupport {
        guard let version = AgentSemVer.firstToken(in: output) else { return .unsupported }
        return AsyncHookSupport(
            supported: version >= minimumAsyncHookVersion,
            detected: version)
    }

    /// Run `codex --version` at `binaryPath` and decide.
    ///
    /// Reuses `BinaryIdentityProbe.run`, which hard-bounds the subprocess:
    /// this runs on the daemon boot path, before the board poll, so a `codex`
    /// that hangs (or forks a child holding the stdout pipe) must not stall
    /// startup. On timeout the run is cancelled and the empty output falls
    /// through to sync-only.
    ///
    /// Probed **once at boot**, matching how agent availability is decided —
    /// so upgrading `codex` under a running `crowd` needs a daemon restart to
    /// take effect, same as installing one.
    public static func probe(
        binaryPath: String,
        runner: any ShellRunner = ProcessShellRunner(),
        timeoutNanos: UInt64 = BinaryIdentityProbe.defaultTimeoutNanos
    ) async -> AsyncHookSupport {
        let output = await BinaryIdentityProbe.run(
            binaryPath, versionArgument, runner: runner, timeoutNanos: timeoutNanos)
        return decide(versionOutput: output)
    }
}
