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
    /// (`.unspecified`) are stored as-is.
    public func insertMetric(
        crowSessionID: UUID,
        metricName: String,
        value: Double,
        attributesJSON: String?,
        timestampNs: String?,
        temporality: OTLPAggregationTemporality = .unspecified,
        isMonotonic: Bool? = nil
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
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    public func insertEvent(
        crowSessionID: UUID,
        eventName: String,
        body: String?,
        attributesJSON: String?,
        severityNumber: Int?,
        timestampNs: String?
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
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    // MARK: - Reads

    /// Compute aggregated analytics for a Crow session.
    public func sessionAnalytics(for crowSessionID: UUID) -> SessionAnalytics {
        let sid = crowSessionID.uuidString
        var analytics = SessionAnalytics()

        // Aggregate metrics
        analytics.totalCost = sumMetric("claude_code.cost.usage", session: sid)

        // Token breakdown by type attribute
        analytics.inputTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "input", session: sid))
        analytics.outputTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "output", session: sid))
        analytics.cacheReadTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "cacheRead", session: sid))
        analytics.cacheCreationTokens = Int(sumMetricWithAttribute("claude_code.token.usage", attrKey: "type", attrValue: "cacheCreation", session: sid))

        analytics.activeTimeSeconds = sumMetric("claude_code.active_time.total", session: sid)

        // Lines of code by type attribute
        analytics.linesAdded = Int(sumMetricWithAttribute("claude_code.lines_of_code.count", attrKey: "type", attrValue: "added", session: sid))
        analytics.linesRemoved = Int(sumMetricWithAttribute("claude_code.lines_of_code.count", attrKey: "type", attrValue: "removed", session: sid))

        analytics.commitCount = Int(sumMetric("claude_code.commit.count", session: sid))

        // Count events by type
        analytics.promptCount = countEvents("claude_code.user_prompt", session: sid)
        analytics.toolCallCount = countEvents("claude_code.tool_result", session: sid)
        analytics.apiRequestCount = countEvents("claude_code.api_request", session: sid)
        analytics.apiErrorCount = countEvents("claude_code.api_error", session: sid)

        return analytics
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

    private func sumMetric(_ name: String, session: String) -> Double {
        let sql = "SELECT COALESCE(SUM(value), 0) FROM metrics WHERE crow_session_id = ? AND metric_name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0
    }

    private func sumMetricWithAttribute(
        _ name: String,
        attrKey: String,
        attrValue: String,
        session: String
    ) -> Double {
        // Filter metrics where the JSON attributes contain the specified key-value pair.
        // Uses json_extract for exact matching.
        let sql = """
            SELECT COALESCE(SUM(value), 0) FROM metrics
            WHERE crow_session_id = ? AND metric_name = ?
            AND json_extract(attributes_json, '$.' || ?) = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (attrKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (attrValue as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0
    }

    private func countEvents(_ eventName: String, session: String) -> Int {
        let sql = "SELECT COUNT(*) FROM events WHERE crow_session_id = ? AND event_name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (eventName as NSString).utf8String, -1, nil)

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
