import Foundation
import Testing
import CrowCore
@testable import Crow

/// Tests for `SessionService.shouldAutoPermission(kind:jobsAuto:reviewAuto:)` —
/// the launch decision that grants worker sessions `--permission-mode auto`
/// (CROW-602). Jobs and reviews each have their own opt-in (default-on)
/// toggle; `work` sessions never get auto mode, and the Manager is launched
/// through a separate path gated by `managerAutoPermissionMode`.
@Suite("Auto-permission launch decision")
struct SessionServiceAutoPermissionTests {

    @Test func reviewFollowsReviewToggle() {
        #expect(SessionService.shouldAutoPermission(kind: .review, jobsAuto: false, reviewAuto: true))
        #expect(!SessionService.shouldAutoPermission(kind: .review, jobsAuto: true, reviewAuto: false))
    }

    @Test func jobFollowsJobsToggle() {
        #expect(SessionService.shouldAutoPermission(kind: .job, jobsAuto: true, reviewAuto: false))
        #expect(!SessionService.shouldAutoPermission(kind: .job, jobsAuto: false, reviewAuto: true))
    }

    @Test func workAndManagerNeverAutoPermission() {
        // Work sessions are attended; the Manager is gated by its own
        // `managerAutoPermissionMode` on a separate launch path. Neither may
        // pick up auto mode from the jobs/review toggles.
        #expect(!SessionService.shouldAutoPermission(kind: .work, jobsAuto: true, reviewAuto: true))
        #expect(!SessionService.shouldAutoPermission(kind: .manager, jobsAuto: true, reviewAuto: true))
    }
}
