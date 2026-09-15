import Foundation
import CrowCore

/// Tiny on-disk index of TUI recordings (`recordings.json` beside the per-id
/// directories). Same `NSLock` + atomic-rename shape as `JSONStore`, but a
/// dedicated type so multi-megabyte logs never land in `store.json`.
final class TuiRecordingIndex: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var rows: [TuiRecordingRecord]

    init(root: URL) {
        self.fileURL = root.appendingPathComponent("recordings.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([TuiRecordingRecord].self, from: data) {
            self.rows = decoded
        } else {
            self.rows = []
        }
    }

    func all() -> [TuiRecordingRecord] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    func get(_ id: UUID) -> TuiRecordingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return rows.first { $0.id == id }
    }

    func inFlight(sessionID: UUID, terminalID: UUID) -> TuiRecordingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return rows.first {
            $0.sessionID == sessionID
                && $0.terminalID == terminalID
                && ($0.status == .unbound || $0.status == .recording)
        }
    }

    func inFlightCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.filter { $0.status == .unbound || $0.status == .recording }.count
    }

    func upsert(_ record: TuiRecordingRecord) {
        lock.lock()
        if let i = rows.firstIndex(where: { $0.id == record.id }) {
            rows[i] = record
        } else {
            rows.append(record)
        }
        let snapshot = rows
        lock.unlock()
        persist(snapshot)
    }

    @discardableResult
    func remove(_ id: UUID) -> TuiRecordingRecord? {
        lock.lock()
        let removed = rows.first { $0.id == id }
        rows.removeAll { $0.id == id }
        let snapshot = rows
        lock.unlock()
        persist(snapshot)
        return removed
    }

    private func persist(_ snapshot: [TuiRecordingRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            CrowLog.info("[CrowTui index_write_failed error=\(error.localizedDescription)]")
        }
    }
}
