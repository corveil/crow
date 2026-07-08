import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Re-homes the root-suite coverage for launch-token detection and the shared
/// launch-text prep, which moved into `CrowEngine/AgentLaunch.swift` when the
/// send path left `AppDelegate` (CROW-581). Was `CommandLaunchesTokenTests`
/// (token anchoring) and `DeferredLaunchTests` (hook-write + OTEL prep).

// MARK: - Token anchoring (was CommandLaunchesTokenTests)

@Suite struct CommandLaunchesTokenTests {
    private func launches(_ command: String, _ token: String = "claude") -> Bool {
        AgentLaunch.commandLaunchesToken(command, token: token)
    }

    @Test func matchesAtStartOfCommand() {
        #expect(launches("claude"))
        #expect(launches("claude --continue"))
        #expect(launches("claude 'do the thing'"))          // token then quote
    }

    @Test func matchesAfterShellSeparators() {
        #expect(launches("cd /repo && claude"))
        #expect(launches("export X=1; claude --resume"))
        #expect(launches("false || claude"))
        #expect(launches("echo hi | claude"))
    }

    @Test func matchesAfterPathSeparator() {
        // A launch by absolute/relative path still counts.
        #expect(launches("/opt/homebrew/bin/claude --continue"))
        #expect(launches("./claude"))
    }

    @Test func rejectsIncidentalSubstrings() {
        // The token embedded in prose or another word must NOT flip readiness —
        // the anchoring guard against e.g. Cursor's "agent" token in a sentence.
        #expect(launches("agent", "agent"))                  // sanity: bare token DOES launch
        #expect(!launches("the agent finished the task", "agent"))
        #expect(!launches("please ask claude to help"))      // mid-sentence, space-prefixed word
        #expect(!launches("claudette --run"))                // token is a prefix of a longer word
        #expect(!launches("myclaude"))                       // token is a suffix of a longer word
        #expect(!launches("echo claude-is-great"))           // token then '-', not a boundary
    }

    @Test func respectsTrailingBoundary() {
        // Boundary is space, end-of-string, or a quote — not arbitrary punctuation.
        #expect(launches("claude"))                          // end of string
        #expect(launches("claude\t--flag"))                  // whitespace (tab)
        #expect(launches(#"claude"quoted""#))                // double-quote boundary
    }
}

// MARK: - Launch-text prep (was DeferredLaunchTests)

/// Records whether `writeHookConfig` was invoked, and with what, so the test can
/// assert the hook file gets written exactly on the launch path.
private final class SpyHookConfigWriter: HookConfigWriter, @unchecked Sendable {
    struct Call: Equatable { let worktreePath: String; let sessionID: UUID; let crowPath: String }
    private(set) var calls: [Call] = []
    func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws {
        calls.append(Call(worktreePath: worktreePath, sessionID: sessionID, crowPath: crowPath))
    }
    func removeHookConfig(worktreePath: String) {}
}

private struct NoopStateSignalSource: StateSignalSource {
    func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition { AgentStateTransition() }
}

/// Minimal `CodingAgent` for exercising `AgentLaunch.prepareAgentLaunchText`.
/// Only `kind`, `launchCommandToken`, and `hookConfigWriter` are consulted by
/// the code under test; the rest are inert stubs.
private struct MockAgent: CodingAgent {
    var kind: AgentKind
    let spy: SpyHookConfigWriter
    var launchCommandToken: String = "claude"

    var displayName: String { "Mock" }
    var iconSystemName: String { "sparkles" }
    var supportsRemoteControl: Bool { false }
    var hookConfigWriter: any HookConfigWriter { spy }
    var stateSignalSource: any StateSignalSource { NoopStateSignalSource() }
    func findBinary() -> String? { "/usr/bin/true" }
    func autoLaunchCommand(session: Session, worktreePath: String, remoteControlEnabled: Bool, autoPermissionMode: Bool, telemetryPort: UInt16?) -> String? { nil }
    func generatePrompt(session: Session, worktrees: [SessionWorktree], ticketURL: String?, provider: Provider?, codeProvider: Provider?) async -> String { "" }
    func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) async throws -> String { "" }
}

@Suite struct PrepareAgentLaunchTextTests {
    private func agent(_ kind: AgentKind) -> MockAgent { MockAgent(kind: kind, spy: SpyHookConfigWriter()) }

    @Test func nonLaunchCommandPassesThroughAndWritesNoHook() {
        let a = agent(.claudeCode)
        let (text, didLaunch) = AgentLaunch.prepareAgentLaunchText(
            command: "ls -la", agent: a, sessionID: UUID(),
            worktreePath: "/tmp/wt", crowPath: "/usr/local/bin/crow", telemetryPort: 4318)
        #expect(text == "ls -la")
        #expect(!didLaunch)
        #expect(a.spy.calls.isEmpty)   // no launch → no hook config written
    }

    @Test func launchWritesHookConfigForTheSession() {
        let a = agent(.claudeCode)
        let sid = UUID()
        let (_, didLaunch) = AgentLaunch.prepareAgentLaunchText(
            command: "claude --continue", agent: a, sessionID: sid,
            worktreePath: "/tmp/wt", crowPath: "/usr/local/bin/crow", telemetryPort: nil)
        #expect(didLaunch)
        #expect(a.spy.calls == [.init(worktreePath: "/tmp/wt", sessionID: sid, crowPath: "/usr/local/bin/crow")])
    }

    @Test func missingWorktreeSkipsHookConfig() {
        let a = agent(.claudeCode)
        let (_, didLaunch) = AgentLaunch.prepareAgentLaunchText(
            command: "claude", agent: a, sessionID: UUID(),
            worktreePath: nil, crowPath: nil, telemetryPort: nil)
        #expect(didLaunch)
        #expect(a.spy.calls.isEmpty)   // no worktree/crowPath → nothing to write
    }

    @Test func prependsOtelForClaudeWithPort() {
        let a = agent(.claudeCode)
        let sid = UUID()
        let (text, didLaunch) = AgentLaunch.prepareAgentLaunchText(
            command: "claude --continue", agent: a, sessionID: sid,
            worktreePath: nil, crowPath: nil, telemetryPort: 4318)
        #expect(didLaunch)
        #expect(text.hasPrefix("export CLAUDE_CODE_ENABLE_TELEMETRY=1 "))
        #expect(text.contains("OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318"))
        #expect(text.contains("crow.session.id=\(sid.uuidString)"))
        #expect(text.hasSuffix("&& claude --continue"))
    }

    @Test func noOtelForClaudeWithoutPort() {
        let a = agent(.claudeCode)
        let (text, _) = AgentLaunch.prepareAgentLaunchText(
            command: "claude", agent: a, sessionID: UUID(),
            worktreePath: nil, crowPath: nil, telemetryPort: nil)
        #expect(text == "claude")   // no port → no telemetry export
    }

    @Test func noOtelForNonClaudeAgentEvenWithPort() {
        // OTEL is Claude-specific — a Cursor/Codex launch never gets the export
        // block even when a telemetry port is available.
        var a = agent(.cursor)
        a.launchCommandToken = "cursor-agent"
        let (text, didLaunch) = AgentLaunch.prepareAgentLaunchText(
            command: "cursor-agent chat", agent: a, sessionID: UUID(),
            worktreePath: nil, crowPath: nil, telemetryPort: 4318)
        #expect(didLaunch)
        #expect(text == "cursor-agent chat")
    }
}
