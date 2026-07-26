import Foundation

/// Process-wide registry of `CodingAgent` implementations, keyed by
/// `AgentKind`. Phase A registers exactly one agent (Claude Code); later
/// phases let users pick an agent per session.
public final class AgentRegistry: @unchecked Sendable {
    public static let shared = AgentRegistry()

    private let lock = NSLock()
    private var agents: [AgentKind: any CodingAgent] = [:]
    private var defaultKind: AgentKind?

    public init() {}

    /// Register `agent`. If no default has been set yet, the first registered
    /// agent becomes the default.
    public func register(_ agent: any CodingAgent) {
        lock.lock(); defer { lock.unlock() }
        agents[agent.kind] = agent
        if defaultKind == nil {
            defaultKind = agent.kind
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
}
