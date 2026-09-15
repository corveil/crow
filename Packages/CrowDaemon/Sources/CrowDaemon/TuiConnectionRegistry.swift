import Foundation

/// Process-wide `group → recording_id` map for bind/unbind/stop **only**.
/// The PTY hot path must not look this up — it uses a connection-local tee.
final class TuiConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var groupToRecording: [String: UUID] = [:]
    private var recordingToGroup: [UUID: String] = [:]

    func recordingID(for group: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return groupToRecording[group]
    }

    func group(for recordingID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recordingToGroup[recordingID]
    }

    /// Bind `group` to `recordingID`. If the group already mapped to a different
    /// id, returns that prior id so the caller can unbind it with no grace.
    @discardableResult
    func bind(group: String, recordingID: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        let prior = groupToRecording[group]
        if let prior, prior != recordingID {
            recordingToGroup[prior] = nil
        }
        if let oldGroup = recordingToGroup[recordingID], oldGroup != group {
            groupToRecording[oldGroup] = nil
        }
        groupToRecording[group] = recordingID
        recordingToGroup[recordingID] = group
        return (prior != recordingID) ? prior : nil
    }

    func unbind(group: String) {
        lock.lock()
        defer { lock.unlock() }
        if let id = groupToRecording[group] {
            recordingToGroup[id] = nil
        }
        groupToRecording[group] = nil
    }

    func unbind(recordingID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let group = recordingToGroup[recordingID] {
            groupToRecording[group] = nil
        }
        recordingToGroup[recordingID] = nil
    }
}
