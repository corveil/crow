import Foundation
import Testing
@testable import Crow

/// Verifies `AppDelegate.commandLaunchesToken` anchors token matches at
/// shell-word boundaries instead of doing a naked substring check.
///
/// Motivation: Cursor's `launchCommandToken` is `"agent"` — a common
/// English word that can appear inside any `crow send` prose
/// (e.g. *"refactor the agent registry"*). A bare `command.contains(token)`
/// would falsely flip `terminalReadiness = .agentLaunched` on arbitrary
/// text and pollute `list-terminals` readiness reporting.
@Suite("commandLaunchesToken — agent launch detection")
struct CommandLaunchesTokenTests {

    // MARK: Auto-launch shapes — must match

    @Test func bareAgentLaunch() {
        #expect(AppDelegate.commandLaunchesToken("agent\n", token: "agent"))
    }

    @Test func bareCodexLaunch() {
        #expect(AppDelegate.commandLaunchesToken("codex\n", token: "codex"))
    }

    @Test func claudeWithArgs() {
        #expect(AppDelegate.commandLaunchesToken("claude --rc --name 'foo' \"prompt\"", token: "claude"))
    }

    @Test func envPrefixedClaudeLaunch() {
        let cmd = "export CLAUDE_CODE_ENABLE_TELEMETRY=1 OTEL_EXPORTER_OTLP_PROTOCOL=http/json && claude --rc"
        #expect(AppDelegate.commandLaunchesToken(cmd, token: "claude"))
    }

    @Test func cdPrefixedAgentLaunch() {
        // Shape emitted by `CursorLauncher.launchCommand`.
        let cmd = "cd '/Users/x/wt' && agent \"$(cat /tmp/prompt.md)\""
        #expect(AppDelegate.commandLaunchesToken(cmd, token: "agent"))
    }

    @Test func cdPrefixedCodexLaunch() {
        let cmd = "cd '/Users/x/wt' && codex \"$(cat /tmp/prompt.md)\""
        #expect(AppDelegate.commandLaunchesToken(cmd, token: "codex"))
    }

    // MARK: Absolute-path resolved binaries — must match
    // `resolveClaudeInCommand` rewrites the bare `claude` token to an
    // absolute path before the deferred-launch paste reaches
    // `prepareAgentLaunchText`. The left boundary must accept `/` or
    // hook-config writes (the per-worktree `.claude/settings.local.json`)
    // and Claude's OTEL env injection both silently skip.

    @Test func pathResolvedClaudeBrew() {
        #expect(AppDelegate.commandLaunchesToken("/opt/homebrew/bin/claude --rc --name 'foo'", token: "claude"))
    }

    @Test func pathResolvedClaudeLocal() {
        #expect(AppDelegate.commandLaunchesToken("/usr/local/bin/claude --rc", token: "claude"))
    }

    @Test func pathResolvedAgent() {
        #expect(AppDelegate.commandLaunchesToken("/opt/homebrew/bin/agent\n", token: "agent"))
    }

    @Test func pathResolvedClaudeWithEnvPrefix() {
        // The full shape that flows through pasteDeferredLaunch on the
        // standard #408 path — env prefix from telemetry merge + path-resolved
        // claude. The guard must still admit this so writeHookConfig runs.
        let cmd = "export CLAUDE_CODE_ENABLE_TELEMETRY=1 OTEL_EXPORTER_OTLP_PROTOCOL=http/json && /opt/homebrew/bin/claude --rc"
        #expect(AppDelegate.commandLaunchesToken(cmd, token: "claude"))
    }

    // MARK: Incidental prose — must NOT match (the Cursor footgun)

    @Test func proseContainingAgentRejected() {
        #expect(!AppDelegate.commandLaunchesToken("refactor the agent registry", token: "agent"))
    }

    @Test func proseContainingAgentMidSentenceRejected() {
        #expect(!AppDelegate.commandLaunchesToken("Please update the agent kind enum", token: "agent"))
    }

    @Test func flagLikeAgentRejected() {
        // `--agent` is preceded by `-`, not a shell separator.
        #expect(!AppDelegate.commandLaunchesToken("the --agent flag does X", token: "agent"))
    }

    @Test func proseContainingClaudeStillRejected() {
        // Even rare-as-prose tokens are now properly word-bounded.
        #expect(!AppDelegate.commandLaunchesToken("the claudeKind enum", token: "claude"))
    }

    @Test func pathLikeAgentSubstringRejected() {
        // `/tmp/agent_log` has `/` left of `agent` but `_log` on the right,
        // so the right-boundary (`\s|$|["']`) keeps it rejected. Confirms
        // the `/` boundary doesn't open the door to incidental path substrings.
        #expect(!AppDelegate.commandLaunchesToken("tail -f /tmp/agent_log", token: "agent"))
    }

    // MARK: Edge cases

    @Test func emptyCommandRejected() {
        #expect(!AppDelegate.commandLaunchesToken("", token: "agent"))
    }

    @Test func tokenAtEndOfString() {
        #expect(AppDelegate.commandLaunchesToken("cd /x && agent", token: "agent"))
    }

    @Test func semicolonSeparator() {
        #expect(AppDelegate.commandLaunchesToken("echo hi; agent\n", token: "agent"))
    }
}
