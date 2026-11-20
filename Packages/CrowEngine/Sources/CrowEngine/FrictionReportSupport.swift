import CrowCore
import CrowIPC
import Foundation

/// What Crow can say about Corveil's agent friction report (CROW-1477).
///
/// Corveil is building a recurring report from uploaded session transcripts
/// (corveil/corveil#5601). Its API is not published, so Crow does not model
/// its shape: ``report(_:)`` carries whatever a future source returns,
/// verbatim, and today's only source answers ``unavailable(reason:tracking:)``.
public enum CorveilFrictionReport: Sendable, Equatable {
    /// Crow cannot fetch the report: there is nothing to call yet.
    case unavailable(reason: String, tracking: String)
    /// A report from Corveil, passed through without reshaping. Before a real
    /// source returns this, pick the fields worth handing `/rpc` and MCP (the
    /// way `list_tickets` drops `body`) once #5601's shape is known.
    case report(JSONValue)
}

/// Where the Corveil half of `get-friction-report` comes from. The one seam a
/// real client plugs into once corveil/corveil#5601 publishes an endpoint.
/// A Crow connection can hold several Corveil orgs (ADR 0020), so the real
/// client will need the selected org; `fetch()` takes none yet because the
/// pending source needs nothing and the endpoint's scoping is unknown.
public protocol CorveilFrictionReportSource: Sendable {
    func fetch() async -> CorveilFrictionReport
}

/// The source Crow ships with until corveil/corveil#5601 lands: it never
/// calls the network and always reports the gap.
public struct PendingCorveilFrictionReportSource: CorveilFrictionReportSource {
    public static let tracking = "https://github.com/corveil/corveil/issues/5601"
    public static let reason =
        "Corveil's agent friction report has no published API yet (corveil/corveil#5601). Until it ships, this report covers only the friction items captured in Scratch."

    public init() {}

    public func fetch() async -> CorveilFrictionReport {
        .unavailable(reason: Self.reason, tracking: Self.tracking)
    }
}

/// Pure builders for the `get-friction-report` RPC (CROW-1477).
///
/// The local half is real: Scratch items of kind `friction`, grouped by what
/// happened so a repeat is counted rather than listed twice. The Corveil half
/// is whatever ``CorveilFrictionReportSource`` returns.
public enum FrictionRPC {
    public static let defaultLimit = 10
    public static let maxLimit = 100

    /// Separators between "what happened" and "workaround" in the capture
    /// rule's `[friction] <what happened> — <workaround>`.
    static let workaroundSeparators = [" — ", " – ", " -- "]

    /// The grouping key for a friction item: the text without the
    /// `[friction]` prefix, cut at the first workaround separator found in
    /// preference order (em dash, en dash, then ` -- `) and only that one, so
    /// a ` -- ` inside the symptom survives an em-dash workaround. Lowercased,
    /// whitespace collapsed, trailing punctuation dropped. Two agents that hit
    /// the same missing flag and worked around it differently share a key.
    public static func summary(of text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix(TodoKind.frictionPrefix) {
            body = String(body.dropFirst(TodoKind.frictionPrefix.count))
        }
        for separator in workaroundSeparators {
            if let range = body.range(of: separator) {
                body = String(body[..<range.lowerBound])
                break
            }
        }
        let collapsed = body
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
    }

    public static func summaryKey(of text: String) -> String {
        summary(of: text).lowercased()
    }

    /// An item still waiting on a fix: not done and not dropped.
    public static func isOpen(_ item: TodoItem) -> Bool {
        item.state != .done && item.state != .dropped
    }

    public static func decodeLimit(_ params: [String: JSONValue]) throws -> Int {
        guard let value = params["limit"], value != .null else { return defaultLimit }
        guard let limit = value.intValue, limit >= 1, limit <= maxLimit else {
            throw RPCError.invalidParams("limit must be an integer from 1 to \(maxLimit)")
        }
        return limit
    }

    public static func decodeIncludeClosed(_ params: [String: JSONValue]) throws -> Bool {
        guard let value = params["include_closed"], value != .null else { return false }
        guard let flag = value.boolValue else {
            throw RPCError.invalidParams("include_closed must be a boolean")
        }
        return flag
    }

    /// The local half: friction counts and the top groups.
    public static func localSection(
        _ todos: [TodoItem], limit: Int, includeClosed: Bool
    ) -> JSONValue {
        let friction = todos.filter { $0.kind == .friction }
        let considered = friction.filter { includeClosed || isOpen($0) }

        var byState: [String: JSONValue] = [:]
        for state in TodoState.allCases {
            let n = friction.filter { $0.state == state }.count
            if n > 0 { byState[state.rawValue] = .int(n) }
        }

        // Group newest-first so each group's `summary` is the latest wording.
        var order: [String] = []
        var members: [String: [TodoItem]] = [:]
        for item in considered.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = summaryKey(of: item.text)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(item)
        }
        let ranked = order.sorted { a, b in
            let ca = members[a]!.count, cb = members[b]!.count
            if ca != cb { return ca > cb }
            return members[a]![0].createdAt > members[b]![0].createdAt
        }
        let groups: [JSONValue] = ranked.prefix(limit).map { key in
            let items = members[key]!
            let latest = items[0]
            return .object([
                "summary": .string(summary(of: latest.text)),
                "count": .int(items.count),
                "latest_text": .string(latest.text),
                "latest_at": .string(iso8601(latest.createdAt)),
                "todo_ids": .array(items.map { .string($0.id.uuidString) }),
                "states": .array(Array(Set(items.map(\.state.rawValue))).sorted().map { .string($0) }),
            ])
        }

        return .object([
            "open": .int(friction.filter(isOpen).count),
            "total": .int(friction.count),
            "by_state": .object(byState),
            "group_count": .int(ranked.count),
            "groups": .array(groups),
        ])
    }

    public static func corveilSection(_ report: CorveilFrictionReport) -> JSONValue {
        switch report {
        case .unavailable(let reason, let tracking):
            return .object([
                "available": .bool(false),
                "reason": .string(reason),
                "tracking": .string(tracking),
            ])
        case .report(let body):
            return .object([
                "available": .bool(true),
                "report": body,
            ])
        }
    }

    /// The whole `get-friction-report` payload.
    public static func report(
        todos: [TodoItem],
        corveil: CorveilFrictionReport,
        params: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        let limit = try decodeLimit(params)
        let includeClosed = try decodeIncludeClosed(params)
        return [
            "local": localSection(todos, limit: limit, includeClosed: includeClosed),
            "corveil": corveilSection(corveil),
        ]
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
