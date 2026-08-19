import Foundation

/// The absolute path that passed `CodingAgent.verifyBinaryIdentity` at
/// registration, per `AgentKind` — written once by `AgentDiscovery.evaluate`
/// and read by `CodingAgent.launchBinary()` at exec time.
///
/// **Why a cache and not a re-walk.** Registration and launch used to resolve
/// independently: boot probed whatever `resolveBinary()` returned, and every
/// later launch ran a *fresh* PATH walk whose result was interpolated into the
/// tmux command unprobed. Those two walks can disagree — a colliding token
/// (Cursor's legacy `agent`, which xAI's grok-build also installs) can resolve
/// to a different binary the second time if PATH, the override map, or the
/// on-disk install changed in between. That is how a session configured as
/// Cursor exec'd grok-build even though `cursor-agent` was installed and the
/// probe had passed at boot (CROW-1058). Pinning the *verified* path makes
/// "the binary we identified" and "the binary we launch" the same string by
/// construction, instead of two walks that happen to agree.
///
/// Deliberately **not** persisted to disk: the pin must not outlive the
/// process that verified it, or an upgrade/uninstall would leave Crow launching
/// a path that no longer holds this agent. `launchBinary()` re-checks
/// executability on every read for the same reason.
public final class VerifiedBinaries: @unchecked Sendable {
    public static let shared = VerifiedBinaries()

    private let lock = NSLock()
    private var paths: [AgentKind: String] = [:]

    public init() {}

    /// Pin `path` as the identity-verified binary for `kind`.
    public func record(kind: AgentKind, path: String) {
        lock.lock(); defer { lock.unlock() }
        paths[kind] = path
    }

    /// Drop any pin for `kind`. Called when discovery reports the agent
    /// unavailable, so a re-registration that now fails cannot leave a stale
    /// path behind for `launchBinary()` to hand back.
    public func clear(kind: AgentKind) {
        lock.lock(); defer { lock.unlock() }
        paths[kind] = nil
    }

    /// The verified path for `kind`, or `nil` if discovery never confirmed one.
    public func path(for kind: AgentKind) -> String? {
        lock.lock(); defer { lock.unlock() }
        return paths[kind]
    }
}
