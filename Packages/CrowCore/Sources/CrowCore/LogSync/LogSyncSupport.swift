import Foundation

/// The harness identifiers the Corveil session-artifact contract accepts on the
/// `harness` column / query param (corveil#2426). Mirrors the server-side DB
/// CHECK exactly, so an out-of-set value never reaches the endpoint (it would
/// 400). Crow's own harness roster is larger than this set; anything without a
/// first-class value maps to `.unknown`.
public enum LogSyncHarness: String, Sendable, Equatable, CaseIterable {
    case claude
    case cursor
    case codex
    case opencode
    case unknown

    /// Map a Crow `AgentKind` to the artifact contract's harness value. The four
    /// harnesses the server enumerates map directly; every other kind (Grok,
    /// Antigravity, Muse, or a future one) maps to `.unknown` so the upload is
    /// still accepted and attributed, just not harness-typed.
    public init(agentKind: AgentKind) {
        switch agentKind {
        case .claudeCode: self = .claude
        case .cursor: self = .cursor
        case .codex: self = .codex
        case .openCode: self = .opencode
        default: self = .unknown
        }
    }
}

/// The single artifact kind the contract defines today
/// (`crow_session_artifacts.kind`). A second value arrives with the feature that
/// needs it.
public enum LogSyncArtifactKind: String, Sendable, Equatable {
    case sessionTranscript = "session_transcript"
}

/// The untrusted "sidecar hints" attached to an upload as query parameters
/// (corveil#2426). These are *hints* for the server-side derivation's REFERENCES
/// edges — the server derives attribution from the API key, never from these.
/// Every field is optional; a best-effort uploader may omit any of them.
public struct LogSyncSessionMetadata: Sendable, Equatable {
    public var name: String?
    public var status: String?
    public var agentKind: String?
    public var ticketURL: String?
    public var ticketNumber: Int?
    public var repo: String?
    public var orgGoal: String?

    public init(
        name: String? = nil,
        status: String? = nil,
        agentKind: String? = nil,
        ticketURL: String? = nil,
        ticketNumber: Int? = nil,
        repo: String? = nil,
        orgGoal: String? = nil
    ) {
        self.name = name
        self.status = status
        self.agentKind = agentKind
        self.ticketURL = ticketURL
        self.ticketNumber = ticketNumber
        self.repo = repo
        self.orgGoal = orgGoal
    }
}
