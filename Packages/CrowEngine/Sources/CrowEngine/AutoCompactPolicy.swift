import CrowCore
import Foundation

/// Whether Crow may type `/compact` into a session right now (CROW-1493,
/// pre-expiry compaction). Pure, so every rule is unit-testable; the
/// controller gathers the inputs and acts on the verdict.
///
/// The point is to compact while the prompt cache is still warm: the
/// compaction call then reads the cache cheaply, and a later resume writes a
/// small cache instead of re-writing a large one at the cache-write price.
/// Every rule below is about either that window or not getting in the
/// operator's way.
public enum AutoCompactPolicy {

    public enum Verdict: Equatable, Sendable {
        case compact
        case skip(Skip)
    }

    /// Why a session was left alone. The raw value goes to the automation log.
    public enum Skip: String, Sendable, Equatable {
        case disabled
        /// Only Claude Code: its `/compact` and cache lifetimes are what this
        /// was measured on.
        case unsupportedAgent = "unsupported_agent"
        /// Completed or archived: nobody is coming back to it.
        case inactiveSession = "inactive_session"
        case noTranscript = "no_transcript"
        case belowThreshold = "below_threshold"
        /// Already compacted, and nothing has been sent since.
        case alreadyCompacted = "already_compacted"
        /// Crow already sent `/compact` for this exact last call.
        case alreadyAttempted = "already_attempted"
        case unknownIdle = "unknown_idle"
        case notIdleLongEnough = "not_idle_long_enough"
        /// The cache lifetime isn't recorded, so "before it expires" can't be
        /// judged.
        case unknownCacheLifetime = "unknown_cache_lifetime"
        /// Too late: compacting now pays the rebuild anyway.
        case cacheExpired = "cache_expired"
        /// `agent_state` isn't `idle` (working, waiting on a permission,
        /// starting, exited, or no agent terminal).
        case agentNotIdle = "agent_not_idle"
    }

    public struct Inputs: Sendable, Equatable {
        public var agentKind: AgentKind
        public var status: SessionStatus
        public var agentState: AgentReadinessState?
        public var snapshot: ContextSnapshot?
        /// The `lastRequestAt` Crow last compacted this session for.
        public var lastAttemptFor: Date?

        public init(
            agentKind: AgentKind, status: SessionStatus, agentState: AgentReadinessState?,
            snapshot: ContextSnapshot?, lastAttemptFor: Date? = nil
        ) {
            self.agentKind = agentKind
            self.status = status
            self.agentState = agentState
            self.snapshot = snapshot
            self.lastAttemptFor = lastAttemptFor
        }
    }

    /// The verdict before the pane is read. A `.compact` here still needs the
    /// composer check (``ClaudeComposer``) right before sending.
    public static func evaluate(
        _ inputs: Inputs, settings: ContextCompactionSettings, now: Date = Date()
    ) -> Verdict {
        guard settings.autoCompact else { return .skip(.disabled) }
        guard inputs.agentKind == .claudeCode else { return .skip(.unsupportedAgent) }
        guard inputs.status == .active || inputs.status == .paused || inputs.status == .inReview else {
            return .skip(.inactiveSession)
        }
        guard let snap = inputs.snapshot else { return .skip(.noTranscript) }
        guard snap.compactedAt == nil else { return .skip(.alreadyCompacted) }
        guard let tokens = snap.tokens, tokens >= settings.effectiveMinContextTokens else {
            return .skip(.belowThreshold)
        }
        guard let last = snap.lastRequestAt, let idle = snap.idleSeconds(now: now) else {
            return .skip(.unknownIdle)
        }
        if let attempted = inputs.lastAttemptFor, attempted >= last { return .skip(.alreadyAttempted) }
        guard idle >= settings.effectiveIdleSeconds else { return .skip(.notIdleLongEnough) }
        guard let ttl = snap.cacheTTL else { return .skip(.unknownCacheLifetime) }
        // A minute of margin: the compaction call has to reach the API before
        // the entry lapses.
        guard idle < ttl - 60 else { return .skip(.cacheExpired) }
        // Checked last: it's the one input that changes second to second.
        guard inputs.agentState == .idle else { return .skip(.agentNotIdle) }
        return .compact
    }
}
