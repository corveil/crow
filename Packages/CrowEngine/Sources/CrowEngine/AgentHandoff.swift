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

/// The Scratch item that opened this Manager (`todo explore` / `todo ticket`
/// sets `linkedSessionID`). Re-included on handoff so the incoming agent
/// still has the original ask (CROW-1314).
public struct ManagerHandoffScratch: Sendable, Equatable {
    public var text: String
    public var note: String
    public var tags: [String]
    public var state: String

    public init(text: String, note: String, tags: [String], state: String) {
        self.text = text
        self.note = note
        self.tags = tags
        self.state = state
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tags.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// One session link rendered into the Manager handoff brief.
public struct ManagerHandoffLink: Sendable, Equatable {
    public var label: String
    public var url: String
    public var type: String

    public init(label: String, url: String, type: String) {
        self.label = label
        self.url = url
        self.type = type
    }
}

/// Optional context sections for ``AgentHandoff/buildManagerPrompt``.
/// Every field is omitted from the brief when empty. Transcripts are not
/// copied — `transcriptPath` is a pointer (ADR 0011 / CROW-1314).
public struct ManagerHandoffContext: Sendable, Equatable {
    public var sessionName: String
    public var ticketURL: String?
    public var ticketTitle: String?
    public var links: [ManagerHandoffLink]
    public var scratch: ManagerHandoffScratch?
    public var transcriptPath: String?
    public var scrollback: String?

    public init(
        sessionName: String = "",
        ticketURL: String? = nil,
        ticketTitle: String? = nil,
        links: [ManagerHandoffLink] = [],
        scratch: ManagerHandoffScratch? = nil,
        transcriptPath: String? = nil,
        scrollback: String? = nil
    ) {
        self.sessionName = sessionName
        self.ticketURL = ticketURL
        self.ticketTitle = ticketTitle
        self.links = links
        self.scratch = scratch
        self.transcriptPath = transcriptPath
        self.scrollback = scrollback
    }

    public static let none = ManagerHandoffContext()
}

/// Builds the resume brief seeded into the incoming agent after a mid-session
/// handoff. Conversation history does not transfer across agents — Crow
/// preserves session/worktree/ticket identity and gives the new agent a clear
/// resume point (CROW-627 / ADR 0011).
public enum AgentHandoff {
    /// Pane lines copied into a Manager handoff brief (CROW-1314).
    static let scrollbackMaxLines = 200
    /// Hard cap on that tail so a wide TUI cannot blow the launch prompt.
    static let scrollbackMaxCharacters = 24_000
    static let scratchTextMaxCharacters = 4_000
    static let scratchNoteMaxCharacters = 4_000
    static let linkMaxCount = 12
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
    /// produces does not describe its work.
    ///
    /// The brief is a **context pointer**, not a transcript migration
    /// (ADR 0011 / CROW-1314): who the prior agent was, the optional note,
    /// and — when present — the session's name/ticket/links, the originating
    /// Scratch item, the prior agent's on-disk transcript path, and a capped
    /// scrollback tail. Empty sections are omitted. Seeded as argv on first
    /// launch (like the Explore brief), never pasted into the composer.
    public static func buildManagerPrompt(
        from priorKind: AgentKind,
        to targetKind: AgentKind,
        note: String?,
        devRoot: String?,
        context: ManagerHandoffContext = .none
    ) -> String {
        var lines: [String] = [
            "# Manager Agent Handoff",
            "",
            "You are taking over this Crow **Manager** session from **\(priorKind.displayName)**.",
            "You are running as **\(targetKind.displayName)**.",
            "The previous agent ran out of credits (or the user switched agents).",
            "Conversation history does not transfer across agents. Sections below,",
            "when present, point at where the previous agent left off; they are",
            "not a copied transcript. This Manager's identity, name, links, and",
            "orchestration context are unchanged.",
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

        appendSessionSection(context, to: &lines)
        appendScratchSection(context.scratch, to: &lines)
        appendTranscriptSection(context.transcriptPath, to: &lines)
        appendScrollbackSection(context.scrollback, to: &lines)

        return lines.joined(separator: "\n") + "\n"
    }

    /// The Scratch item whose most recent session link is this Manager.
    /// Nil when none matches, or when text, note, and tags are all blank.
    public static func originatingScratch(
        in todos: [TodoItem]?, sessionID: UUID
    ) -> ManagerHandoffScratch? {
        guard let todos else { return nil }
        let matches = todos.filter { $0.linkedSessionID == sessionID }
        guard let item = matches.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        let scratch = ManagerHandoffScratch(
            text: item.text,
            note: item.note,
            tags: item.tags,
            state: item.state.rawValue
        )
        return scratch.isEmpty ? nil : scratch
    }

    private static func appendSessionSection(_ context: ManagerHandoffContext, to lines: inout [String]) {
        let name = context.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = context.ticketTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ticket = context.ticketURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let links = context.links.prefix(linkMaxCount).filter { link in
            !link.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !link.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !name.isEmpty || !title.isEmpty || !ticket.isEmpty || !links.isEmpty else { return }
        lines.append("")
        lines.append("## Session")
        lines.append("")
        if !name.isEmpty {
            lines.append("Name: \(cappedHead(name, max: 256))")
        }
        if !title.isEmpty || !ticket.isEmpty {
            let ticketLine: String
            if !title.isEmpty && !ticket.isEmpty {
                ticketLine = "\(cappedHead(title, max: 300)) — \(cappedHead(ticket, max: 500))"
            } else if !title.isEmpty {
                ticketLine = cappedHead(title, max: 300)
            } else {
                ticketLine = cappedHead(ticket, max: 500)
            }
            lines.append("Ticket: \(ticketLine)")
        }
        if !links.isEmpty {
            lines.append("Links:")
            for link in links {
                let label = cappedHead(
                    link.label.trimmingCharacters(in: .whitespacesAndNewlines), max: 120)
                let url = cappedHead(
                    link.url.trimmingCharacters(in: .whitespacesAndNewlines), max: 500)
                let type = link.type.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty {
                    lines.append("- \(url)")
                } else if url.isEmpty {
                    lines.append("- \(label)")
                } else if type.isEmpty {
                    lines.append("- \(label): \(url)")
                } else {
                    lines.append("- \(label) (\(type)): \(url)")
                }
            }
        }
    }

    private static func appendScratchSection(_ scratch: ManagerHandoffScratch?, to lines: inout [String]) {
        guard let scratch, !scratch.isEmpty else { return }
        lines.append("")
        lines.append("## Originating Scratch item")
        lines.append("")
        let state = scratch.state.trimmingCharacters(in: .whitespacesAndNewlines)
        if !state.isEmpty {
            lines.append("State: \(state)")
            lines.append("")
        }
        let text = scratch.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(cappedHead(text, max: scratchTextMaxCharacters))
        }
        let note = scratch.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("")
            lines.append("### Notes")
            lines.append("")
            lines.append(cappedHead(note, max: scratchNoteMaxCharacters))
        }
        let tags = scratch.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            lines.append("")
            lines.append("Tags: \(cappedHead(tags.joined(separator: ", "), max: 500))")
        }
    }

    private static func appendTranscriptSection(_ path: String?, to lines: inout [String]) {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            return
        }
        lines.append("")
        lines.append("## Prior agent transcript")
        lines.append("")
        lines.append("Read this file to see where the previous agent left off:")
        lines.append(cappedTail(path, maxCharacters: 1_024))
    }

