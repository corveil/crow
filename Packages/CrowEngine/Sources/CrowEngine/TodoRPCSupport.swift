import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `todo-*` RPC handlers (CROW-1231).
///
/// Kept out of the router so param validation, list filters, and the explore
/// brief are unit-testable without a socket (same pattern as `JobRPC`).
public enum TodoRPC {
    public static let validStates = TodoState.allCases.map(\.rawValue)
    public static let validLinkTypes = TodoLinkType.allCases.map(\.rawValue)

    /// Extract a todo UUID from `todo_id`.
    public static func decodeID(_ params: [String: JSONValue]) throws -> UUID {
        guard let raw = params["todo_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw RPCError.invalidParams("todo_id must be a UUID")
        }
        return id
    }

    /// Extract and trim the item text. Rejects missing or whitespace-only.
    public static func decodeText(_ value: JSONValue?) throws -> String {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw RPCError.invalidParams("text is required")
        }
        return text
    }

    public static func decodeNote(_ value: JSONValue?) -> String {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static func decodeTags(_ value: JSONValue?) throws -> [String] {
        guard let value else { return [] }
        guard let items = value.arrayValue else {
            throw RPCError.invalidParams("tags must be an array of strings")
        }
        let tags = items.compactMap(\.stringValue)
        guard tags.count == items.count else {
            throw RPCError.invalidParams("tags must be an array of strings")
        }
        return TodoItem.normalizeTags(tags)
    }

    public static func decodePriority(_ value: JSONValue?) throws -> String? {
        do {
            return try TodoItem.normalizePriority(value?.stringValue)
        } catch is TodoItem.NormalizeError {
            throw RPCError.invalidParams(TodoItem.invalidPriorityMessage)
        }
    }

    public static func decodeState(_ value: JSONValue?) throws -> TodoState? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state = TodoState(rawValue: trimmed) else {
            throw RPCError.invalidParams(
                "state must be one of: \(validStates.joined(separator: ", "))")
        }
        return state
    }

    public static func decodeLinkType(_ value: JSONValue?) throws -> TodoLinkType {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let type = TodoLinkType(rawValue: raw) else {
            throw RPCError.invalidParams(
                "type must be one of: \(validLinkTypes.joined(separator: ", "))")
        }
        return type
    }

    /// Filter `items` by optional `state` and `tag` query params.
    public static func filtered(_ items: [TodoItem], params: [String: JSONValue]) throws -> [TodoItem] {
        let state = try decodeState(params["state"])
        let tag = params["tag"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nonemptyTag = (tag?.isEmpty == false) ? tag : nil
        return items.filter { item in
            if let state, item.state != state { return false }
            if let nonemptyTag, !item.tags.contains(where: { $0.lowercased() == nonemptyTag }) {
                return false
            }
            return true
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Apply an edit patch. Only provided fields change.
    public static func applyingEdit(_ item: TodoItem, params: [String: JSONValue]) throws -> TodoItem {
        var next = item
        if params["text"] != nil {
            next.text = try decodeText(params["text"])
        }
        if params["note"] != nil {
            next.note = decodeNote(params["note"])
        }
        if params["priority"] != nil {
            next.priority = try decodePriority(params["priority"])
        }
        if params["state"] != nil {
            next.state = try decodeState(params["state"]) ?? item.state
        }
        if params["tags"] != nil {
            next.tags = try decodeTags(params["tags"])
        }
        let add = try decodeTags(params["add_tags"])
        if !add.isEmpty {
            next.tags = TodoItem.normalizeTags(next.tags + add)
        }
        let remove = Set(try decodeTags(params["remove_tags"]).map { $0.lowercased() })
        if !remove.isEmpty {
            next.tags = next.tags.filter { !remove.contains($0.lowercased()) }
        }
        next.updatedAt = Date()
        return next
    }

    public static func todoJSON(_ item: TodoItem) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(item),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
            return .object(["id": .string(item.id.uuidString)])
        }
        return .object(object)
    }

    /// Session name for the Manager spawned by `todo explore`. Truncated so
    /// it stays a valid Crow session name.
    public static func managerName(from text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        let trimmed = String(collapsed.prefix(80))
        if trimmed.isEmpty { return "Scratch" }
        if Validation.isValidSessionName(trimmed) { return trimmed }
        let stripped = String(trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let fallback = String(stripped.prefix(Validation.maxSessionNameLength))
        return fallback.isEmpty ? "Scratch" : fallback
    }

    /// The prompt seeded into the exploring Manager. Read/explain only — this
    /// is the Scratch sibling of `/crow-workspace --explore`. Tells the agent
    /// what to start looking at (the item, this cwd, a recommended next step)
    /// so a submitted brief actually kicks off work (CROW-1237).
    public static func exploreBrief(for item: TodoItem) -> String {
        var lines = [
            "You are exploring a Crow Scratch item in this Manager session. Start now: read the item below, inspect related code in this working directory, and report what it means, what already exists, and a recommended next step.",
            "Do not file a ticket, create a worktree, or start a work session unless I ask.",
            "",
            "## Scratch item",
            item.text,
        ]
        if !item.note.isEmpty {
            lines.append(contentsOf: ["", "## Notes", item.note])
        }
        if !item.tags.isEmpty {
            lines.append(contentsOf: ["", "Tags: " + item.tags.joined(separator: ", ")])
        }
        if let priority = item.priority {
            lines.append("Priority: \(priority)")
        }
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Temp file the Explore Manager launch reads as its initial prompt.
    /// Unique per session so two concurrent Explores cannot clobber each other.
    public static func explorePromptPath(sessionID: UUID) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-explore-\(sessionID.uuidString).md")
    }

    /// Wrap a Manager launch command so the explore brief is argv (job-style
    /// `evalPromptLaunch`), not a TUI paste. Cursor/Grok need `--` so a brief
    /// whose first character is `-` is not parsed as a flag.
    public static func seedLaunchCommand(
        baseCommand: String, promptPath: String, agentKind: AgentKind
    ) -> String {
        ShellLaunchArgs.evalPromptLaunch(
            prefix: baseCommand,
            promptPath: promptPath,
            endOfOptions: seedsExplorePromptWithEndOfOptions(agentKind)
        )
    }

    public static func seedsExplorePromptWithEndOfOptions(_ agentKind: AgentKind) -> Bool {
        agentKind == .cursor || agentKind == .grok
    }

    /// `#{pane_current_command}` looks like a coding-agent TUI, not the
    /// wrapper/shell the Manager window is born as. SessionStart can fire
    /// before the composer owns stdin (Cursor especially); pasting into
    /// zsh is the "first characters go to the shell" failure (CROW-1237).
    public static func paneLooksLikeAgent(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let token = (trimmed as NSString).lastPathComponent.lowercased()
        let shells: Set<String> = [
            "zsh", "bash", "sh", "fish", "dash", "login", "tmux",
            "crow-shell-wrapper.sh",
        ]
        if shells.contains(token) { return false }
        let agents = [
            "claude", "cursor-agent", "codex", "grok", "opencode",
            "muse", "agy", "antigravity",
        ]
        if agents.contains(where: { token == $0 || token.hasPrefix($0) }) {
            return true
        }
        // Cursor's unambiguous name is `cursor-agent`; the colliding `agent`
        // token is accepted only as an exact basename (not `ssh-agent`).
        return token == "agent"
    }

    /// Hook name that means the TUI accepted a prompt (argv or paste).
    public static let userPromptSubmitEventName = "UserPromptSubmit"

    public static func promptWasAccepted(
        hookEventNames: [String], activity: AgentActivityState
    ) -> Bool {
        if hookEventNames.contains(userPromptSubmitEventName) { return true }
        switch activity {
        case .working, .waiting: return true
        case .idle, .done: return false
        }
    }

    /// Body filed with `todo ticket` — the item plus its note, tagged as
    /// originating in Scratch so the trail is visible on the provider too.
    public static func ticketBody(for item: TodoItem) -> String {
        var parts: [String] = []
        if !item.note.isEmpty { parts.append(item.note) }
        if !item.tags.isEmpty {
            parts.append("Tags: " + item.tags.joined(separator: ", "))
        }
        parts.append("Filed from Crow Scratch.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Manager prompt delivery (CROW-1233)

    /// Polls waiting for the Manager pane to exist (20 × 250ms).
    public static let managerTerminalPolls = 20
    public static let managerTerminalPollNanos: UInt64 = 250_000_000

    /// After the agent announces (SessionStart), Cursor's composer still
    /// needs a beat before Enter is accepted (#1233 / #272).
    public static let composerSettleNanos: UInt64 = 1_500_000_000
    /// Already-running Manager (Talk / re-Explore after SessionStart): skip
    /// the long composer settle — the TUI is already focused.
    public static let alreadyUpSettleNanos: UInt64 = 200_000_000

    /// Fresh Manager launch: wait up to 30s (60 × 500ms) for SessionStart.
    public static let agentAnnouncePolls = 60
    /// Existing Manager (Talk / re-Explore): shorter wait — the TUI is
    /// usually already up, but Explore may have just spawned it.
    public static let existingAgentAnnouncePolls = 16
    public static let agentAnnouncePollNanos: UInt64 = 500_000_000

    /// After paste+Enter, wait this long for `.working`/`.waiting` before
    /// retrying a bare Enter. Too short and a slow UserPromptSubmit looks
    /// like a dropped Enter; a second Enter would re-submit leftover text
    /// (#631).
    public static let submitConfirmNanos: UInt64 = 2_000_000_000

    /// Whether this Manager's *current* agent TUI has announced itself.
    /// Keys off `SessionStart` specifically — any other event (or a leftover
    /// count from a previous pane after `recreate-terminal` / `restartManager`)
    /// is not "composer ready". Managers do not track `TerminalReadiness`.
    public static let sessionStartEventName = "SessionStart"

    public static func agentHasAnnounced(hookEventNames: [String]) -> Bool {
        hookEventNames.contains(sessionStartEventName)
    }

    /// Retry a bare Enter only when the agent is up and then stayed idle
    /// after the paste — "words in the box, agent idle". Skip when hooks
    /// never fired (don't double-submit an agent that accepted Enter but
    /// has no hook pipeline) and when UserPromptSubmit / working already
    /// proved the brief landed (CROW-1237).
    public static func shouldRetryEnter(
        activity: AgentActivityState,
        agentAnnounced: Bool,
        promptAccepted: Bool = false
    ) -> Bool {
        guard agentAnnounced, !promptAccepted else { return false }
        switch activity {
        case .working, .waiting: return false
        case .idle, .done: return true
        }
    }
}
