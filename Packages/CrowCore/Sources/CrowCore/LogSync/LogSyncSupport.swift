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
/// not yet enumerate (`.grok`, `.antigravity`, `.muse`) carries its own rawValue
/// internally but sends `unknown` on the wire, so the upload is still accepted and
/// attributed, just not harness-typed. Every other case's `wireValue` equals its
/// `rawValue`.
public enum LogSyncHarness: String, Sendable, Equatable, Codable, CaseIterable {
    case claude
    case cursor
    case codex
    case opencode
    /// Grok Build (CROW-1098). Internal-only: `wireValue` collapses it to
    /// `unknown` because the server's CHECK does not (yet) accept `grok`.
    case grok
    /// Antigravity (CROW-1107). Internal-only, exactly like `.grok`: `wireValue`
    /// collapses it to `unknown` because the server's CHECK does not (yet) accept
    /// `antigravity` (corveil#2426). Carrying the real case internally still lets
    /// it drive a distinct ledger slot and backfill-row display.
    case antigravity
    /// Muse Code (CROW-1106). Internal-only, like `.grok`: `wireValue` collapses
    /// it to `unknown` because the server's CHECK does not (yet) accept `muse`
    /// (coordinate corveil#2426 to add it, then drop it from the collapse list).
    case muse
    case unknown

    /// The value accepted by the server's `harness` CHECK (corveil#2426). Cases
    /// the server enumerates pass through their rawValue; a not-yet-recognized
    /// harness (`.grok`, `.antigravity`, `.muse`) collapses to `unknown`. Keep this
    /// in sync with the DB CHECK: when the server adds one, drop it from the collapse
    /// list.
    public var wireValue: String {
        switch self {
        case .grok, .antigravity, .muse: return LogSyncHarness.unknown.rawValue
        case .claude, .cursor, .codex, .opencode, .unknown: return rawValue
        }
    }

    /// Map a Crow `AgentKind` to its harness identifier. The four harnesses the
    /// server enumerates map directly; Grok, Antigravity, and Muse map to their
    /// internal cases (all wire-collapsed to `unknown`); every other kind (a future
    /// one) maps to `.unknown` so the upload is still accepted and attributed, just
    /// not harness-typed.
    public init(agentKind: AgentKind) {
        switch agentKind {
        case .claudeCode: self = .claude
        case .cursor: self = .cursor
        case .codex: self = .codex
        case .openCode: self = .opencode
        case .grok: self = .grok
        case .antigravity: self = .antigravity
        case .muse: self = .muse
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
    /// The pull request the session PRODUCED (CROW-1115) — the write-side of
    /// Corveil's AgentSession PR-outcome scoring. Populated from the PR Crow
    /// actually opened for the session's branch, so an *issue-linked* session
    /// carries its PR too, not only one whose ticket URL is itself a `/pull/`
    /// link. Corveil reads these as the `crow_sessions.pr_url`/`pr_number`
    /// sidecar (migration 0249 / corveil#2569) and attaches a direct
    /// `PRODUCED → PullRequest` edge, letting the session score its PR's real
    /// state instead of `no_pr`. Optional like every other hint.
    public var prURL: String?
    public var prNumber: Int?
    public var repo: String?
    public var orgGoal: String?

    public init(
        name: String? = nil,
        status: String? = nil,
        agentKind: String? = nil,
        ticketURL: String? = nil,
        ticketNumber: Int? = nil,
        prURL: String? = nil,
        prNumber: Int? = nil,
        repo: String? = nil,
        orgGoal: String? = nil
    ) {
        self.name = name
        self.status = status
        self.agentKind = agentKind
        self.ticketURL = ticketURL
        self.ticketNumber = ticketNumber
        self.prURL = prURL
        self.prNumber = prNumber
        self.repo = repo
        self.orgGoal = orgGoal
    }
}
