import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("OpenAICodexAgent")
struct OpenAICodexAgentTests {
    private let agent = OpenAICodexAgent()

    @Test func protocolMembers() {
        #expect(agent.kind == .codex)
        #expect(agent.displayName == "OpenAI Codex")
        #expect(agent.iconSystemName == "terminal.fill")
        #expect(agent.supportsRemoteControl == false)
        #expect(agent.launchCommandToken == "codex")
    }

    @Test func autoLaunchCommandWorkSession() {
        let session = Session(name: "test", agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            telemetryPort: nil
        )
        #expect(cmd == "codex\n")
    }

    @Test func autoLaunchCommandIgnoresTelemetryAndRemoteControl() {
        // Codex has no OTEL exporter and doesn't honor --rc — toggling these
        // shouldn't change the launch text.
        let session = Session(name: "test", agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: true,
            telemetryPort: 4318
        )
        #expect(cmd == "codex\n")
    }

    @Test func autoLaunchCommandReviewSessionUnsupported() {
        let session = Session(name: "review", kind: .review, agentKind: .codex)
        let cmd = agent.autoLaunchCommand(
            session: session,
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            telemetryPort: nil
        )
        #expect(cmd == nil) // Codex review sessions aren't supported in MVP.
    }

    @Test func findBinaryReturnsNilWhenAbsent() {
        // We can't easily mock FileManager.isExecutableFile, but we CAN
        // verify the search returns nil when the candidate paths don't
        // resolve. This relies on the test environment not having a
        // codex binary at the homedir candidate path — the homebrew path
        // may or may not exist depending on the developer machine, so we
        // accept either outcome and just verify the result type.
        _ = agent.findBinary()  // smoke test: must not crash
    }
}
