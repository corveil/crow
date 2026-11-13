import Foundation

/// Proof that a session's traffic actually reaches the Corveil gateway
/// (CROW-1423, the debug-mode recording indicator).
///
/// "Configured" and even "launched" can disagree with reality: a Manager
/// tagged with one org's workspace can still send its requests under another
/// org's key. Corveil's gateway request log (`GET /api/logs`) stamps every
/// Claude Code request with the Claude **conversation id**
/// (`metadata.request_body_claude_code_session`) — the same id as the
/// transcript file `~/.claude/projects/<slug(cwd)>/<id>.jsonl`. Joining the
/// two answers "did this session's agent talk to the gateway, and under which
/// org/key?" deterministically. No LLM, no heuristics.
///
/// Everything here is pure: decoding a page, the paging stop rule, the index,
/// and the per-session verdict. The daemon does the I/O.
///
/// ⚠️ REDACTION. Only key **ids/names** and org ids/names leave this type —
/// never a key value. Evidence rides `list-sessions`, which remote `/rpc` peers
/// read.
public enum GatewayTraffic {

    // MARK: - Log entries

    /// One gateway request log entry: only the fields the join needs.
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var createdAt: Date
        /// `metadata.request_body_claude_code_session`; nil for non-Claude-Code
        /// traffic (other harnesses don't stamp one).
        public var conversationID: String?
        public var apiKeyID: String?
        public var apiKeyName: String?
        public var organizationID: String?
        public var statusCode: Int?

