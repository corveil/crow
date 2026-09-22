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
    case reviewNotSupported(String)

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
        case .reviewNotSupported(let kind):
            return "Agent \"\(kind)\" does not support review sessions; hand the review to a review-capable agent instead"
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

    /// Compose the resume brief for an **extra Manager** handed off mid-flight
    /// (CROW-1283). A Manager orchestrates from the dev root and has no worktree,
    /// branch, or ticket to inspect, so the worktree git brief (`git status` /
    /// `git log` / `git diff`) that ``buildPrompt(from:to:session:worktrees:note:)``
    /// produces does not describe its work. This is a short orientation instead:
    /// who the prior agent was, the optional handoff note, and "continue
    /// orchestration from the dev root". Seeded as argv on first launch (like the
    /// Explore brief), never pasted into the composer.
    public static func buildManagerPrompt(
        from priorKind: AgentKind,
        to targetKind: AgentKind,
        note: String?,
        devRoot: String?
    ) -> String {
        var lines: [String] = [
            "# Manager Agent Handoff",
            "",
            "You are taking over this Crow **Manager** session from **\(priorKind.displayName)**.",
            "The previous agent ran out of credits (or the user switched agents).",
            "Conversation history does not transfer across agents, but this Manager's",
            "identity, name, links, and orchestration context are unchanged.",
            "",
            "Continue orchestration from the dev root. Drive and inspect work sessions",
            "with the `crow` CLI as before — do not re-scaffold or recreate anything.",
        ]

        if let devRoot = devRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !devRoot.isEmpty {
            lines.append("")
            lines.append("Dev root: `\(devRoot)`")
        }

        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("")
            lines.append("## Handoff note")
            lines.append("")
            lines.append(note)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
