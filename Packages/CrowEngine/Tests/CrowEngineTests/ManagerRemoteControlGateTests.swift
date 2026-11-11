import Foundation
import Testing
import CrowAntigravity
import CrowClaude
@testable import CrowEngine

/// The Manager's RC badge (and Claude's `/rename` injection) is gated on the
/// flag the agent actually emitted, not the global toggle (CROW-433). Since
/// CROW-1428 that is two spellings: Claude's `--rc` and Antigravity's
/// session-scoped `--remote-control`.
@Suite("ManagerSessionController.managerCommandCarriesRemoteControl")
struct ManagerRemoteControlGateTests {

    @Test func claudeRCFlagCounts() {
        let cmd = "claude" + ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "Manager")
        #expect(ManagerSessionController.managerCommandCarriesRemoteControl(cmd))
    }

    @Test func antigravityRemoteControlFlagCounts() {
        let cmd = "'agy'" + AntigravityLaunchArgs.remoteControlSuffix(true)
        #expect(ManagerSessionController.managerCommandCarriesRemoteControl(cmd))
    }

    @Test func bareCommandsDoNotCount() {
        #expect(!ManagerSessionController.managerCommandCarriesRemoteControl("claude"))
        #expect(!ManagerSessionController.managerCommandCarriesRemoteControl(
            "'agy'" + AntigravityLaunchArgs.remoteControlSuffix(false)))
        #expect(!ManagerSessionController.managerCommandCarriesRemoteControl("'cursor-agent'"))
    }
}
