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
    /// `.override` pin is trusted without probing; PATH/`.fallback` matches on a
    /// collision-prone token are identity-probed (`verifyBinaryIdentity`) so a
    /// foreign same-named binary is reported unavailable rather than launchable.
    ///
    /// Also **pins the verified path** in `VerifiedBinaries` so launch execs the
    /// binary discovery identified, rather than re-resolving and possibly
    /// landing elsewhere (CROW-1058). That side effect is why this is the one
    /// entry point registration should call; `decide` below is the pure half.
    public static func evaluate(_ agent: any CodingAgent) async -> AgentAvailability {
        let outcome = await decide(agent)
        // Pin the winner so `launchBinary()` execs the binary we identified
        // rather than re-walking PATH and possibly landing on a different one
        // (CROW-1058). Clearing on failure matters as much as recording on
        // success: a re-registration that now fails must not leave the previous
        // pin behind for launch to keep using.
        switch outcome {
        case .available(let path, _):
            VerifiedBinaries.shared.record(kind: agent.kind, path: path)
        case .unavailableNotFound, .unavailableFailedProbe:
            VerifiedBinaries.shared.clear(kind: agent.kind)
        }
        return outcome
    }

    /// The availability decision itself, with no side effects.
    ///
    /// Probes **every** candidate rather than only the first. A single sample is
    /// enough to judge an unambiguous token, but not one that collides: with
    /// grok-build's `agent` ahead of Cursor's on PATH, first-sample-only reports
    /// Cursor unavailable while a genuine `cursor-agent` sits further down the
    /// list (CROW-989's documented residual, CROW-1058). Candidates are already
    /// in preference order, so the first that verifies is also the most
    /// preferred one that verifies.
    ///
    /// Cost is unchanged for a healthy install: candidates are ordered
    /// preferred-name-first, so the genuine binary is normally sampled first and
    /// the loop exits after one spawn. Extra probes happen only when an earlier
    /// candidate is an impostor — exactly the case worth paying for — and each
    /// is hard-bounded by `BinaryIdentityProbe`.
    private static func decide(_ agent: any CodingAgent) async -> AgentAvailability {
        let candidates = agent.resolveBinaryCandidates()
        guard let first = candidates.first else {
            return .unavailableNotFound
        }
        if first.source == .override {
            return .available(path: first.path, viaOverride: true)
        }
        for candidate in candidates {
            if await agent.verifyBinaryIdentity(atPath: candidate.path) {
                return .available(path: candidate.path, viaOverride: false)
            }
        }
        // Report the most-preferred candidate as the impostor: it's the one the
        // pre-CROW-1058 walk would have launched, so it's the path the operator
        // needs named in the boot log.
        return .unavailableFailedProbe(path: first.path)
    }
}
