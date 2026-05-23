import Foundation
import Testing
import CrowCore
@testable import Crow

/// Locks down the legacy primary-Manager migration (#316). Before
/// SessionKind.manager existed the primary Manager was persisted as `.work`;
/// on upgrade it must become `.manager` BEFORE hydration's per-session loop,
/// otherwise the work-session branch clears its claude command and reroutes it
/// through the auto-launch path (dropping --auto-permission-mode).
@Suite("SessionService.migrateLegacyManagerKind")
struct ManagerMigrationTests {

    @Test
    func migratesLegacyWorkPrimaryManager() {
        var sessions = [
            Session(id: AppState.managerSessionID, name: "Manager", kind: .work),
            Session(name: "feature", kind: .work),
        ]
        let migrated = SessionService.migrateLegacyManagerKind(&sessions)
        #expect(migrated)
        #expect(sessions.first { $0.id == AppState.managerSessionID }?.kind == .manager)
        // Non-primary work session is untouched.
        #expect(sessions.first { $0.name == "feature" }?.kind == .work)
    }

    @Test
    func noOpWhenPrimaryAlreadyManager() {
        var sessions = [Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)]
        #expect(SessionService.migrateLegacyManagerKind(&sessions) == false)
        #expect(sessions[0].kind == .manager)
    }

    @Test
    func noOpWhenNoPrimaryManager() {
        var sessions = [Session(name: "work", kind: .work)]
        #expect(SessionService.migrateLegacyManagerKind(&sessions) == false)
    }
}
