import Foundation
import SQLite3
import Testing
@testable import CrowTelemetry

/// Tests for CUMULATIVE→delta normalization at metric ingest (issue #689).
///
/// Cumulative sum datapoints are running totals; storing them raw makes the
/// SUM()-based readers double-count. `insertMetric` normalizes them to deltas
/// so the stored rows always sum to the true total.

private func makeDatabase() async throws -> (db: TelemetryDatabase, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".db").path
    let db = TelemetryDatabase(path: path)
    try await db.open()
    return (db, path)
}

private func insertCost(
    _ db: TelemetryDatabase,
    session: UUID,
    value: Double,
    temporality: OTLPAggregationTemporality = .cumulative,
    isMonotonic: Bool? = true
) async {
    await db.insertMetric(
        crowSessionID: session,
        metricName: "claude_code.cost.usage",
        value: value,
        attributesJSON: nil,
        timestampNs: nil,
        temporality: temporality,
        isMonotonic: isMonotonic
    )
}

private func metricRowCount(path: String) -> Int {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM metrics", -1, &stmt, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int(stmt, 0))
}

@Test func cumulativeStreamDoesNotDoubleCount() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertCost(db, session: session, value: 100)
    await insertCost(db, session: session, value: 250)
    await insertCost(db, session: session, value: 400)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 400)
    await db.close()
}

@Test func deltaStreamStillSumsCorrectly() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertCost(db, session: session, value: 100, temporality: .delta)
    await insertCost(db, session: session, value: 150, temporality: .delta)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 250)
    await db.close()
}

@Test func unspecifiedTemporalityInsertsRaw() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    // Gauge path: no temporality, values stored as-is.
    await insertCost(db, session: session, value: 5, temporality: .unspecified, isMonotonic: nil)
    await insertCost(db, session: session, value: 7, temporality: .unspecified, isMonotonic: nil)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 12)
    await db.close()
}

@Test func counterResetProducesNoNegativeDelta() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertCost(db, session: session, value: 100)
    await insertCost(db, session: session, value: 250)
    await insertCost(db, session: session, value: 40)  // reset: new process counts from 0
    await insertCost(db, session: session, value: 55)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 305)  // 100 + 150 + 40 + 15
    await db.close()
}

@Test func firstDatapointOfSeriesIsStoredWhole() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertCost(db, session: session, value: 100)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 100)
    await db.close()
}

@Test func baselineRecoversAcrossDatabaseRestart() async throws {
    let (db1, path) = try await makeDatabase()
    let session = UUID()

    await insertCost(db1, session: session, value: 100)
    await insertCost(db1, session: session, value: 250)
    await db1.close()

    // New instance on the same file simulates an app restart: the in-memory
    // last-value cache is gone, but the stored deltas sum to 250.
    let db2 = TelemetryDatabase(path: path)
    try await db2.open()
    await insertCost(db2, session: session, value: 400)

    let analytics = await db2.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 400)
    await db2.close()
}

@Test func attributeSetsAreSeparateSeries() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    func insertTokens(_ value: Double, type: String) async {
        await db.insertMetric(
            crowSessionID: session,
            metricName: "claude_code.token.usage",
            value: value,
            attributesJSON: "{\"type\":\"\(type)\"}",
            timestampNs: nil,
            temporality: .cumulative,
            isMonotonic: true
        )
    }

    await insertTokens(100, type: "input")
    await insertTokens(50, type: "output")
    await insertTokens(200, type: "input")
    await insertTokens(75, type: "output")

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.inputTokens == 200)
    #expect(analytics.outputTokens == 75)
    await db.close()
}

@Test func zeroDeltaRowsAreSkipped() async throws {
    let (db, path) = try await makeDatabase()
    let session = UUID()

    await insertCost(db, session: session, value: 100)
    await insertCost(db, session: session, value: 100)
    await insertCost(db, session: session, value: 100)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 100)
    await db.close()

    #expect(metricRowCount(path: path) == 1)
}

@Test func nonMonotonicCumulativeAllowsNegativeDelta() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertCost(db, session: session, value: 100, isMonotonic: false)
    await insertCost(db, session: session, value: 60, isMonotonic: false)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.totalCost == 60)  // 100 + (-40): SUM reconstructs last value
    await db.close()
}

@Test func sumTemporalityDecodesFromOTLPJSON() throws {
    let json = """
        {
            "resourceMetrics": [{
                "scopeMetrics": [{
                    "metrics": [{
                        "name": "claude_code.token.usage",
                        "sum": {
                            "aggregationTemporality": 2,
                            "isMonotonic": true,
                            "dataPoints": [{"asInt": "1234", "attributes": [{"key": "type", "value": {"stringValue": "input"}}]}]
                        }
                    }, {
                        "name": "claude_code.cost.usage",
                        "sum": {
                            "aggregationTemporality": 1,
                            "isMonotonic": true,
                            "dataPoints": [{"asDouble": 0.5}]
                        }
                    }]
                }]
            }]
        }
        """
    let payload = try JSONDecoder().decode(OTLPMetricsPayload.self, from: Data(json.utf8))
    let metrics = payload.resourceMetrics[0].scopeMetrics?[0].metrics
    #expect(metrics?[0].sum?.temporality == .cumulative)
    #expect(metrics?[1].sum?.temporality == .delta)
    #expect(metrics?[0].sum?.dataPoints?[0].numericValue == 1234)
}
