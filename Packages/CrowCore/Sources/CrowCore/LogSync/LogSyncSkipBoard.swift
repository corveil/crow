import Foundation

/// One reason the log-sync collector gave for not uploading a session, kept
/// in memory so the sidebar can say it (spike: recording indicator).
///
/// The collector already logs every skip once (CROW-1395). This is the same
/// fact as a structured value, so the reason shows up on the session row
/// instead of only in `crowd`'s log.
public struct LogSyncSkipNote: Sendable, Equatable {
    /// Stable machine reason, e.g. `no-transcript`, `no-workspace`.
    public var reason: String
    /// Human text: what was looked at. Paths and ids only, never transcript
    /// text or a credential (the same rule as the log line).
    public var detail: String
    /// A Manager conversation id when the skip is about one conversation.
    public var scope: String?

    public init(reason: String, detail: String, scope: String? = nil) {
        self.reason = reason
        self.detail = detail
        self.scope = scope
    }
}

/// The collector's latest skip notes per session. In-memory only: it is
/// rebuilt on every sweep, so after a `crowd` restart it fills in again within
/// one collector tick (~5 min).
public final class LogSyncSkipBoard: @unchecked Sendable {
    public static let shared = LogSyncSkipBoard()

    private let lock = NSLock()
    private var notes: [UUID: [LogSyncSkipNote]] = [:]

    public init() {}

    /// Forget what the last sweep said about `sessionID`. The collector calls
    /// this before it looks at a session again, so a note never outlives the
    /// condition that produced it.
    public func clear(_ sessionID: UUID) {
        lock.withLock { _ = notes.removeValue(forKey: sessionID) }
    }

    public func record(_ sessionID: UUID, _ note: LogSyncSkipNote) {
        lock.withLock {
            var list = notes[sessionID] ?? []
            if !list.contains(note) { list.append(note) }
            notes[sessionID] = list
        }
    }

    public func notes(for sessionID: UUID) -> [LogSyncSkipNote] {
        lock.withLock { notes[sessionID] ?? [] }
    }
}
