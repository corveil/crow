import Foundation
import CrowCore

/// Agent-launch text preparation, shared by the `send` RPC and the #408
/// deferred-launch paste path. Relocated out of `AppDelegate` so the engine
/// (`SessionService`) can use it without reaching into the app module
/// (CROW-581 headless-engine migration).
public enum AgentLaunch {
    /// Given a `crow send` command that may launch the agent, write the
    /// per-worktree hook config so the agent's hooks route back to `sessionID`,
    /// and (for Claude) prepend the OTEL telemetry exporter env vars. Returns
    /// the final text plus whether `command` actually launches the agent (its
    /// `launchCommandToken` is present). Single source of truth shared by the
    /// `send` RPC and the deferred-launch paste so the two never drift.
    public static func prepareAgentLaunchText(
        command: String,
        agent: any CodingAgent,
        sessionID: UUID,
        worktreePath: String?,
        crowPath: String?,
        telemetryPort: UInt16?
    ) -> (text: String, didLaunch: Bool) {
        guard commandLaunchesToken(command, token: agent.launchCommandToken) else { return (command, false) }
        if let worktreePath, let crowPath {
            do {
                try agent.hookConfigWriter.writeHookConfig(
                    worktreePath: worktreePath,
                    sessionID: sessionID,
                    crowPath: crowPath
                )
            } catch {
                NSLog("[AgentLaunch] Failed to write hook config for session %@: %@",
                      sessionID.uuidString, error.localizedDescription)
            }
        }
        // OTEL telemetry env vars are Claude-specific — Codex has no equivalent
        // OTLP exporter.
        guard agent.kind == .claudeCode, let port = telemetryPort else { return (command, true) }
        let vars = [
            "CLAUDE_CODE_ENABLE_TELEMETRY=1",
            "OTEL_METRICS_EXPORTER=otlp",
            "OTEL_LOGS_EXPORTER=otlp",
            "OTEL_EXPORTER_OTLP_PROTOCOL=http/json",
            "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(port)",
            "OTEL_RESOURCE_ATTRIBUTES=crow.session.id=\(sessionID.uuidString)",
        ].joined(separator: " ")
        return ("export \(vars) && \(command)", true)
    }

    /// Whether `command` invokes `token` as a shell command rather than an
    /// incidental substring. Anchored at start-of-string, after a shell command
    /// separator (`;`, `&&`, `||`, `|`), or at a path separator (`/`). Prevents
    /// flipping readiness on prose that merely contains an agent token like
    /// Cursor's `"agent"`.
    public static func commandLaunchesToken(_ command: String, token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?:^|[;&|]\\s*|/)\(escaped)(?=\\s|$|[\"'])"
        return command.range(of: pattern, options: .regularExpression) != nil
    }
}
