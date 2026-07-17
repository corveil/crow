import Testing
@testable import CrowEngine

/// Pure-policy tests for the CROW-747 cold-start terminal takeover decision.
/// `takeOverTerminalSurfaces` itself drives real tmux + agents, but its branch
/// is factored into `shouldRecreateSurfacesOnTakeover(cockpitSessionIsLive:)`
/// so the adopt-vs-recreate choice is testable without a tmux server.
@Suite("SessionService takeover policy (CROW-747)")
struct SessionServiceTakeoverPolicyTests {

    /// Cockpit gone (machine reboot / `tmux kill-server`) → recreate windows and
    /// relaunch each session's agent (`forceRegister: true`).
    @Test func recreatesWhenCockpitGone() {
        #expect(SessionService.shouldRecreateSurfacesOnTakeover(cockpitSessionIsLive: false))
    }

    /// Cockpit alive (warm crowd restart, windows + agents still running) →
    /// adopt in place (`forceRegister: false`); never relaunch into a live pane.
    @Test func adoptsWhenCockpitAlive() {
        #expect(!SessionService.shouldRecreateSurfacesOnTakeover(cockpitSessionIsLive: true))
    }
}
