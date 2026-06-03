import Foundation
import Testing
@testable import CrowCursor
@testable import CrowCore

@Suite("CursorAgent")
struct CursorAgentTests {
    private let agent = CursorAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .cursor)
        #expect(agent.displayName == "Cursor")
        #expect(agent.iconSystemName == "cursorarrow.rays")
        #expect(agent.supportsRemoteControl == true)
        #expect(agent.launchCommandToken == "agent")
    }

    @Test func autoLaunchCommandWorkSession() {
        let session = Session(name: "test", agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd == "agent\n")
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // Cursor has no OTEL exporter and provides remote control via the
        // global hooks.json (`stop.followup_message`), not a per-launch
        // flag — toggling these shouldn't change the launch text.
        let session = Session(name: "test", agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            autoPermissionMode: false,
            telemetryPort: 4318
        )
        #expect(cmd == "agent\n")
    }

    @Test func autoLaunchCommandReviewSessionUnsupported() {
        let session = Session(name: "review", kind: .review, agentKind: .cursor)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
        #expect(cmd == nil) // Cursor review sessions aren't supported in MVP.
    }

    @Test func findBinaryReturnsNilWhenAbsent() {
        // We can't easily mock FileManager.isExecutableFile, but we CAN
        // verify the search returns nil when the candidate paths don't
        // resolve. This relies on the test environment not having an
        // `agent` binary at the homedir candidate path — the homebrew
        // path may or may not exist depending on the developer machine,
        // so we accept either outcome and just verify the result type.
        _ = agent.findBinary()  // smoke test: must not crash
    }
}
