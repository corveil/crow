import Foundation

/// A small on-disk record of which session transcripts have already been
/// uploaded, so a repeated sweep (including the one-time backfill of existing
/// on-disk history) never re-uploads the same artifact (CROW-1056).
///
/// Idempotency is belt-and-suspenders: the server also rejects a duplicate
/// `(session, harness, kind)` with 409, but the ledger avoids paying for the
/// round trip (and re-reading the log files) on every tick for every
/// already-uploaded session. Persisted at `{devRoot}/.claude/logsync-ledger.json`.
///
/// Written only by the single collector poll loop, so — unlike `config.json` —
/// it needs no cross-writer lock.
public struct LogSyncLedger: Codable, Sendable, Equatable {
    /// What happened last for a `(session, harness, kind)` key.
    public enum Status: String, Codable, Sendable, Equatable {
        /// Stored (201) or already present (409). Never re-attempted.
        case uploaded
        /// Rejected in a way retrying can't fix (too large / auth / validation).
        /// Never re-attempted.
        case skippedPermanent
        /// Transient failure (5xx / network). Re-attempted after a backoff.
        case failedTransient
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var status: Status
        public var sha256: String
        public var sizeBytes: Int
        /// Epoch seconds of the last attempt.
        public var at: Double
        public var reason: String?

        public init(status: Status, sha256: String, sizeBytes: Int, at: Double, reason: String? = nil) {
            self.status = status
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.at = at
            self.reason = reason
        }
    }

    /// Keyed by `"<sessionUID>:<harness>:<kind>"`.
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The stable ledger key for one artifact slot.
    public static func key(sessionUID: String, harness: LogSyncHarness, kind: LogSyncArtifactKind) -> String {
        "\(sessionUID):\(harness.rawValue):\(kind.rawValue)"
    }

    /// Whether this slot should be uploaded now, given the last recorded outcome.
    /// - `uploaded` / `skippedPermanent` → never again.
    /// - `failedTransient` → only after `retryBackoff` seconds have passed.
    /// - unknown → yes.
    public func shouldUpload(key: String, now: Double, retryBackoff: Double) -> Bool {
        guard let entry = entries[key] else { return true }
        switch entry.status {
        case .uploaded, .skippedPermanent: return false
        case .failedTransient: return (now - entry.at) >= retryBackoff
        }
    }

    public mutating func record(key: String, entry: Entry) {
        entries[key] = entry
    }

    /// Drop entries older than `retentionDays` (housekeeping so the ledger can't
    /// grow without bound). 0 keeps everything. A pruned-then-revisited live
    /// session simply re-converges via the server's 409.
    public mutating func prune(retentionDays: Int, now: Double) {
        guard retentionDays > 0 else { return }
        let cutoff = now - Double(retentionDays) * 86_400
        entries = entries.filter { $0.value.at >= cutoff }
    }

    // MARK: - Persistence

    /// Ledger file path under the dev root's `.claude` directory.
    public static func ledgerURL(devRoot: String) -> URL {
        URL(fileURLWithPath: devRoot)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("logsync-ledger.json")
    }

    /// Load the ledger, or an empty one if absent/unreadable/corrupt (a corrupt
    /// ledger is not fatal — worst case is a few duplicate uploads the server
    /// 409s).
    public static func load(devRoot: String) -> LogSyncLedger {
        let url = ledgerURL(devRoot: devRoot)
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(LogSyncLedger.self, from: data)
        else { return LogSyncLedger() }
        return ledger
    }

    /// Persist the ledger (pretty-printed, atomic). Best-effort — a write failure
    /// is logged by the caller and otherwise ignored.
    public func save(devRoot: String) throws {
        let url = Self.ledgerURL(devRoot: devRoot)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
