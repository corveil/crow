import Foundation
import CrowCore

#if canImport(SQLite3)
import SQLite3
#endif

/// Thread-safe SQLite storage for telemetry data.
///
/// Uses the system SQLite3 C API (available on macOS without external dependencies).
/// All access is serialized through the actor.
public actor TelemetryDatabase {
    private var db: OpaquePointer?
    private let path: String

    /// Identifies a unique metric series: the attributes JSON is stable because
    /// the receiver encodes it with sorted keys.
    private struct MetricSeriesKey: Hashable {
        let sessionID: String
        let metricName: String
        let attributesJSON: String?
    }

    /// Last cumulative value seen per series — NOT the stored-delta sum; the two
    /// diverge after a counter reset (prev=100, curr=5 → delta 5, stored sum 105,
    /// but the next reading must diff against 5).
    private var lastCumulativeValues: [MetricSeriesKey: Double] = [:]

    public init(path: String) {
        self.path = path
    }

    // MARK: - Lifecycle

    public func open() throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw TelemetryDatabaseError.openFailed(msg)
        }
        // Enable WAL mode for better concurrent read performance
        execute("PRAGMA journal_mode=WAL")
        try createTables()
    }

    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Schema

    private func createTables() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS session_map (
                claude_session_id TEXT PRIMARY KEY,
                crow_session_id TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                crow_session_id TEXT NOT NULL,
                metric_name TEXT NOT NULL,
                value REAL NOT NULL,
                attributes_json TEXT,
                timestamp_ns TEXT,
                received_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_metrics_session ON metrics(crow_session_id)",
            "CREATE INDEX IF NOT EXISTS idx_metrics_name ON metrics(metric_name)",
            """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                crow_session_id TEXT NOT NULL,
                event_name TEXT NOT NULL,
                body TEXT,
                attributes_json TEXT,
                severity_number INTEGER,
                timestamp_ns TEXT,
                received_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_events_session ON events(crow_session_id)",
        ]

        for sql in statements {
            guard execute(sql) else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
                throw TelemetryDatabaseError.schemaFailed(msg)
            }
        }
    }

    // MARK: - Writes

    public func registerSessionMapping(claudeSessionID: String, crowSessionID: UUID) {
        let sql = """
            INSERT OR IGNORE INTO session_map (claude_session_id, crow_session_id, created_at)
            VALUES (?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (claudeSessionID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (crowSessionID.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// Insert a metric datapoint, normalizing CUMULATIVE sums to deltas so that
    /// downstream SUM() aggregation stays correct. DELTA sums and gauges
    /// (`.unspecified`) are stored as-is. `receivedAt` is injectable so tests
    /// can exercise the `received_at`-windowed queries and retention pruning.
    public func insertMetric(
        crowSessionID: UUID,
        metricName: String,
        value: Double,
        attributesJSON: String?,
        timestampNs: String?,
        temporality: OTLPAggregationTemporality = .unspecified,
        isMonotonic: Bool? = nil,
        receivedAt: Date = Date()
    ) {
        var insertValue = value
        if temporality == .cumulative {
            let key = MetricSeriesKey(
                sessionID: crowSessionID.uuidString,
                metricName: metricName,
                attributesJSON: attributesJSON
            )
            // App-restart recovery: stored deltas sum to the last cumulative value
            // seen. Exact unless a counter reset preceded the restart — a rare
            // overlap whose over-count is bounded by the counter value at restart;
            // accepted rather than persisting per-series state.
            let prev = lastCumulativeValues[key] ?? storedSeriesSum(
                session: key.sessionID,
                metricName: metricName,
                attributesJSON: attributesJSON
            )
            var delta = value - prev
            // nil isMonotonic is treated as monotonic — every claude_code sum of
            // interest is a monotonic counter. Non-monotonic (UpDownCounter)
            // series legitimately go negative and get no reset clamp.
            if delta < 0 && isMonotonic != false {
                // Counter reset (e.g. Claude Code restarted): count from 0.
                delta = value
            }
            lastCumulativeValues[key] = value
            guard delta != 0 else { return }
            insertValue = delta
        }

        let sql = """
            INSERT INTO metrics (crow_session_id, metric_name, value, attributes_json, timestamp_ns, received_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (crowSessionID.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (metricName as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, insertValue)
        if let json = attributesJSON {
            sqlite3_bind_text(stmt, 4, (json as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let ts = timestampNs {
            sqlite3_bind_text(stmt, 5, (ts as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, receivedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// `receivedAt` is injectable so tests can exercise the
    /// `received_at`-windowed queries and retention pruning.
    public func insertEvent(
        crowSessionID: UUID,
        eventName: String,
        body: String?,
        attributesJSON: String?,
        severityNumber: Int?,
        timestampNs: String?,
        receivedAt: Date = Date()
    ) {
        let sql = """
            INSERT INTO events (crow_session_id, event_name, body, attributes_json, severity_number, timestamp_ns, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (crowSessionID.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (eventName as NSString).utf8String, -1, nil)
        if let body {
            sqlite3_bind_text(stmt, 3, (body as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let json = attributesJSON {
            sqlite3_bind_text(stmt, 4, (json as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let severity = severityNumber {
            sqlite3_bind_int(stmt, 5, Int32(severity))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let ts = timestampNs {
            sqlite3_bind_text(stmt, 6, (ts as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_double(stmt, 7, receivedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    // MARK: - Reads

    /// Compute aggregated analytics for a Crow session.
    public func sessionAnalytics(for crowSessionID: UUID) -> SessionAnalytics {
        aggregateAnalytics(session: crowSessionID.uuidString, window: nil)
    }

    /// Windowed variant over `received_at` (ingest time — rows arrive within
    /// seconds of the activity, so it's an acceptable proxy for event time).
    /// Half-open [start, end), matching `ScorecardModel`'s week membership.
    /// Feeds the Manager-session weekly rollups (#745).
    public func sessionAnalytics(
        for crowSessionID: UUID, receivedBetween start: Date, end: Date
    ) -> SessionAnalytics {
        aggregateAnalytics(
            session: crowSessionID.uuidString,
            window: (start.timeIntervalSince1970, end.timeIntervalSince1970))
    }

    /// Distinct Crow session IDs with any telemetry rows, for the scorecard
    /// snapshot backfill (#745). Rows whose id doesn't parse as a UUID are
    /// dropped. Driven off `metrics`/`events` rather than `session_map`, which
    /// outlives retention pruning and would list aged-out sessions.
    public func sessionIDs() -> [UUID] {
        let sql = "SELECT crow_session_id FROM metrics UNION SELECT crow_session_id FROM events"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0),
               let id = UUID(uuidString: String(cString: ptr)) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Cheap health probe backing the scorecard's live capture-status line
    /// (#745): how many sessions have telemetry rows, and when the newest
    /// row arrived.
    public func captureStatus() -> TelemetryCaptureStatus {
        let sql = """
            SELECT COUNT(DISTINCT crow_session_id), MAX(received_at)
            FROM (SELECT crow_session_id, received_at FROM metrics
                  UNION ALL SELECT crow_session_id, received_at FROM events)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return TelemetryCaptureStatus(sessionCount: 0, lastReceivedAt: nil)
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return TelemetryCaptureStatus(sessionCount: 0, lastReceivedAt: nil)
        }
        let count = Int(sqlite3_column_int(stmt, 0))
        let lastReceivedAt: Date? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        return TelemetryCaptureStatus(sessionCount: count, lastReceivedAt: lastReceivedAt)
    }

    /// Shared aggregator behind both `sessionAnalytics` variants; a nil window
    /// keeps the original un-windowed behavior byte-for-byte.
    private func aggregateAnalytics(
        session sid: String, window: (start: Double, end: Double)?
    ) -> SessionAnalytics {
        var analytics = SessionAnalytics()

        // Aggregate metrics
        analytics.totalCost = sumMetric("claude_code.cost.usage", session: sid, window: window)

        // Token breakdown by type attribute
        analytics.inputTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "input", session: sid, window: window))
        analytics.outputTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "output", session: sid, window: window))
        analytics.cacheReadTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "cacheRead", session: sid, window: window))
        analytics.cacheCreationTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "cacheCreation", session: sid, window: window))

        analytics.activeTimeSeconds = sumMetric("claude_code.active_time.total", session: sid, window: window)

        // Lines of code by type attribute
        analytics.linesAdded = Int(sumMetricWithAttribute("claude_code.lines_of_code.count", attrKey: "type", attrValue: "added", session: sid, window: window))
        analytics.linesRemoved = Int(sumMetricWithAttribute("claude_code.lines_of_code.count", attrKey: "type", attrValue: "removed", session: sid, window: window))

        analytics.commitCount = Int(sumMetric("claude_code.commit.count", session: sid, window: window))

        // Count events by type
        analytics.promptCount = countEvents("claude_code.user_prompt", session: sid, window: window)
        analytics.toolCallCount = countEvents("claude_code.tool_result", session: sid, window: window)
        analytics.apiRequestCount = countEvents("claude_code.api_request", session: sid, window: window)
        analytics.apiErrorCount = countEvents("claude_code.api_error", session: sid, window: window)

        return analytics
    }

    /// Reconstruct per-turn analytics for a Crow session by segmenting
    /// token/cost metric rows between successive `claude_code.user_prompt`
    /// events (ADR 0008 follow-up 7). Returns one record per prompt event,
    /// in turn order; rows timestamped before the first prompt fold into
    /// turn 0, so per-field sums across turns match `sessionAnalytics`.
    /// Returns an empty array when the session has no prompt events (rows
    /// aged out of retention, or telemetry off) — callers fall back to the
    /// `promptCount` average.
    public func turnAnalytics(for crowSessionID: UUID) -> [TurnAnalytics] {
        let sid = crowSessionID.uuidString

        let eventSQL = """
            SELECT id, timestamp_ns, received_at FROM events
            WHERE crow_session_id = ? AND event_name = 'claude_code.user_prompt'
            ORDER BY id
            """
        var eventStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, eventSQL, -1, &eventStmt, nil) == SQLITE_OK else { return [] }

        var boundaries: [(t: Double, id: Int64)] = []
        sqlite3_bind_text(eventStmt, 1, (sid as NSString).utf8String, -1, nil)
        while sqlite3_step(eventStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(eventStmt, 0)
            let ns = sqlite3_column_text(eventStmt, 1).map { String(cString: $0) }
            let receivedAt = sqlite3_column_double(eventStmt, 2)
            boundaries.append((timestampSeconds(ns: ns, receivedAt: receivedAt), id))
        }
        sqlite3_finalize(eventStmt)

        guard !boundaries.isEmpty else { return [] }
        boundaries.sort { ($0.t, $0.id) < ($1.t, $1.id) }
        let boundaryTimes = boundaries.map(\.t)

        let metricSQL = """
            SELECT metric_name, value, json_extract(attributes_json, '$.type'), timestamp_ns, received_at
            FROM metrics
            WHERE crow_session_id = ? AND metric_name IN ('claude_code.token.usage', 'claude_code.cost.usage')
            ORDER BY id
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, metricSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sid as NSString).utf8String, -1, nil)

        // Sum as doubles per turn and truncate once at the end, matching the
        // Int(SUM(...)) behavior of sessionAnalytics.
        struct Sums { var input = 0.0, output = 0.0, cacheRead = 0.0, cacheCreation = 0.0, cost = 0.0 }
        var sums = [Sums](repeating: Sums(), count: boundaries.count)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)
            let value = sqlite3_column_double(stmt, 1)
            let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let ns = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let receivedAt = sqlite3_column_double(stmt, 4)
            let index = turnIndex(
                for: timestampSeconds(ns: ns, receivedAt: receivedAt),
                boundaryTimes: boundaryTimes
            )
            switch (name, type) {
            case ("claude_code.cost.usage", _): sums[index].cost += value
            case ("claude_code.token.usage", "input"): sums[index].input += value
            case ("claude_code.token.usage", "output"): sums[index].output += value
            case ("claude_code.token.usage", "cacheRead"): sums[index].cacheRead += value
            case ("claude_code.token.usage", "cacheCreation"): sums[index].cacheCreation += value
            default: break
            }
        }

        return sums.enumerated().map { index, turn in
            TurnAnalytics(
                turnIndex: index,
                inputTokens: Int(turn.input),
                outputTokens: Int(turn.output),
                cacheReadTokens: Int(turn.cacheRead),
                cacheCreationTokens: Int(turn.cacheCreation),
                cost: turn.cost
            )
        }
    }

    // MARK: - Cleanup

    /// Delete all telemetry data for a session.
    public func deleteSessionData(for crowSessionID: UUID) {
        let sid = crowSessionID.uuidString
        execute("DELETE FROM metrics WHERE crow_session_id = '\(sid)'")
        execute("DELETE FROM events WHERE crow_session_id = '\(sid)'")
        execute("DELETE FROM session_map WHERE crow_session_id = '\(sid)'")
    }

    /// Delete metrics and events older than the retention window.
    /// `retentionDays == 0` is a no-op (retention disabled — keep forever).
    public func pruneOldData(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(retentionDays) * 86400
        execute("DELETE FROM metrics WHERE received_at < \(cutoff)")
        execute("DELETE FROM events WHERE received_at < \(cutoff)")
    }

    // MARK: - Private Helpers

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// One ordering key shared by event and metric rows: the OTLP
    /// `timeUnixNano` when present, else the ingest wall clock. Both are
    /// wall-clock-near-now, so their sub-second skew is irrelevant at turn
    /// granularity.
    private func timestampSeconds(ns: String?, receivedAt: Double) -> Double {
        if let ns, let value = Int64(ns) { return Double(value) / 1_000_000_000 }
        return receivedAt
    }

    /// Index of the last boundary at or before `t`; rows earlier than the
    /// first boundary fold into turn 0.
    private func turnIndex(for t: Double, boundaryTimes: [Double]) -> Int {
        var low = 0
        var high = boundaryTimes.count
        while low < high {
            let mid = (low + high) / 2
            if boundaryTimes[mid] <= t { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    /// Sum of stored delta rows for one exact series (null-safe attribute match).
    /// Used to recover the cumulative baseline after an app restart.
    private func storedSeriesSum(session: String, metricName: String, attributesJSON: String?) -> Double {
        let sql = """
            SELECT COALESCE(SUM(value), 0) FROM metrics
            WHERE crow_session_id = ? AND metric_name = ? AND attributes_json IS ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (metricName as NSString).utf8String, -1, nil)
        if let json = attributesJSON {
            sqlite3_bind_text(stmt, 3, (json as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0
    }

    /// Half-open `received_at` filter appended to the aggregate queries when a
    /// window is given; binds start/end at `index` and `index + 1`.
    private static let windowClause = " AND received_at >= ? AND received_at < ?"

    private func bindWindow(
        _ stmt: OpaquePointer?, _ window: (start: Double, end: Double)?, at index: Int32
    ) {
        guard let window else { return }
        sqlite3_bind_double(stmt, index, window.start)
        sqlite3_bind_double(stmt, index + 1, window.end)
    }

    private func sumMetric(
        _ name: String, session: String, window: (start: Double, end: Double)? = nil
    ) -> Double {
        var sql = "SELECT COALESCE(SUM(value), 0) FROM metrics WHERE crow_session_id = ? AND metric_name = ?"
        if window != nil { sql += Self.windowClause }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        bindWindow(stmt, window, at: 3)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0
    }

    private func sumMetricWithAttribute(
        _ name: String,
        attrKey: String,
        attrValue: String,
        session: String,
        window: (start: Double, end: Double)? = nil
    ) -> Double {
        // Filter metrics where the JSON attributes contain the specified key-value pair.
        // Uses json_extract for exact matching.
        var sql = """
            SELECT COALESCE(SUM(value), 0) FROM metrics
            WHERE crow_session_id = ? AND metric_name = ?
            AND json_extract(attributes_json, '$.' || ?) = ?
            """
        if window != nil { sql += Self.windowClause }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (attrKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (attrValue as NSString).utf8String, -1, nil)
        bindWindow(stmt, window, at: 5)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0
    }

    private func countEvents(
        _ eventName: String, session: String, window: (start: Double, end: Double)? = nil
    ) -> Int {
        var sql = "SELECT COUNT(*) FROM events WHERE crow_session_id = ? AND event_name = ?"
        if window != nil { sql += Self.windowClause }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (eventName as NSString).utf8String, -1, nil)
        bindWindow(stmt, window, at: 3)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
}

// MARK: - Errors

public enum TelemetryDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case schemaFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open telemetry database: \(msg)"
        case .schemaFailed(let msg): return "Failed to create telemetry schema: \(msg)"
        }
    }
}
