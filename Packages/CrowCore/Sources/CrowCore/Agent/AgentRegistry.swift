import Foundation

/// Process-wide registry of `CodingAgent` implementations, keyed by
/// `AgentKind`. Phase A registers exactly one agent (Claude Code); later
/// phases let users pick an agent per session.
public final class AgentRegistry: @unchecked Sendable {
    public static let shared = AgentRegistry()

    private let lock = NSLock()
    private var agents: [AgentKind: any CodingAgent] = [:]
    /// Every agent the process knows about — available or not — in registration
    /// order, each paired with whether its binary resolved at boot. Superset of
    /// `agents` (which holds only the launchable ones). Drives the
    /// "surface-but-disable" pickers so an off-PATH agent shows greyed-out with
    /// a help tooltip instead of vanishing (#879).
    private var knownOrder: [(agent: any CodingAgent, available: Bool)] = []
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
    /// Available agents are also added to the launchable `agents` map (and seed
    /// the default if none is set yet); **unavailable ones are recorded for the
    /// UI only** — they never enter `agents`, so `registeredKind`/`agent(for:)`
    /// still refuse to launch or hand off to them. This is what lets the pickers
    /// show all known agents while keeping the launch gate intact (#879).
    public func registerKnown(_ agent: any CodingAgent, available: Bool) {
        lock.lock(); defer { lock.unlock() }
        knownOrder.append((agent, available))
        if available {
            agents[agent.kind] = agent
            if defaultKind == nil {
                defaultKind = agent.kind
            }
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
    /// paired with whether its binary resolved. De-duplicated by kind (last
    /// registration wins, so a re-register can flip availability). This is the
    /// source the `list-agents` RPC / pickers use so an off-PATH agent surfaces
    /// as a disabled option rather than disappearing (#879).
    public func allKnownAgents() -> [(agent: any CodingAgent, available: Bool)] {
        lock.lock(); defer { lock.unlock() }
        var byKind: [AgentKind: (agent: any CodingAgent, available: Bool)] = [:]
        var order: [AgentKind] = []
        for entry in knownOrder {
            if byKind[entry.agent.kind] == nil { order.append(entry.agent.kind) }
            byKind[entry.agent.kind] = entry
        }
        return order.map { byKind[$0]! }
    }
}
