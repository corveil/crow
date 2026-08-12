import Foundation
import Testing
import CrowCore
import CrowClaude
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
    var alternateLaunchCommandTokens: [String] = []

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

    /// A legacy install invoked under the alias still counts as a launch, so it
    /// gets hook config written. Crow prefers `cursor-agent` since CROW-989, but
    /// an older install — or an operator recovering a pane by hand with
    /// `crow send "agent --continue"` — still says `agent`, and a miss here would
    /// silently leave that session without hooks.
    @Test func alternateTokenAlsoCountsAsALaunch() {
        var a = agent(.cursor)
        a.launchCommandToken = "cursor-agent"
        a.alternateLaunchCommandTokens = ["agent"]
        let sid = UUID()
        let (_, didLaunch) = AgentLaunch.prepareAgentLaunchText(
            command: "'/Users/x/.local/bin/agent' --trust", agent: a, sessionID: sid,
            worktreePath: "/tmp/wt", crowPath: "/usr/local/bin/crow", telemetryPort: nil)
        #expect(didLaunch)
        #expect(a.spy.calls == [.init(worktreePath: "/tmp/wt", sessionID: sid, crowPath: "/usr/local/bin/crow")])
    }

    /// The alias must not widen matching into prose. `commandLaunchesToken` is
    /// already anchored, and adding `agent` as an alias doesn't relax that —
    /// otherwise a `crow send` of ordinary text mentioning the word would flip
    /// readiness and rewrite hook config.
    @Test func aliasDoesNotMatchIncidentalProse() {
        var a = agent(.cursor)
        a.launchCommandToken = "cursor-agent"
        a.alternateLaunchCommandTokens = ["agent"]
        #expect(!AgentLaunch.commandLaunchesAgent("ask the agent to retry", agent: a))
        #expect(!AgentLaunch.commandLaunchesAgent("./my-agent run", agent: a))
        #expect(AgentLaunch.commandLaunchesAgent("agent --continue", agent: a))
        #expect(AgentLaunch.commandLaunchesAgent("cd /tmp && cursor-agent", agent: a))
    }

    /// An agent with no aliases matches exactly as before — the CROW-989
    /// plumbing is inert for every single-name harness.
    @Test func singleTokenAgentMatchingIsUnchanged() {
        let a = agent(.claudeCode)
        #expect(AgentLaunch.commandLaunchesAgent("claude --continue", agent: a))
        #expect(!AgentLaunch.commandLaunchesAgent("agent --continue", agent: a))
    }

    /// #897 end-to-end on the wiring: the launch path resolves its crow binary
    /// the way production does, so what lands in the hook file is the stable
    /// `{devRoot}/.claude/bin/crow` symlink — never the `.build/…` product of
    /// whichever worktree the daemon happened to be built in.
    @Test func launchResolvesTheStableSymlinkNotABuildProduct() throws {
        let fm = FileManager.default
        let devRoot = fm.temporaryDirectory.appendingPathComponent("agentlaunch-crowpath-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: devRoot) }
        let buildDir = devRoot.appendingPathComponent(".build/arm64-apple-macosx/debug")
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let appBinary = buildDir.appendingPathComponent("crow")
        try Data("#!/bin/sh\n".utf8).write(to: appBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appBinary.path)

        let a = agent(.claudeCode)
        let sid = UUID()
        _ = AgentLaunch.prepareAgentLaunchText(
            command: "claude --continue", agent: a, sessionID: sid,
            worktreePath: "/tmp/wt",
            crowPath: ClaudeHookConfigWriter.resolveCrowBinary(
                devRoot: devRoot.path, appCrowPath: appBinary.path),
            telemetryPort: nil)

        let written = try #require(a.spy.calls.first)
        #expect(written.crowPath == devRoot.appendingPathComponent(".claude/bin/crow").path)
        #expect(!written.crowPath.contains("/.build/"))
    }
}
