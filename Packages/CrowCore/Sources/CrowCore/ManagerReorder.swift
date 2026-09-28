import Foundation

/// Reorder extra Manager sessions inside the stored session array (CROW-1294).
///
/// The sidebar's **Manager** pill is the well-known primary
/// (``AppState/managerSessionID``), wherever that row sits. Extra Managers
/// keep the indices they already occupy; a reorder only permutes which extra
/// Manager fills which of those indices. Work, job, and review rows stay put,
/// so their groups don't move. ``createManagerSession`` appends, and an id
/// that isn't in `extraOrder` is filled in after the ids that are — a Manager
/// created during a reorder lands at the end of the extra-Manager rows.
public enum ManagerReorder {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case ambiguousAnchor
        case sessionNotFound
        case notExtraManager(isPrimary: Bool)
        case targetNotFound
        case targetNotExtraManager(isPrimary: Bool)
        case targetIsMovingSession

        public var description: String {
            switch self {
            case .ambiguousAnchor:
                return "Pass exactly one of before_id or after_id"
            case .sessionNotFound:
                return "Session not found"
            case .notExtraManager(isPrimary: true):
                return "The primary Manager stays in the nav pill and cannot be reordered"
            case .notExtraManager(isPrimary: false):
                return "Only an extra Manager can be reordered"
            case .targetNotFound:
                return "Target session not found"
            case .targetNotExtraManager(isPrimary: true):
                return "The primary Manager is not a drop target"
            case .targetNotExtraManager(isPrimary: false):
                return "Drop target must be an extra Manager"
            case .targetIsMovingSession:
                return "before_id and after_id must be a different extra Manager"
            }
        }
    }

    /// An extra Manager is any `.manager` that is not the primary. Array
    /// position does not decide this — a drop must not be able to move the
    /// nav pill onto a different session.
    public static func isExtraManager(_ session: Session) -> Bool {
        session.kind == .manager && session.id != AppState.managerSessionID
    }

    /// Extra-Manager ids after moving `moving` to sit immediately before
    /// `before` or immediately after `after`. Exactly one anchor.
    public static func extraOrder(
        moving: UUID,
        before: UUID?,
        after: UUID?,
        in sessions: [Session]
    ) throws -> [UUID] {
        let anchor: Anchor
        switch (before, after) {
        case let (.some(beforeID), nil):
            anchor = .before(beforeID)
        case let (nil, .some(afterID)):
            anchor = .after(afterID)
        default:
            throw Failure.ambiguousAnchor
        }

        guard let movingSession = sessions.first(where: { $0.id == moving }) else {
            throw Failure.sessionNotFound
        }
        guard isExtraManager(movingSession) else {
            throw Failure.notExtraManager(isPrimary: movingSession.id == AppState.managerSessionID)
        }

        let anchorID: UUID
        let insertAfter: Bool
        switch anchor {
        case .before(let id):
            anchorID = id
            insertAfter = false
        case .after(let id):
            anchorID = id
            insertAfter = true
        }
        if anchorID == moving {
            throw Failure.targetIsMovingSession
        }
        guard let anchorSession = sessions.first(where: { $0.id == anchorID }) else {
            throw Failure.targetNotFound
        }
        guard isExtraManager(anchorSession) else {
            throw Failure.targetNotExtraManager(isPrimary: anchorSession.id == AppState.managerSessionID)
        }

        var extras = sessions.filter(isExtraManager).map(\.id)
        extras.removeAll { $0 == moving }
        guard let anchorIndex = extras.firstIndex(of: anchorID) else {
            throw Failure.targetNotFound
        }
        extras.insert(moving, at: insertAfter ? anchorIndex + 1 : anchorIndex)
        return extras
    }

    /// Write `extraOrder` back into the indices extra Managers already occupy.
    /// Ids in `extraOrder` that aren't extra Managers in `sessions` are
    /// skipped. Extra Managers missing from `extraOrder` keep their relative
    /// order and follow the ids that were listed, so a newly appended Manager
    /// stays at the end.
    public static func apply(extraOrder: [UUID], to sessions: [Session]) -> [Session] {
        let extras = sessions.filter(isExtraManager)
        var byID: [UUID: Session] = [:]
        byID.reserveCapacity(extras.count)
        for session in extras {
            byID[session.id] = session
        }
        var placed: [Session] = []
        var seen = Set<UUID>()
        placed.reserveCapacity(extras.count)
        for id in extraOrder {
            guard let session = byID[id], seen.insert(id).inserted else { continue }
            placed.append(session)
        }
        for session in extras where !seen.contains(session.id) {
            placed.append(session)
        }

        var result = sessions
        var index = 0
        for slot in result.indices where isExtraManager(result[slot]) {
            if index < placed.count {
                result[slot] = placed[index]
                index += 1
            }
        }
        return result
    }

    private enum Anchor {
        case before(UUID)
        case after(UUID)
    }
}
