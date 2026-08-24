import Foundation

/// Crow's internal identifier for the harness that wrote a session transcript
/// (corveil#2426). It drives the local ledger slot, the backfill row's display,
/// and the `format` / `agentKind` derivation — so a Claude, a Codex, and a Grok
/// session are all distinguishable even though several of them collapse to the
/// same value on the wire.
///
/// The **wire** value sent to the server (`wireValue`) is a strict subset — the
/// server-side DB CHECK on `crow_session_artifacts.harness`
/// (`claude`/`cursor`/`codex`/`opencode`/`unknown`). A harness the server does
/// not yet enumerate (`.grok`) carries its own rawValue internally but sends
/// `unknown` on the wire, so the upload is still accepted and attributed, just
/// not harness-typed. Every other case's `wireValue` equals its `rawValue`.
public enum LogSyncHarness: String, Sendable, Equatable, Codable, CaseIterable {
    case claude
    case cursor
    case codex
    case opencode
    /// Grok Build (CROW-1098). Internal-only: `wireValue` collapses it to
    /// `unknown` because the server's CHECK does not (yet) accept `grok`.
    case grok
    case unknown

    /// The value accepted by the server's `harness` CHECK (corveil#2426). Cases
    /// the server enumerates pass through their rawValue; a not-yet-recognized
    /// harness (`.grok`) collapses to `unknown`. Keep this in sync with the DB
    /// CHECK: when the server adds `grok`, drop it from the collapse list.
    public var wireValue: String {
        switch self {
        case .grok: return LogSyncHarness.unknown.rawValue
        case .claude, .cursor, .codex, .opencode, .unknown: return rawValue
        }
    }

    /// Map a Crow `AgentKind` to its harness identifier. The four harnesses the
    /// server enumerates map directly, and Grok maps to its internal `.grok`
    /// (wire-collapsed to `unknown`); every other kind (Antigravity, Muse, or a
    /// future one) maps to `.unknown` so the upload is still accepted and
    /// attributed, just not harness-typed.
    public init(agentKind: AgentKind) {
        switch agentKind {
        case .claudeCode: self = .claude
        case .cursor: self = .cursor
        case .codex: self = .codex
        case .openCode: self = .opencode
        case .grok: self = .grok
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
