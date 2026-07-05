import Foundation
import CrowCore
import CrowClaude

/// RPC-handler helpers relocated out of `AppDelegate` so the router can move
/// into CrowEngine (CROW-581). These are pure, `nonisolated`, and framework-
/// light (Foundation + CrowCore/CrowClaude).
public enum EngineHelpers {
    /// Map a `transition-ticket --to` argument to a `TicketStatus`.
    public static func ticketStatus(fromArg arg: String) -> TicketStatus? {
        switch arg.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "") {
        case "inprogress": return .inProgress
        case "inreview": return .inReview
        case "done", "completed", "closed": return .done
        default: return nil
        }
    }

    /// Run `create` up to `attempts` times, rethrowing the last error after
    /// exhausting all attempts. Pure over the `create` closure so the retry
    /// policy is unit-testable without tmux (issue #408).
    public static func registerWithRetry<T>(
        attempts: Int,
        create: (_ attempt: Int) throws -> T
    ) throws -> T {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try create(attempt)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RPCError.applicationError("registerWithRetry: no attempts run")
    }

    /// Rewrite a bare `claude` launch command to an absolute binary path (and,
    /// when requested, append the `--rc`/`--name` remote-control suffix).
    public static func resolveClaudeInCommand(
        _ command: String,
        remoteControl: Bool = false,
        sessionName: String? = nil
    ) -> String {
        for path in SessionService.claudeBinaryCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                let rest: String?
                if command == "claude" {
                    rest = ""
                } else if command.hasPrefix("claude ") {
                    rest = String(command.dropFirst("claude".count))
                } else {
                    rest = nil
                }
                guard let rest else { return command }

                let wantsRC = remoteControl
                    && !command.contains("--rc")
                    && !command.contains("--remote-control")
                let extra = wantsRC
                    ? ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: sessionName)
                    : ""
                return path + extra + rest
            }
        }
        return command
    }
}