    private static func appendScrollbackSection(_ raw: String?, to lines: inout [String]) {
        guard let raw else { return }
        let body = cappedScrollback(raw)
        guard !body.isEmpty else { return }
        lines.append("")
        lines.append("## Recent terminal scrollback")
        lines.append("")
        lines.append("Last lines from the previous agent's pane:")
        lines.append(fenced(body))
    }

    /// Keep the start of a field. A Scratch item's ask is at the top.
    static func cappedHead(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        let end = text.index(text.startIndex, offsetBy: max - 1)
        return String(text[..<end]) + "…"
    }

    /// Keep the end of a field. The newest pane output is what the next
    /// agent needs.
    static func cappedTail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 1 else { return text }
        let start = text.index(text.endIndex, offsetBy: -(maxCharacters - 1))
        return "…" + String(text[start...])
    }

    static func cappedScrollback(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return scalar.value >= 0x20 && scalar.value != 0x7F
        })
        var lines = cleaned.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        if lines.count > scrollbackMaxLines {
            lines = Array(lines.suffix(scrollbackMaxLines))
        }
        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return "" }
        return cappedTail(joined, maxCharacters: scrollbackMaxCharacters)
    }

    private static func fenced(_ body: String) -> String {
        var tick = "```"
        while body.contains(tick) { tick += "`" }
        return "\(tick)\n\(body)\n\(tick)"
    }
}