        public init(
            id: String, createdAt: Date, conversationID: String?, apiKeyID: String? = nil,
            apiKeyName: String? = nil, organizationID: String? = nil, statusCode: Int? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.conversationID = conversationID
            self.apiKeyID = apiKeyID
            self.apiKeyName = apiKeyName
            self.organizationID = organizationID
            self.statusCode = statusCode
        }
    }

    public struct Page: Sendable, Equatable {
        public var entries: [Entry]
        public var nextCursor: String?
    }

    /// Decode one `GET /api/logs` page (`{logs: [...], next_cursor}`). Nil when
    /// the body isn't that shape (an error document, HTML, …). Entries without
    /// an id or a parseable `created_at` are dropped.
    public static func decodePage(_ data: Data) -> Page? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logs = root["logs"] as? [[String: Any]]
        else { return nil }
        let entries: [Entry] = logs.compactMap { log in
            guard let id = log["id"] as? String,
                  let created = (log["created_at"] as? String).flatMap(parseDate)
            else { return nil }
            let meta = log["metadata"] as? [String: Any]
            let conv = (meta?["request_body_claude_code_session"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return Entry(
                id: id, createdAt: created, conversationID: conv,
                apiKeyID: log["api_key_id"] as? String, apiKeyName: log["api_key_name"] as? String,
                organizationID: log["organization_id"] as? String,
                statusCode: log["status_code"] as? Int)
        }
        let cursor = (root["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Page(entries: entries, nextCursor: cursor)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - Paging

    /// The API caps a page at 500, and a larger `limit` silently falls back to
    /// 50, so the reader always asks for exactly this.
    public static let pageSize = 500

    /// Whether to fetch another page: there is a cursor, the page budget isn't
    /// spent, and the page just read still reaches back past `oldestWanted`
    /// (logs are newest first, so once a page's oldest entry is older than
    /// the window, everything after it is too).
    public static func shouldFetchNext(after page: Page, pagesRead: Int, maxPages: Int, oldestWanted: Date) -> Bool {
        guard page.nextCursor != nil, pagesRead < maxPages, !page.entries.isEmpty else { return false }
        let oldest = page.entries.map(\.createdAt).min() ?? .distantPast
        return oldest >= oldestWanted
    }

    // MARK: - Index

    /// Requests seen for one conversation under one key.
    public struct Hit: Sendable, Equatable {
        public var organizationID: String?
        public var apiKeyID: String?
        public var apiKeyName: String?
        public var count: Int
        public var lastAt: Date
    }

    /// One readable org's log window.
    public struct Window: Sendable, Equatable {
        public var organizationID: String
        public var oldest: Date
        public var newest: Date
        public var count: Int
    }

    /// Every conversation's hits, across every org read this pass.
    public struct Index: Sendable, Equatable {
        public var byConversation: [String: [Hit]]
        /// Per org whose log was read (even if it had no Claude Code traffic).
        public var windows: [String: Window]
        public static let empty = Index(byConversation: [:], windows: [:])
    }

    /// Build the index from entries read across any number of orgs. The same
    /// org can be read through two keys (a workspace and the Manager gateway
    /// often share one), so entries are de-duplicated by log id. `readOrgs`
    /// names every org whose log was read this pass, so an org with no traffic
    /// at all still counts as "looked, saw nothing".
    public static func index(entries: [Entry], readOrgs: Set<String>) -> Index {
        var seen = Set<String>()
        var hits: [String: [String: Hit]] = [:]
        var windows: [String: Window] = [:]
        for org in readOrgs {
            windows[org] = Window(organizationID: org, oldest: .distantFuture, newest: .distantPast, count: 0)
        }
        for e in entries where seen.insert(e.id).inserted {
            if let org = e.organizationID {
                var w = windows[org] ?? Window(organizationID: org, oldest: .distantFuture, newest: .distantPast, count: 0)
                w.oldest = min(w.oldest, e.createdAt)
                w.newest = max(w.newest, e.createdAt)
                w.count += 1
                windows[org] = w
            }
            guard let conv = e.conversationID else { continue }
            let slot = (e.organizationID ?? "") + "|" + (e.apiKeyID ?? "")
            var h = hits[conv]?[slot] ?? Hit(organizationID: e.organizationID, apiKeyID: e.apiKeyID,
                                             apiKeyName: e.apiKeyName, count: 0, lastAt: .distantPast)
            h.count += 1
            h.lastAt = max(h.lastAt, e.createdAt)
            hits[conv, default: [:]][slot] = h
        }
        return Index(
            byConversation: hits.mapValues { $0.values.sorted { $0.lastAt > $1.lastAt } },
            windows: windows)
    }

    // MARK: - Verdict

    /// The gateway identity a session is expected to send under: the org (and,
    /// when Crow minted it, the key id) its resolved gateway belongs to.
    public struct Expected: Sendable, Equatable {
        public var organizationID: String
        public var organizationName: String
        /// Empty for a key adopted by `link-gateway` (no id recorded).
        public var apiKeyID: String

        public init(organizationID: String, organizationName: String, apiKeyID: String) {
            self.organizationID = organizationID
            self.organizationName = organizationName
            self.apiKeyID = apiKeyID
        }
    }

    /// One of a session's conversations and when its agent was last active:
    /// the transcript's newest timestamped entry (`TranscriptActivity`), not
    /// its mtime (CROW-1449).
    public struct Conversation: Sendable, Equatable {
        public var id: String
        public var lastWrite: Date?
        public init(id: String, lastWrite: Date?) {
            self.id = id
            self.lastWrite = lastWrite
        }
    }

    public enum State: String, Sendable, Equatable {
        /// Requests seen, all under the expected org/key (or no expectation to
        /// contradict).
        case verified
        /// Requests seen under a different org or key than the session's
        /// resolved gateway.
        case mismatch
        /// The agent wrote its transcript inside a window we could read for its
        /// expected org, yet no request carried its conversation id.
        case silent
        /// The logs that would prove it weren't readable this pass.
        case unavailable
        /// Nothing to say: not Claude Code, no conversations, or no activity
        /// inside the window.
        case none
    }

    public struct Evidence: Sendable, Equatable {
        public var state: State
        public var count: Int
        public var lastAt: Date?
        /// Where the requests landed (the most recent hit).
        public var seenOrganizationID: String?
        public var seenOrganizationName: String?
        public var seenAPIKeyID: String?
        public var seenAPIKeyName: String?
        public var expectedOrganizationName: String?
        public var detail: String
    }

    /// The verdict for one session.
    ///
    /// - Parameters:
    ///   - conversations: the session's Claude Code conversations (Managers:
    ///     `managerConversations`; others: the transcript files in the
    ///     worktree's project folder), each with its transcript mtime.
    ///   - expected: the org/key of the session's resolved gateway, when the
    ///     gateway is one the Corveil connection manages; nil otherwise.
    ///   - throughGateway: the session launched (or is configured) to go
    ///     through a gateway, so silence is meaningful.
    ///   - orgNames: org id → display name.
    public static func evidence(
        conversations: [Conversation], index: Index, expected: Expected?,
        throughGateway: Bool, orgNames: [String: String], now: Date
    ) -> Evidence {
        func name(_ org: String?) -> String? {
            guard let org else { return nil }
            return orgNames[org] ?? String(org.prefix(8))
        }
        var none = Evidence(state: .none, count: 0, lastAt: nil, detail: "")
        none.expectedOrganizationName = expected?.organizationName
        guard !conversations.isEmpty else {
            none.detail = "No Claude Code conversation found for this session"
            return none
        }
        let hits = conversations.flatMap { index.byConversation[$0.id] ?? [] }
        if !hits.isEmpty {
            let total = hits.reduce(0) { $0 + $1.count }
            let latest = hits.max { $0.lastAt < $1.lastAt }!
            let wrong = expected.map { exp in
                hits.filter { h in
                    h.organizationID != exp.organizationID
                        || (!exp.apiKeyID.isEmpty && h.apiKeyID != nil && h.apiKeyID != exp.apiKeyID)
                }
            } ?? []
            let shown = wrong.max { $0.lastAt < $1.lastAt } ?? latest
            var ev = Evidence(
                state: wrong.isEmpty ? .verified : .mismatch, count: total, lastAt: latest.lastAt,
                seenOrganizationID: shown.organizationID, seenOrganizationName: name(shown.organizationID),
                seenAPIKeyID: shown.apiKeyID, seenAPIKeyName: shown.apiKeyName,
                expectedOrganizationName: expected?.organizationName, detail: "")
            let keyLabel = shown.apiKeyName.map { "key \"\($0)\"" } ?? "an unnamed key"
            let seenOrg = ev.seenOrganizationName ?? "an unknown org"
            if let expected, !wrong.isEmpty {
                let wrongCount = wrong.reduce(0) { $0 + $1.count }
                ev.detail = "\(wrongCount) of \(total) requests went to \(seenOrg) (\(keyLabel)), "
                    + "but this session's gateway belongs to \(expected.organizationName). "
                    + "Last seen \(RecordingStatus.ago(shown.lastAt.timeIntervalSince1970, now))."
            } else {
                let unlinked = expected == nil ? " (gateway isn't linked to the Corveil connection, so the org wasn't checked)" : ""
                ev.detail = "Verified: \(total) request\(total == 1 ? "" : "s") in \(seenOrg) (\(keyLabel)), "
                    + "last \(RecordingStatus.ago(latest.lastAt.timeIntervalSince1970, now))\(unlinked)"
            }
            return ev
        }

        // No hits. Silence only means something when the expected org's log
        // was read and its window covers the agent's last activity.
        guard throughGateway else {
            none.detail = "No gateway requests seen (not launched through a gateway)"
            return none
        }
        guard let expected else {
            var ev = none
            ev.state = .unavailable
            ev.detail = "Can't verify: this gateway isn't linked to the Corveil connection, so there's no org log to check"
            return ev
        }
        guard let window = index.windows[expected.organizationID] else {
            var ev = none
            ev.state = .unavailable
            ev.detail = "Can't verify: \(expected.organizationName)'s request log wasn't readable this pass"
            return ev
        }
        let lastWrite = conversations.compactMap(\.lastWrite).max()
        let windowStart = window.count > 0 ? window.oldest : now
        guard let lastWrite, lastWrite >= windowStart else {
            none.detail = "No activity inside the request-log window (\(window.count) requests read from \(expected.organizationName))"
            return none
        }
        var ev = none
        ev.state = .silent
        ev.detail = "The agent was active \(RecordingStatus.ago(lastWrite.timeIntervalSince1970, now)), "
            + "but none of \(window.count) recent \(expected.organizationName) requests carry its conversation id. "
            + "Its traffic isn't reaching that gateway."
        return ev
    }
}

/// The verifier's latest per-session evidence, in memory (rebuilt every log-sync
/// tick, ~5 min).
public final class GatewayTrafficBoard: @unchecked Sendable {
    public static let shared = GatewayTrafficBoard()

    /// How the last pass went, for the tooltip and the PR's answer to "can a
    /// gateway key read logs?".
    public struct SourceStatus: Sendable, Equatable {
        public var label: String
        public var readable: Bool
        public var note: String
        public init(label: String, readable: Bool, note: String) {
            self.label = label
            self.readable = readable
            self.note = note
        }
    }

    private let lock = NSLock()
    private var evidence: [UUID: GatewayTraffic.Evidence] = [:]
    private var sources: [SourceStatus] = []
    private var at: Date?

    public init() {}

    public func replace(_ evidence: [UUID: GatewayTraffic.Evidence], sources: [SourceStatus], at: Date) {
        lock.withLock {
            self.evidence = evidence
            self.sources = sources
            self.at = at
        }
    }

    public func evidence(for id: UUID) -> GatewayTraffic.Evidence? {
        lock.withLock { evidence[id] }
    }

    public func lastPass() -> (sources: [SourceStatus], at: Date?) {
        lock.withLock { (sources, at) }
    }
}
