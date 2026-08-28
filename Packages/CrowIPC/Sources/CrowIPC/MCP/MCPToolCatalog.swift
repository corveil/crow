import CrowCore
import Foundation

/// How a tool reaches the daemon: the same `(method, params) -> result` shape
/// `CommandRouter.Handler` has, so the daemon can pass its router straight in and
/// the CLI can pass a Unix-socket round trip.
public typealias MCPInvoke = @Sendable (String, [String: JSONValue]) async throws -> [String: JSONValue]

/// One MCP tool.
public struct MCPTool: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    /// The single scope a caller must hold to see *or* call this tool.
    public let scope: MCPScope
    /// Every RPC method this tool reads. Gated against `ParityLedger` by
    /// `MCPLedgerExportTests`, so a tool cannot quietly start reading a method
    /// nobody approved for export.
    public let backingMethods: Set<String>
    public let run: @Sendable ([String: JSONValue], @escaping MCPInvoke) async throws -> JSONValue

    public var definitionJSON: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

/// An input the model got wrong — surfaced as a tool execution error
/// (`isError: true`) rather than a protocol error, so the model can self-correct.
public struct MCPToolInputError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The **closed allowlist** of everything MCP can reach (CROW-1004).
///
/// This is the security boundary, and it is an allowlist by construction: there is
/// no passthrough tool, no "call any RPC" escape hatch, and no way to name a method
/// from the wire. A caller can invoke exactly the methods named in some tool's
/// `backingMethods`, with parameters this file builds.
///
/// That is what keeps the local-only RPCs (`gateway-*`, `web-password-*`,
/// `run-setup`, `hook-event`, `open-in-vscode`/`open-terminal`) unreachable over MCP
/// on **both** transports — including the stdio bridge, which speaks to the daemon
/// over the Unix socket and therefore bypasses
/// `RPCWebSocketHandler.localOnlyDenial` entirely. The gate there is this list, not
/// the transport.
///
/// v1 is read-only. Every tool here reads; none writes. `MCPLedgerExportTests`
/// fails the build if a `backingMethods` entry is ledgered `isWrite`.
public enum MCPToolCatalog {

    /// Every tool, in a stable order. The spec asks for deterministic ordering so
    /// clients can cache the list and prompt caches stay warm.
    public static let all: [MCPTool] = [
        boardSummary, listSessions, getSession, listStuckSessions, listTickets, listReviews,
    ]

    /// The tools a caller holding `scopes` may see and call.
    ///
    /// This filters `tools/list`, not just `tools/call` — a deny-after-call still
    /// teaches the model that a tool exists, which is the leak the ticket is closing.
    /// The spec explicitly permits varying the set by authorization: credentials are
    /// per-request input, not connection state.
    public static func tools(for scopes: Set<MCPScope>) -> [MCPTool] {
        all.filter { scopes.contains($0.scope) }
    }

    /// Look up a tool the caller is allowed to use. Returns nil both when the tool
    /// does not exist and when the caller's scopes do not cover it — deliberately
    /// indistinguishable, so probing `tools/call` cannot enumerate what is hidden.
    public static func tool(named name: String, scopes: Set<MCPScope>) -> MCPTool? {
        tools(for: scopes).first { $0.name == name }
    }

    /// Every method reachable through some tool — the export set the ledger gates.
    public static var exportedMethods: Set<String> {
        all.reduce(into: Set<String>()) { $0.formUnion($1.backingMethods) }
    }

    // MARK: - Tools

