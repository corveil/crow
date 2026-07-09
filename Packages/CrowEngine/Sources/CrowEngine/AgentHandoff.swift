import Foundation
import CrowCore

/// Errors raised when switching a session's coding agent mid-flight (CROW-627).
public enum AgentHandoffError: Error, LocalizedError, Equatable {
    case sessionNotFound
    case managerNotSupported
    case sameAgent
    case agentNotRegistered(String)
    case agentBinaryMissing(String)
    case noWorktree
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        case .managerNotSupported:
            return "Manager sessions cannot be handed off; change the Manager agent in Settings and restart"
        case .sameAgent:
            return "Session is already using that agent"
        case .agentNotRegistered(let kind):
            return "Agent \"\(kind)\" is not registered"
        case .agentBinaryMissing(let kind):
            return "Agent \"\(kind)\" is not installed (CLI binary not found)"
        case .noWorktree:
            return "Session has no worktree to hand off"
        case .launchFailed(let message):
            return "Failed to build handoff launch command: \(message)"
        }
    }
}

/// Builds the resume brief seeded into the incoming agent after a mid-session
/// handoff. Conversation history does not transfer across agents — Crow
/// preserves session/worktree/ticket identity and gives the new agent a clear
/// resume point (CROW-627 / ADR 0009).
public enum AgentHandoff {
    /// Compose a handoff prompt: prior-agent context + optional note, then the
    /// target agent's normal workspace/ticket brief.
    public static func buildPrompt(
        from priorKind: AgentKind,
        to target: any CodingAgent,
        session: Session,
        worktrees: [SessionWorktree],
        note: String?
    ) async -> String {
        var header: [String] = [
            "# Agent Handoff",
            "",
            "You are taking over this Crow session from **\(priorKind.displayName)**.",
            "The previous agent ran out of credits (or the user switched agents).",
            "Session identity, worktree, branch, and ticket context are unchanged.",
            "",
            "**Do not** re-scaffold the workspace or recreate the branch.",
            "Inspect the current git state and continue the unfinished work.",
            "",
            "Suggested orientation:",
            "```bash",
            "git status",
            "git log --oneline -15",
            "git diff",
            "```",
        ]

        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            header.append("")
            header.append("## Handoff note")
            header.append("")
            header.append(note)
        }

        header.append("")
        header.append("---")
        header.append("")

        let body = await target.generatePrompt(
            session: session,
            worktrees: worktrees,
            ticketURL: session.ticketURL,
            provider: session.provider,
            codeProvider: session.codeProvider
        )
        return header.joined(separator: "\n") + body
    }
}
