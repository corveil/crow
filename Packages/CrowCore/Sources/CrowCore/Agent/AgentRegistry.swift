import Foundation

/// Process-wide registry of `CodingAgent` implementations, keyed by
/// `AgentKind`. Phase A registers exactly one agent (Claude Code); later
/// phases let users pick an agent per session.
public final class AgentRegistry: @unchecked Sendable {
    public static let shared = AgentRegistry()

    private let lock = NSLock()
    private var agents: [AgentKind: any CodingAgent] = [:]
    /// Every agent the process knows about — available or not — keyed by kind,
    /// each paired with whether its binary resolved at boot. Superset of `agents`
    /// (which holds only the launchable ones). `knownOrder` preserves first-
    /// registration order for the listing. Drives the "surface-but-disable"
    /// pickers so an off-PATH agent shows greyed-out with a help tooltip instead
    /// of vanishing (#879).
    private var known: [AgentKind: (agent: any CodingAgent, available: Bool)] = [:]
    private var knownOrder: [AgentKind] = []
    private var defaultKind: AgentKind?

    public init() {}

    /// Register an available (launchable) `agent`. Thin wrapper over
    /// `registerKnown(_:available:)` — the common path for callers that only
    /// ever register resolved agents (tests, the desktop mirror). If no default
    /// has been set yet, the first registered agent becomes the default.
    public func register(_ agent: any CodingAgent) {
        registerKnown(agent, available: true)
    }

    /// Record a known agent along with whether its binary resolved on PATH.
    ///
    /// Available agents are added to the launchable `agents` map (and seed the
    /// default if none is set yet); **unavailable ones are recorded for the UI
    /// only** — they never enter `agents`, so `registeredKind`/`agent(for:)`
    /// still refuse to launch or hand off to them. This is what lets the pickers
    /// show all known agents while keeping the launch gate intact (#879).
    ///
    /// Availability is authoritative and kept in sync with `agents`: re-
    /// registering a kind as unavailable also removes it from the launchable map
    /// (and drops it as the default), so the two never disagree. Registration is
    /// boot-once in practice, but the invariant holds regardless of order.
    public func registerKnown(_ agent: any CodingAgent, available: Bool) {
        lock.lock(); defer { lock.unlock() }
        if known[agent.kind] == nil { knownOrder.append(agent.kind) }
        known[agent.kind] = (agent, available)
        if available {
            agents[agent.kind] = agent
            if defaultKind == nil {
                defaultKind = agent.kind
            }
        } else {
            agents[agent.kind] = nil
            if defaultKind == agent.kind { defaultKind = nil }
        }
    }

    public func agent(for kind: AgentKind) -> (any CodingAgent)? {
        lock.lock(); defer { lock.unlock() }
        return agents[kind]
    }

    /// The single registry gate for a caller-supplied `AgentKind` (CROW-593; #834).
    ///
    /// Returns `requested` only when an agent is actually registered for it;
    /// otherwise `nil`, so the caller falls back to its own configured default.
    /// Every session-creation surface (new-session and web/daemon
    /// `create-manager`) funnels a requested kind through here so none can
    /// persist a session with an unregistered/unknown kind — a persisted-but-
    /// unlaunchable session (`launchAgent` no-ops on the registry miss) or one
    /// that silently launches the default instead of the requested harness.
    /// Composed with each surface's `?? <configured default>` fallback rather
    /// than falling back itself, so the default choice stays with the caller.
    public func registeredKind(_ requested: AgentKind?) -> AgentKind? {
        guard let requested, agent(for: requested) != nil else { return nil }
        return requested
    }

    /// The agent to use when the caller doesn't specify one. Falls back to
    /// the first-registered agent.
    public var defaultAgent: (any CodingAgent)? {
        lock.lock(); defer { lock.unlock() }
        guard let kind = defaultKind else { return nil }
        return agents[kind]
    }

    /// Explicitly set the default agent by kind. Caller must ensure the kind
    /// has already been registered.
    public func setDefault(_ kind: AgentKind) {
        lock.lock(); defer { lock.unlock() }
        defaultKind = kind
    }

    public func allAgents() -> [any CodingAgent] {
        lock.lock(); defer { lock.unlock() }
        return Array(agents.values)
    }

    /// Every known agent — available and not — in first-registration order, each
    /// paired with whether its binary resolved. Availability is write-once per
    /// process in practice (registration is boot-once), but a re-register updates
    /// it in place and stays consistent with the launchable `agents` map. This is
    /// the source the `list-agents` RPC / pickers use so an off-PATH agent
    /// surfaces as a disabled option rather than disappearing (#879).
    public func allKnownAgents() -> [(agent: any CodingAgent, available: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return knownOrder.compactMap { known[$0] }
    }
}
