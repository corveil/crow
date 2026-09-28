import Foundation
import Testing
@testable import CrowCore

// Extra-Manager sidebar order (CROW-1294). The primary is the well-known id.
// Reordering permutes extra Managers among the indices they already occupy
// and leaves every other session where it is.

private let primaryID = AppState.managerSessionID
private let aID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let bID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
private let cID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
private let workID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
private let jobID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

private func manager(_ id: UUID, _ name: String) -> Session {
    Session(id: id, name: name, kind: .manager)
}

private func names(_ sessions: [Session]) -> [String] {
    sessions.map(\.name)
}

@Suite("Manager reorder") struct ManagerReorderTests {

    private func seeded() -> [Session] {
        [
            manager(primaryID, "Primary"),
            manager(aID, "A"),
            Session(id: workID, name: "Work", kind: .work),
            manager(bID, "B"),
            Session(id: jobID, name: "Job", kind: .job),
        ]
    }

    @Test func moveBeforePermutesOnlyExtraManagerSlots() throws {
        let sessions = seeded()
        let order = try ManagerReorder.extraOrder(moving: bID, before: aID, after: nil, in: sessions)
        #expect(order == [bID, aID])
        #expect(names(ManagerReorder.apply(extraOrder: order, to: sessions))
            == ["Primary", "B", "Work", "A", "Job"])
    }

    @Test func moveAfterPlacesTheRowBelowTheAnchor() throws {
        let sessions = seeded()
        let order = try ManagerReorder.extraOrder(moving: aID, before: nil, after: bID, in: sessions)
        #expect(order == [bID, aID])
        #expect(names(ManagerReorder.apply(extraOrder: order, to: sessions))
            == ["Primary", "B", "Work", "A", "Job"])
    }

    @Test func primaryNotFirstStaysThePrimaryAndStaysInItsSlot() throws {
        // An extra Manager already sits above the primary. Moving the other
        // extra must not slide the primary into "first Manager" position or
        // out of its own index.
        let sessions = [
            manager(bID, "B"),
            manager(primaryID, "Primary"),
            Session(id: workID, name: "Work", kind: .work),
            manager(aID, "A"),
        ]
        let order = try ManagerReorder.extraOrder(moving: aID, before: bID, after: nil, in: sessions)
        let next = ManagerReorder.apply(extraOrder: order, to: sessions)
        #expect(names(next) == ["A", "Primary", "Work", "B"])
        #expect(next.first { $0.id == primaryID }?.name == "Primary")
        #expect(next[1].id == primaryID)
    }

    @Test func appendedManagerStaysLastUntilItIsTheOneMoving() throws {
        var sessions = seeded()
        sessions.append(manager(cID, "C"))
        let order = try ManagerReorder.extraOrder(moving: bID, before: aID, after: nil, in: sessions)
        #expect(order == [bID, aID, cID])
        #expect(names(ManagerReorder.apply(extraOrder: order, to: sessions))
            == ["Primary", "B", "Work", "A", "Job", "C"])
    }

    @Test func idMissingFromTheOrderFollowsTheListedExtras() {
        // A Manager appended after the client computed its order still lands
        // at the end of the extra-Manager slots.
        let sessions = seeded() + [manager(cID, "C")]
        let next = ManagerReorder.apply(extraOrder: [bID, aID], to: sessions)
        #expect(names(next) == ["Primary", "B", "Work", "A", "Job", "C"])
    }

    @Test func movingThePrimaryIsRefused() {
        let sessions = seeded()
        #expect(throws: ManagerReorder.Failure.notExtraManager(isPrimary: true)) {
            _ = try ManagerReorder.extraOrder(moving: primaryID, before: aID, after: nil, in: sessions)
        }
    }

    @Test func movingAWorkSessionIsRefused() {
        let sessions = seeded()
        #expect(throws: ManagerReorder.Failure.notExtraManager(isPrimary: false)) {
            _ = try ManagerReorder.extraOrder(moving: workID, before: aID, after: nil, in: sessions)
        }
    }

    @Test func droppingOnThePrimaryIsRefused() {
        let sessions = seeded()
        #expect(throws: ManagerReorder.Failure.targetNotExtraManager(isPrimary: true)) {
            _ = try ManagerReorder.extraOrder(moving: aID, before: primaryID, after: nil, in: sessions)
        }
    }

    @Test func droppingOnAWorkSessionIsRefused() {
        let sessions = seeded()
        #expect(throws: ManagerReorder.Failure.targetNotExtraManager(isPrimary: false)) {
            _ = try ManagerReorder.extraOrder(moving: aID, before: nil, after: workID, in: sessions)
        }
    }

    @Test func missingSessionAndMissingAnchor() {
        let sessions = seeded()
        #expect(throws: ManagerReorder.Failure.sessionNotFound) {
            _ = try ManagerReorder.extraOrder(moving: cID, before: aID, after: nil, in: sessions)
        }
        #expect(throws: ManagerReorder.Failure.targetNotFound) {
            _ = try ManagerReorder.extraOrder(moving: aID, before: cID, after: nil, in: sessions)
        }
    }

    @Test func anchorMustBeExactlyOneAndNotItself() {
        let sessions = seeded()
        #expect(throws: ManagerReorder.Failure.ambiguousAnchor) {
            _ = try ManagerReorder.extraOrder(moving: aID, before: nil, after: nil, in: sessions)
        }
        #expect(throws: ManagerReorder.Failure.ambiguousAnchor) {
            _ = try ManagerReorder.extraOrder(moving: aID, before: bID, after: bID, in: sessions)
        }
        #expect(throws: ManagerReorder.Failure.targetIsMovingSession) {
            _ = try ManagerReorder.extraOrder(moving: aID, before: aID, after: nil, in: sessions)
        }
    }

    @Test func alreadyInPlaceOrderIsUnchanged() throws {
        let sessions = seeded()
        let order = try ManagerReorder.extraOrder(moving: aID, before: bID, after: nil, in: sessions)
        #expect(order == [aID, bID])
        #expect(names(ManagerReorder.apply(extraOrder: order, to: sessions)) == names(sessions))
    }
}
