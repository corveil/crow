import Foundation
import CrowCore

/// Coordinates the OTLP receiver and telemetry database, providing the public API
/// for the rest of the app to interact with session analytics.
public final class TelemetryService: Sendable {
    private let database: TelemetryDatabase
    private let receiver: OTLPReceiver
    public let port: UInt16

    /// Create and initialize the telemetry service.
    ///
    /// - Parameters:
    ///   - port: The port to listen on for OTLP HTTP/JSON requests.
    ///   - dataDirectory: Directory for the SQLite database file. Defaults to app support dir.
    ///   - onDataReceived: Called on the main actor when new telemetry data arrives for a session.
    public init(
        port: UInt16,
        dataDirectory: String? = nil,
        onDataReceived: @escaping @Sendable @MainActor (UUID) -> Void
    ) throws {
        self.port = port

        let dir = dataDirectory ?? Self.defaultDataDirectory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbPath = (dir as NSString).appendingPathComponent("telemetry.db")

        self.database = TelemetryDatabase(path: dbPath)
        self.receiver = try OTLPReceiver(
            port: port,
            database: database,
            onDataReceived: onDataReceived
        )
    }

    /// Start receiving telemetry. Opens the database and starts the HTTP listener.
    public func start() async throws {
        try await database.open()
        receiver.start()
        NSLog("[TelemetryService] Started on port %d", port)
    }

    /// Stop receiving telemetry. Stops the listener and closes the database.
    public func stop() async {
        receiver.stop()
        await database.close()
        NSLog("[TelemetryService] Stopped")
    }

    /// Get analytics for a Crow session.
    public func analytics(for crowSessionID: UUID) async -> SessionAnalytics {
        await database.sessionAnalytics(for: crowSessionID)
    }

    /// Get analytics for a Crow session restricted to rows ingested in the
    /// half-open window [start, end). Feeds the Manager weekly rollups (#745).
    public func analytics(
        for crowSessionID: UUID, receivedBetween start: Date, end: Date
    ) async -> SessionAnalytics {
        await database.sessionAnalytics(for: crowSessionID, receivedBetween: start, end: end)
    }

    /// Distinct Crow session IDs with any telemetry rows, for the scorecard
    /// snapshot backfill (#745).
    public func sessionIDs() async -> [UUID] {
        await database.sessionIDs()
    }

    /// Live capture health for the scorecard's status line (#745).
    public func captureStatus() async -> TelemetryCaptureStatus {
        await database.captureStatus()
    }

    /// Get per-turn analytics for a Crow session, one record per
    /// `claude_code.user_prompt` event. Empty when the session's raw rows
    /// are gone (aged out of retention, or telemetry off) — fall back to
    /// the `promptCount` average from `analytics(for:)`.
    public func turnAnalytics(for crowSessionID: UUID) async -> [TurnAnalytics] {
        await database.turnAnalytics(for: crowSessionID)
    }

    /// Delete all telemetry data for a session (called when session is deleted).
    public func deleteSessionData(for crowSessionID: UUID) async {
        await database.deleteSessionData(for: crowSessionID)
    }

    /// Delete metrics and events older than the retention window.
    /// `retentionDays == 0` keeps data forever.
    public func pruneOldData(retentionDays: Int) async {
        await database.pruneOldData(retentionDays: retentionDays)
    }

    // MARK: - Private

    private static func defaultDataDirectory() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        return (appSupport as NSString).appendingPathComponent("crow")
    }
}
