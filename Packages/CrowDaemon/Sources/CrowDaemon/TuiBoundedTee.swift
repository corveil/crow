import Foundation

/// Connection-local bounded stream drained by the recorder ingest queue.
///
/// `yield*` is a lock + append + async drain schedule — never `await`, never a
/// process-wide map lookup. Tripping 8 MiB or 2 s of unwritten chunks seals
/// with `tee_backpressure`.
final class TuiBoundedTee: @unchecked Sendable {
    let recordingID: UUID
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let ingestQueue: DispatchQueue
    private let onDrain: ([TuiTeeEvent]) -> Void
    private let onBackpressure: () -> Void

    private let lock = NSLock()
    private var pending: [TuiTeeEvent] = []
    private var pendingBytes = 0
    private var oldest: Date?
    private var sealed = false
    private var drainScheduled = false

    init(
        recordingID: UUID,
        ingestQueue: DispatchQueue,
        maxBytes: Int = TuiLimits.teeMaxBytes,
        maxAge: TimeInterval = TuiLimits.teeMaxAge,
        onDrain: @escaping ([TuiTeeEvent]) -> Void,
        onBackpressure: @escaping () -> Void
    ) {
        self.recordingID = recordingID
        self.ingestQueue = ingestQueue
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        self.onDrain = onDrain
        self.onBackpressure = onBackpressure
    }

    func yieldOutput(_ data: Data) { enqueue(.output(data), bytes: data.count) }
    func yieldInput(_ data: Data) { enqueue(.input(data), bytes: data.count) }
    func yieldResize(cols: Int, rows: Int, src: String) {
        enqueue(.resize(cols: cols, rows: rows, src: src), bytes: 32)
    }
    func yieldSelectWindow(_ window: Int) {
        enqueue(.selectWindow(window), bytes: 16)
    }
    func yieldBind(_ group: String) { enqueue(.bind(group), bytes: group.utf8.count) }
    func yieldUnbind(_ reason: String) { enqueue(.unbind(reason), bytes: reason.utf8.count) }
    func yieldMarker(_ note: String?) { enqueue(.marker(note), bytes: note?.utf8.count ?? 8) }

    /// Stop accepting events (stop / seal / unbind). Further yields are no-ops.
    func seal() {
        lock.lock()
        sealed = true
        let batch = takePendingLocked()
        lock.unlock()
        if !batch.isEmpty { onDrain(batch) }
    }

    var isSealed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sealed
    }

    private func enqueue(_ event: TuiTeeEvent, bytes: Int) {
        lock.lock()
        if sealed {
            lock.unlock()
            return
        }
        if pendingBytes + bytes > maxBytes {
            sealed = true
            let batch = takePendingLocked()
            lock.unlock()
            if !batch.isEmpty { onDrain(batch) }
            onBackpressure()
            return
        }
        if let oldest, Date().timeIntervalSince(oldest) > maxAge {
            sealed = true
            let batch = takePendingLocked()
            lock.unlock()
            if !batch.isEmpty { onDrain(batch) }
            onBackpressure()
            return
        }
        if pending.isEmpty { oldest = Date() }
        pending.append(event)
        pendingBytes += bytes
        let schedule = !drainScheduled
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule {
            ingestQueue.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        lock.lock()
        let batch = takePendingLocked()
        drainScheduled = false
        lock.unlock()
        if !batch.isEmpty { onDrain(batch) }
    }

    private func takePendingLocked() -> [TuiTeeEvent] {
        let batch = pending
        pending = []
        pendingBytes = 0
        oldest = nil
        return batch
    }
}
