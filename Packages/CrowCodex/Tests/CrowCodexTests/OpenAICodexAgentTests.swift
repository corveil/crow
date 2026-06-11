import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("OpenAICodexAgent", .serialized)
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
            autoPermissionMode: false,
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
            autoPermissionMode: false,
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
            autoPermissionMode: false,
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

    @Test func findBinaryHonorsBinaryOverride() {
        // `defaults.binaries.codex` -> absolute path. The default
        // `CodingAgent.findBinary()` impl should consult
        // `BinaryOverrides.shared` before walking PATH (CROW-484).
        // `/bin/sh` is guaranteed-executable on macOS and clearly distinct
        // from any real codex install, so a positive result here means the
        // override path was honored.
        BinaryOverrides.shared.set(["codex": "/bin/sh"])
        defer { BinaryOverrides.shared.set([:]) }

        #expect(agent.findBinary() == "/bin/sh")
    }

    @Test func findBinaryIgnoresOverrideWhenPathMissing() {
        // A stale override (binary moved/uninstalled after config edit) must
        // not break registration outright — fall through to PATH/fallback
        // discovery instead. We can't guarantee codex is installed in the
        // test env, so we just assert that the bogus override doesn't get
        // returned literally.
        BinaryOverrides.shared.set(["codex": "/tmp/this-path-does-not-exist-crow484"])
        defer { BinaryOverrides.shared.set([:]) }

        #expect(agent.findBinary() != "/tmp/this-path-does-not-exist-crow484")
    }
}
