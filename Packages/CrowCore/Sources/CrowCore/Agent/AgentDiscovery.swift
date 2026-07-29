import Foundation

/// The outcome of deciding whether a discovered agent is launchable.
public enum AgentAvailability: Sendable, Equatable {
    /// The agent's binary didn't resolve on PATH / override / fallback.
    case unavailableNotFound
    /// The binary resolved via PATH/fallback but **failed the identity probe** —
    /// a different tool sharing the launch token (e.g. `superagent-ai/grok-cli`
    /// standing in for `xai-org/grok-build`). `path` is the impostor, for the
    /// log line (CROW-911).
    case unavailableFailedProbe(path: String)
    /// The binary resolved and is genuinely this agent. `viaOverride` is `true`
    /// when it came from an explicit `defaults.binaries.<kind>` pin (which is
    /// authoritative and bypasses the identity probe).
    case available(path: String, viaOverride: Bool)
}

/// Pure, host-agnostic availability decision for a discovered agent, extracted
/// so it's unit-testable without the daemon's `registerAgents` (which writes the
/// registry and logs). Both the daemon and the desktop mirror wrap this
/// (CROW-911 review — the registration-layer behavior had no test because the
/// decision lived inside a `private static` local function).
public enum AgentDiscovery {
    /// Resolve `agent`'s binary and decide availability. An explicit
    /// `.override` pin is trusted without probing; a PATH/`.fallback` match on a
    /// collision-prone token is identity-probed (`verifyBinaryIdentity`) so a
    /// foreign same-named binary is reported unavailable rather than launchable.
    public static func evaluate(_ agent: any CodingAgent) async -> AgentAvailability {
        guard let resolved = agent.resolveBinary() else {
            return .unavailableNotFound
        }
        if resolved.source == .override {
            return .available(path: resolved.path, viaOverride: true)
        }
        if await agent.verifyBinaryIdentity(atPath: resolved.path) {
            return .available(path: resolved.path, viaOverride: false)
        }
        return .unavailableFailedProbe(path: resolved.path)
    }
}
