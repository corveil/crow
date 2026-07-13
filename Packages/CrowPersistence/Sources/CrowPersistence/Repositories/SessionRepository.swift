import Foundation
import CrowCore

/// Repository for session queries.
public struct SessionRepository: Sendable {
    private let store: JSONStore

    public init(store: JSONStore) {
        self.store = store
    }

    public func all() -> [Session] {
        store.data.sessions
    }

    public func find(id: UUID) -> Session? {
        store.data.sessions.first { $0.id == id }
    }

    public func save(_ session: Session) {
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == session.id }) {
                data.sessions[idx] = session
            } else {
                data.sessions.append(session)
            }
        }
    }

    /// Delete a session and all related data (worktrees, links, terminals) in a single atomic mutation.
    /// `analyticsSnapshots` is deliberately NOT cascaded: the scorecard's
    /// trailing-4-week baseline must survive session deletion (ADR 0008, #690).
    /// `prAttributions` is likewise NOT cascaded: merged-PR-per-window counts
    /// must survive session deletion (ADR 0008, #693).
    public func delete(id: UUID) {
        store.mutate { data in
            data.sessions.removeAll { $0.id == id }
            data.worktrees.removeAll { $0.sessionID == id }
            data.links.removeAll { $0.sessionID == id }
            data.terminals.removeAll { $0.sessionID == id }
        }
    }

    public func worktrees(for sessionID: UUID) -> [SessionWorktree] {
        store.data.worktrees.filter { $0.sessionID == sessionID }
    }

    public func links(for sessionID: UUID) -> [SessionLink] {
        store.data.links.filter { $0.sessionID == sessionID }
    }
}