    static let boardSummary = MCPTool(
        name: "get_board_summary",
        title: "Crow board summary",
        description: """
            Counts of Crow sessions by status (active, inReview, paused, completed, \
            archived), with the session names under each. Start here to get the shape \
            of the board before drilling into a specific session.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "include_managers": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Include Manager sessions in the counts. Defaults to false — a Manager is Crow's own orchestrator, not a unit of work."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        scope: .sessionsRead,
        backingMethods: ["list-sessions"],
        run: { arguments, invoke in
            let includeManagers = arguments["include_managers"]?.boolValue ?? false
            let rows = try await sessionRows(invoke)
                .filter { includeManagers || $0["kind"]?.stringValue != "manager" }

            var byStatus: [String: [JSONValue]] = [:]
            for row in rows {
                let status = row["status"]?.stringValue ?? "unknown"
                byStatus[status, default: []].append(.string(row["name"]?.stringValue ?? ""))
            }
            var counts: [String: JSONValue] = [:]
            var names: [String: JSONValue] = [:]
            for (status, sessionNames) in byStatus {
                counts[status] = .int(sessionNames.count)
                names[status] = .array(sessionNames)
            }
            return .object([
                "total": .int(rows.count),
                "counts": .object(counts),
                "names": .object(names),
            ])
        })

    static let listSessions = MCPTool(
        name: "list_sessions",
        title: "List Crow sessions",
        description: """
            Crow sessions with their status, agent, linked ticket and worktree. \
            Filter by status or kind. Use get_session for one session's full detail.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("string"),
                    "enum": .array(sessionStatuses.map { .string($0) }),
                    "description": .string("Only sessions in this status."),
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(sessionKinds.map { .string($0) }),
                    "description": .string("Only sessions of this kind."),
                ]),
                "limit": limitSchema(default: 50),
            ]),
            "additionalProperties": .bool(false),
        ]),
        scope: .sessionsRead,
        backingMethods: ["list-sessions"],
        run: { arguments, invoke in
            let status = try optionalEnum(arguments, "status", allowed: sessionStatuses)
            let kind = try optionalEnum(arguments, "kind", allowed: sessionKinds)
            let limit = try limit(from: arguments, default: 50)

            let rows = try await sessionRows(invoke)
                .filter { status == nil || $0["status"]?.stringValue == status }
                .filter { kind == nil || $0["kind"]?.stringValue == kind }

            let trimmed = rows.prefix(limit).map { row in
                JSONValue.object(pick(row, sessionSummaryFields))
            }
            return .object([
                "sessions": .array(Array(trimmed)),
                "returned": .int(trimmed.count),
                "total_matching": .int(rows.count),
            ])
        })

    static let getSession = MCPTool(
        name: "get_session",
        title: "Get one Crow session",
        description: """
            One session in full: status, agent, linked ticket, timestamps, org goal, \
            and which workspace gateway it launches with. Takes the session UUID from \
            list_sessions.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "session_id": .object([
                    "type": .string("string"),
                    "description": .string("Session UUID, as returned by list_sessions."),
                ]),
            ]),
            "required": .array([.string("session_id")]),
            "additionalProperties": .bool(false),
        ]),
        scope: .sessionsRead,
        backingMethods: ["get-session"],
        run: { arguments, invoke in
            guard let sessionID = arguments["session_id"]?.stringValue, !sessionID.isEmpty else {
                throw MCPToolInputError("session_id is required")
            }
            guard UUID(uuidString: sessionID) != nil else {
                throw MCPToolInputError(
                    "session_id must be a UUID (got \"\(sessionID)\") — use the id from list_sessions, not the session name")
            }
            // Passthrough. `get-session` is already written to be safe for a remote
            // reader: it reports `gateway_set` plus a base URL and never the gateway
            // header values, which stay behind the local-only `gateway-get`.
            let result = try await invoke("get-session", ["session_id": .string(sessionID)])
            return .object(result)
        })

    static let listStuckSessions = MCPTool(
        name: "list_stuck_sessions",
        title: "List stuck Crow sessions",
        description: """
            Sessions that need a human: waiting on input, failing checks, auto-merge \
            blocked or stalled, auto-rebase stuck, or idle beyond a threshold. Each \
            row explains why, so this is the tool to reach for when asked what needs \
            attention.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "min_idle_minutes": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string(
                        "How long a session must have been waiting on input before it also counts as idle_too_long. Defaults to 60."),
                ]),
                "include_managers": .object([
                    "type": .string("boolean"),
                    "description": .string("Include Manager sessions. Defaults to false."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        scope: .sessionsRead,
        // A genuine join: the two payloads are disjoint. `list-sessions` carries
        // activity/attention; `list-sessions-live` carries pr/auto_merge_state/
        // auto_rebase_state. Neither alone can answer "what is stuck".
        backingMethods: ["list-sessions", "list-sessions-live"],
        run: { arguments, invoke in
            let idleMinutes = try nonNegativeInt(arguments, "min_idle_minutes", default: 60)
            let includeManagers = arguments["include_managers"]?.boolValue ?? false

            let rows = try await sessionRows(invoke)
            let live = (try await invoke("list-sessions-live", [:]))["sessions"]?.objectValue ?? [:]
            let now = Date()

            var stuck: [JSONValue] = []
            for row in rows {
                guard includeManagers || row["kind"]?.stringValue != "manager" else { continue }
                // A finished session cannot be stuck; it is finished.
                let status = row["status"]?.stringValue ?? ""
                guard status != "completed", status != "archived" else { continue }
                guard let id = row["id"]?.stringValue else { continue }

                let entry = live[id]?.objectValue ?? [:]
                let reasons = stuckReasons(row: row, live: entry, idleMinutes: idleMinutes, now: now)
                guard !reasons.isEmpty else { continue }

                var out = pick(row, sessionSummaryFields)
                out["reasons"] = .array(reasons.map { .object($0) })
                stuck.append(.object(out))
            }
            return .object([
                "sessions": .array(stuck),
                "returned": .int(stuck.count),
                "min_idle_minutes": .int(idleMinutes),
            ])
        })

    static let listTickets = MCPTool(
        name: "list_tickets",
        title: "List the Crow ticket board",
        description: """
            Open issues on the Crow ticket board, with their repo, state, labels, PR \
            link and check status. A row whose linked_session_id is null is one \
            nothing is working yet.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "unassigned_only": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Only issues with no Crow session working them (linked_session_id is null). Defaults to false."),
                ]),
                "limit": limitSchema(default: 50),
            ]),
            "additionalProperties": .bool(false),
        ]),
        scope: .boardRead,
        backingMethods: ["list-tickets"],
        run: { arguments, invoke in
            let limit = try limit(from: arguments, default: 50)
            let unassignedOnly = arguments["unassigned_only"]?.boolValue ?? false

            let result = try await invoke("list-tickets", [:])
            var issues = (result["issues"]?.arrayValue ?? []).compactMap(\.objectValue)
            if unassignedOnly {
                issues = issues.filter { $0["linked_session_id"] ?? .null == .null }
            }
            // `body` is the one unbounded field in this payload — a single long
            // issue body can dominate the model's context and crowd out the rest of
            // the board. Everything else is a scalar, so dropping just this keeps
            // the tool usable at 50 rows.
            let trimmed = issues.prefix(limit).map { JSONValue.object(pick($0, ticketFields)) }
            return .object([
                "issues": .array(Array(trimmed)),
                "returned": .int(trimmed.count),
                "total_matching": .int(issues.count),
                "counts": result["counts"] ?? .object([:]),
                "done_last_24h": result["done_last_24h"] ?? .int(0),
                "loading": result["loading"] ?? .bool(false),
                "note": .string("Issue bodies are omitted; open the url for the full text."),
            ])
        })

    static let listReviews = MCPTool(
        name: "list_reviews",
        title: "List the Crow reviews board",
        description: """
            Pull requests on the Crow reviews board, grouped as in_review, \
            not_approved_yet, waiting_on_author, or recently_completed. Every field is \
            bounded, so this is safe to call unfiltered.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "group": .object([
                    "type": .string("string"),
                    "enum": .array(reviewGroups.map { .string($0) }),
                    "description": .string("Only reviews in this board group."),
                ]),
                "limit": limitSchema(default: 50),
            ]),
            "additionalProperties": .bool(false),
        ]),
        scope: .boardRead,
        backingMethods: ["list-reviews"],
        run: { arguments, invoke in
            let group = try optionalEnum(arguments, "group", allowed: reviewGroups)
            let limit = try limit(from: arguments, default: 50)

            let result = try await invoke("list-reviews", [:])
            var reviews = (result["reviews"]?.arrayValue ?? []).compactMap(\.objectValue)
            if let group {
                reviews = reviews.filter { $0["group"]?.stringValue == group }
            }
            let trimmed = reviews.prefix(limit).map { JSONValue.object($0) }
            return .object([
                "reviews": .array(Array(trimmed)),
                "returned": .int(trimmed.count),
                "total_matching": .int(reviews.count),
                "group_counts": result["group_counts"] ?? .object([:]),
                "group_order": result["group_order"] ?? .array([]),
                "hidden_by_filters": result["hidden_by_filters"] ?? .int(0),
                "loading": result["loading"] ?? .bool(false),
            ])
        })

    // MARK: - Shared vocabulary

    /// Mirrors `SessionStatus` / `SessionKind`. Restated rather than derived from
    /// the enums so the JSON Schema shown to a model stays stable if a case is ever
    /// added for internal use — and `MCPToolCatalogTests` pins them equal, so this
    /// cannot drift silently.
    static let sessionStatuses = ["active", "paused", "inReview", "completed", "archived"]
    static let sessionKinds = ["work", "review", "job", "manager"]
    static let reviewGroups = [
        "in_review", "not_approved_yet", "waiting_on_author", "recently_completed",
    ]

    /// The subset of a `list-sessions` row worth handing a model. Drops the
    /// browser-only rendering fields (`agent_display_name`, `ticket_badge`,
    /// `can_set_project_status`, `labels`, `links`).
    static let sessionSummaryFields = [
        "id", "name", "status", "kind", "agent_kind", "locked", "auto_merge",
        "ticket_title", "ticket_url", "ticket_state", "provider", "review_author",
        "org_goal", "repo", "branch", "worktree_path", "activity", "attention",
        "attention_since", "is_explore",
    ]

    /// Every `list-tickets` field except `body`.
    static let ticketFields = [
        "id", "number", "title", "state", "url", "repo", "provider", "pr_number",
        "pr_url", "updated_at", "project_status", "labels", "author", "created_at",
        "comments_count", "pr_state", "checks", "linked_session_id",
        "linked_session_is_explore",
    ]

    // MARK: - Helpers

    private static func sessionRows(_ invoke: @escaping MCPInvoke) async throws -> [[String: JSONValue]] {
        let result = try await invoke("list-sessions", [:])
        return (result["sessions"]?.arrayValue ?? []).compactMap(\.objectValue)
    }

    /// Keep only `fields`, and only those actually present — so an absent optional
    /// stays absent rather than becoming an explicit null the model has to reason
    /// about.
    static func pick(_ object: [String: JSONValue], _ fields: [String]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for field in fields {
            if let value = object[field] { out[field] = value }
        }
        return out
    }

    static func limitSchema(default value: Int) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .int(1),
            "maximum": .int(maxLimit),
            "description": .string("Maximum rows to return. Defaults to \(value), capped at \(maxLimit)."),
        ])
    }

    static let maxLimit = 200

    static func limit(from arguments: [String: JSONValue], default value: Int) throws -> Int {
        guard let raw = arguments["limit"] else { return value }
        guard let n = raw.intValue else {
            throw MCPToolInputError("limit must be an integer")
        }
        guard n >= 1 else { throw MCPToolInputError("limit must be at least 1") }
        return min(n, maxLimit)
    }

    static func nonNegativeInt(
        _ arguments: [String: JSONValue], _ key: String, default value: Int
    ) throws -> Int {
        guard let raw = arguments[key] else { return value }
        guard let n = raw.intValue, n >= 0 else {
            throw MCPToolInputError("\(key) must be a non-negative integer")
        }
        return n
    }

    /// Validate an optional enum argument here rather than letting it silently match
    /// nothing downstream — "no sessions are inReviewww" is a much worse answer than
    /// "inReviewww is not a status".
    static func optionalEnum(
        _ arguments: [String: JSONValue], _ key: String, allowed: [String]
    ) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value = raw.stringValue else {
            throw MCPToolInputError("\(key) must be a string")
        }
        guard allowed.contains(value) else {
            throw MCPToolInputError("\(key) must be one of: \(allowed.joined(separator: ", "))")
        }
        return value
    }

    /// Why one session counts as stuck. Empty means it doesn't.
    static func stuckReasons(
        row: [String: JSONValue],
        live: [String: JSONValue],
        idleMinutes: Int,
        now: Date
    ) -> [[String: JSONValue]] {
        var reasons: [[String: JSONValue]] = []

        let activity = row["activity"]?.stringValue
        let attention = row["attention"]?.stringValue
        if activity == "waiting" || (attention?.isEmpty == false) {
            var reason: [String: JSONValue] = [
                "reason": .string("waiting_on_input"),
                "detail": .string(attention ?? "agent is waiting"),
            ]
            if let since = row["attention_since"]?.stringValue {
                reason["since"] = .string(since)
            }
            reasons.append(reason)

            // Idle is a *duration* on top of waiting, not a separate condition —
            // reported only when we know when the wait started. `attention_since`
            // rides on `list-sessions`; without it there is nothing to measure and
            // claiming "idle" would be a guess.
            if let since = row["attention_since"]?.stringValue,
               let waitingSince = ISO8601DateFormatter().date(from: since),
               now.timeIntervalSince(waitingSince) >= Double(idleMinutes) * 60 {
                let minutes = Int(now.timeIntervalSince(waitingSince) / 60)
                reasons.append([
                    "reason": .string("idle_too_long"),
                    "detail": .string("waiting for \(minutes) minutes"),
                    "since": .string(since),
                ])
            }
        }

        if let pr = live["pr"]?.objectValue, pr["has_pr"]?.boolValue == true {
            let failed = (pr["failed_checks"]?.arrayValue ?? []).compactMap(\.stringValue)
            if pr["checks"]?.stringValue == "failing" || !failed.isEmpty {
                reasons.append([
                    "reason": .string("checks_failing"),
                    "detail": .string(
                        failed.isEmpty ? "checks are failing" : "failing: \(failed.joined(separator: ", "))"),
                ])
            }
        }

        // `AutoMergeState.Phase` has enabled/merged/blocked/stalled/off; only the
        // last two mean nothing is moving. `AutoRebaseState.Phase` has only
        // stalled/blocked — silence there means fine.
        if let reason = watcherReason(live["auto_merge_state"], kind: "auto_merge_stuck",
                                      stuckPhases: ["blocked", "stalled"]) {
            reasons.append(reason)
        }
        if let reason = watcherReason(live["auto_rebase_state"], kind: "auto_rebase_stuck",
                                      stuckPhases: ["blocked", "stalled"]) {
            reasons.append(reason)
        }
        return reasons
    }

    private static func watcherReason(
        _ state: JSONValue?, kind: String, stuckPhases: [String]
    ) -> [String: JSONValue]? {
        guard let state = state?.objectValue,
              let phase = state["phase"]?.stringValue,
              stuckPhases.contains(phase)
        else { return nil }
        var reason: [String: JSONValue] = ["reason": .string(kind), "phase": .string(phase)]
        if let message = state["message"]?.stringValue, !message.isEmpty {
            reason["detail"] = .string(message)
        } else if let why = state["reason"]?.stringValue, !why.isEmpty {
            reason["detail"] = .string(why)
        }
        if let permanent = state["permanent"]?.boolValue {
            reason["permanent"] = .bool(permanent)
        }
        return reason
    }
}
