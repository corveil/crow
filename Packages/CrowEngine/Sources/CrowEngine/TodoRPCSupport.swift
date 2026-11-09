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

    /// Resolve a `workspace` param to the workspace's canonical name, or nil
    /// when absent or blank (blank clears it on `todo-edit`). Names match
    /// case-insensitively and a UUID is accepted, via
    /// ``WorkspaceRPC/resolveIndex(_:in:)`` so `--workspace` means the same
    /// thing here as on `crow workspace` and `crow gateway` (CROW-1383).
    public static func decodeWorkspace(_ value: JSONValue?, config: AppConfig) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let raw = value.stringValue else {
            throw RPCError.invalidParams("workspace must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return config.workspaces[try WorkspaceRPC.resolveIndex(trimmed, in: config)].name
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

    /// Apply an edit patch. Only provided fields change. `config` resolves a
    /// `workspace` param; it is only read when that param is present. A blank
    /// `agent_kind` clears the agent, like a blank `workspace`.
    public static func applyingEdit(
        _ item: TodoItem, params: [String: JSONValue], config: AppConfig = AppConfig(),
        isRegistered: (AgentKind) -> Bool = { AgentRegistry.shared.registeredKind($0) != nil }
    ) throws -> TodoItem {
        var next = item
        if params["text"] != nil {
            next.text = try decodeText(params["text"])
        }
        if params["note"] != nil {
            next.note = decodeNote(params["note"])
        }
        if params["append_note"] != nil {
            next.note = appendingNote(decodeNote(params["append_note"]), to: next.note)
        }
        if params["priority"] != nil {
            next.priority = try decodePriority(params["priority"])
        }
        if params["workspace"] != nil {
            next.workspace = try decodeWorkspace(params["workspace"], config: config)
        }
        if params["agent_kind"] != nil {
            next.agentKind = try decodeAgentKind(params["agent_kind"], isRegistered: isRegistered)
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

    /// `note` with `addition` appended after a blank line (CROW-1416). The
    /// Ticket Manager records a diagnosis outcome this way, so the note the
    /// item was captured with survives and is never retyped into a shell.
    /// A blank addition leaves the note unchanged.
    public static func appendingNote(_ addition: String, to note: String) -> String {
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return note }
        let existing = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? addition : existing + "\n\n" + addition
    }

    /// Set a lifecycle state (`todo done|reopen|park|drop`). Parking or
    /// dropping ends a pending Ticket dispatch: the filing Manager (or the
    /// operator) decided there is no ticket, so the next Ticket press must
    /// open or re-seed a Manager instead of reading as "still filing" for
    /// the rest of ``ticketDispatchTTL`` (CROW-1416).
    public static func applyingState(_ state: TodoState, to item: TodoItem, now: Date = Date()) -> TodoItem {
        var next = item
        next.state = state
        if state == .parked || state == .dropped {
            next.ticketRequestedAt = nil
        }
        next.updatedAt = now
        return next
    }

    /// Attach `link` to `item` (`todo link`). A ticket, PR or custom URL that
    /// is already on the item is never added twice: re-linking it moves the
    /// existing link to the end instead. So the filing Manager can link every
    /// issue it filed without duplicate badges, and can repair an epic linked
    /// out of order by linking the epic again, since the last ticket link is
    /// the one `todo work` starts (``TodoItem/linkedTicketURL``). A ticket
    /// link moves the item through ``stateAfterTicketLink(_:)``: the first one
    /// moves a pre-ticket item to `ticketed`, and the rest of an epic's links
    /// leave it there (CROW-1416). Nothing changes, `updatedAt` included, when
    /// the link is already last and the state stays put.
    public static func linking(_ link: TodoLink, to item: TodoItem, now: Date = Date()) -> TodoItem {
        var next = item
        if link.type != .session, let url = link.url,
           let index = next.links.firstIndex(where: { $0.type == link.type && $0.url == url }) {
            next.links.append(next.links.remove(at: index))
        } else {
            next.links.append(link)
        }
        if link.type == .ticket {
            next.state = stateAfterTicketLink(next.state)
        }
        guard next.links != item.links || next.state != item.state else { return item }
        next.updatedAt = now
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

    /// How long a dispatched Ticket stays in-flight before another filing
    /// Manager may open. Within this window a second `todo-ticket` is a no-op
    /// so refresh or a double-click cannot file the item twice.
    public static let ticketDispatchTTL: TimeInterval = 15 * 60

    public static func isTicketDispatchPending(_ item: TodoItem, now: Date = Date()) -> Bool {
        guard item.linkedTicketURL == nil, let at = item.ticketRequestedAt else { return false }
        return now.timeIntervalSince(at) < ticketDispatchTTL
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

    /// Write a Manager brief to `path`. The file is the single source of
    /// truth for the seed (CROW-1327): a fresh Manager reads it as argv, an
    /// alive one is pointed at it. False when the write did not land.
    @discardableResult
    public static func writeBriefFile(_ brief: String, to path: String) -> Bool {
        guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try brief.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The one line typed into an already-running Manager instead of the
    /// multi-line brief (CROW-1327). A single short line survives an eaten or
    /// offset prefix far better than a 20-line paste, and the agent reads the
    /// full brief from disk. Newline-terminated so `TerminalRouter.send`
    /// submits it.
    public static func briefPointer(path: String) -> String {
        "Read and follow the instructions in \(path)\n"
    }

    /// How a Scratch brief reaches its Manager (CROW-1327). Nothing ever
    /// pastes the brief itself into a TUI.
    public enum BriefDelivery: Equatable, Sendable {
        /// Fresh Manager: the launch command already carries the file as argv.
        /// No follow-up paste — a second copy is how the brief got mangled.
        case launchArgv
        /// Alive (or still-starting) Manager: type only this pointer line.
        case pointer(String)
        /// The brief file could not be written; there is nothing to point at.
        case none
    }

    public static func briefDelivery(
        managerAlive: Bool, briefWritten: Bool, path: String
    ) -> BriefDelivery {
        guard briefWritten else { return .none }
        return managerAlive ? .pointer(briefPointer(path: path)) : .launchArgv
    }

    /// Temp file the extra-Manager handoff brief is read from. Distinct from
    /// ``explorePromptPath(sessionID:)`` so switching agents does not overwrite
    /// the original Scratch/explore seed (CROW-1314).
    public static func handoffPromptPath(sessionID: UUID) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-manager-handoff-\(sessionID.uuidString).md")
    }

    /// Wrap a Manager launch command so the explore brief is argv (job-style
    /// `evalPromptLaunch`), not a TUI paste. Cursor, Grok, and Claude need `--`
    /// before that positional: Cursor/Grok so a brief whose first character is
    /// `-` is not a flag, Claude so a variadic `--add-dir` cannot swallow it
    /// (CROW-1329).
    public static func seedLaunchCommand(
        baseCommand: String, promptPath: String, agentKind: AgentKind
    ) -> String {
        ShellLaunchArgs.evalPromptLaunch(
            prefix: baseCommand,
            promptPath: promptPath,
            endOfOptions: seedsExplorePromptWithEndOfOptions(agentKind)
        )
    }

    /// Whether the Scratch/handoff seed puts `--` before the brief.
    ///
    /// Opt-in per harness. `--` is a convention, and a parser that treats it
    /// as a literal prompt word would corrupt the launch (`ShellLaunchArgs`).
    ///
    /// Manager prefixes audited for a variadic flag left open in front of the
    /// positional brief (CROW-1329):
    /// - **Claude** — `managerCommand` appends `--add-dir <directories...>`,
    ///   which consumes every following positional. Verified on Claude Code
    ///   2.1.296: `--add-dir /tmp BRIEF` stats `BRIEF` as a directory;
    ///   `--add-dir /tmp -- BRIEF` and `--add-dir=/tmp BRIEF` do not. The
    ///   command emits the `=` form as well as `--`.
    /// - **Cursor** and **Grok** — already required `--` so a brief starting
    ///   with `-` is not a flag (CROW-968 / CROW-1144). Their manager flags
    ///   (`--trust`, `--force`, `--approve-mcps`, `--resume <id>`, `-c`) are
    ///   not variadic.
    /// - **Codex** ends in the boolean `--no-alt-screen`. **OpenCode**'s
    ///   `--session` takes one string and is only present with its id.
    ///   **Antigravity**'s manager suffix is empty. **Muse**'s manager flags
    ///   are booleans (`--disable-approval`, `--trust-workspace`). None leave
    ///   a variadic flag open, and `--` is still unverified for them.
    public static func seedsExplorePromptWithEndOfOptions(_ agentKind: AgentKind) -> Bool {
        agentKind == .claudeCode || agentKind == .cursor || agentKind == .grok
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

    /// The prompt seeded when Ticket opens a Manager (CROW-1289). Same
    /// delivery path as ``exploreBrief(for:)``. Since CROW-1416 the Manager
    /// runs `/crow-diagnose` on the item instead of filing one issue itself,
    /// so the item can become one ticket, an epic, or an outcome that isn't a
    /// ticket (`docs/ticket-standard.md`). Crow does not pick the repo or call
    /// `TaskBackend.createTask`.
    ///
    /// `--yes` is passed because pressing Ticket is the operator's go to file
    /// (not to publish private text: the brief says to redact quotes bound for
    /// a public repo). `workspace` (CROW-1387) becomes the skill's
    /// `--workspace`, so a live Manager tagged with another workspace still
    /// files where the item belongs, and ``ticketDestination(_:)`` steers a
    /// Jira or GitLab workspace away from `D file`, which files GitHub issues. `devRoot` names where the skill's relative paths resolve: an
    /// extra Manager runs in its own identity directory, not the root.
    ///
    /// The brief never relies on a slash command alone. Cursor, Codex and
    /// OpenCode receive the same text as their prompt, and are told to read
    /// the installed `SKILL.md` when `.claude/skills/` isn't loaded (ADR 0015).
    public static func ticketBrief(
        for item: TodoItem, workspace: WorkspaceInfo? = nil, devRoot: String? = nil
    ) -> String {
        let id = item.id.uuidString
        var invocation = "/crow-diagnose \(id) --yes"
        if let workspace {
            invocation += " --workspace \"\(workspace.name)\""
        }
        let skillPath = devRoot.map {
            ($0 as NSString).appendingPathComponent(diagnoseSkillRelativePath)
        } ?? diagnoseSkillRelativePath
        var lines = [
            "You are diagnosing a Crow Scratch item from this Manager session. The operator pressed Ticket, so turn it into the ticket or epic it should be, or into the outcome that says why it isn't one. Start now: run the `/crow-diagnose` skill on it.",
            "",
        ]
        if let devRoot {
            lines.append(contentsOf: [
                "Work from the development root, `\(devRoot)`. The skill's commands and paths are relative to it.",
                "",
            ])
        }
        lines.append(contentsOf: [
            invocation,
            "",
            "`--yes` is the operator's go: pressing Ticket asked for the filing, so do not stop to ask before filing, commenting or writing back. If this harness does not run `.claude/skills/` skills as slash commands, read `\(skillPath)` and follow it with the same arguments. The skill checks every draft against the ticket standard, `docs/ticket-standard.md` on `main`.",
            "",
            "`--yes` is the go to file, not to publish private text. A Scratch note is often pasted from a private thread: when a target repo's `visibility` is `public`, quote only what can be public and replace the rest with `[redacted]`, and say so, as the skill's Step 7 allows. The same holds for a comment on a duplicate in a public repo.",
        ])
        if let workspace {
            let destination = ticketDestination(workspace)
            if !destination.isEmpty {
                lines.append("")
                lines.append(contentsOf: destination)
            }
        }
        lines.append(contentsOf: [
            "",
            "When the skill reports its outcome, finish this item:",
            "",
            "- **ticket** (one ticket or an epic): link every issue you filed to this item, once each (`filed.json` lists what `D file` filed). Link an epic's sub-tickets first and the epic last: the last ticket link is the one `crow todo work` starts. The first link moves the item to `ticketed` and the others leave it there. Then check the order with `crow todo get --id \(id)`: if the epic is not the last ticket link, link it again. Re-linking a URL that is already on the item moves it to the end and never adds a second link.",
            "- **duplicate**: file nothing. Link the existing issue instead, then add the reason to the note.",
            "- **commitment** or **needs info**: park the item and add the reason to the note. For needs info, the reason is the question to ask the observer.",
            "- **won't do**: drop the item and add the reason to the note.",
            "",
            "The commands, with the placeholders replaced:",
            "",
            "crow todo link --id \(id) --type ticket --url <issue-url> --label \"<owner/repo#N>\"",
            "crow todo edit --id \(id) --append-note \"Diagnosed by /crow-diagnose: <outcome>. <reason>\"",
            "crow todo park --id \(id)",
            "crow todo drop --id \(id)",
            "",
            "Write the reason yourself, in one or two sentences. `--append-note` keeps the note the item already has. Never paste the item's text or any other source text into a shell command.",
            "Do not run `crow todo ticket` — a second call within 15 minutes does nothing, and after that it opens another Manager. Do not create a worktree or start a work session.",
            "",
            "## Scratch item",
            item.text,
        ])
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

    /// Where the scaffolder installs `/crow-diagnose`, relative to the
    /// development root (CROW-1415).
    public static let diagnoseSkillRelativePath = ".claude/skills/crow-diagnose/SKILL.md"

    /// Attaching a ticket link moves a pre-ticket item to `ticketed`.
    /// `working` and `done` stay put so a late link cannot walk them back.
    public static func stateAfterTicketLink(_ state: TodoState) -> TodoState {
        switch state {
        case .working, .done, .ticketed:
            return state
        case .captured, .exploring, .parked, .dropped:
            return .ticketed
        }
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

    /// Existing Manager (Talk / re-Explore): wait up to 8s for the TUI to
    /// own the pane. Fresh Managers take their brief as argv and never wait
    /// here (CROW-1327).
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
    /// has no hook pipeline) and when `.working` / `.waiting` already
    /// proved the line landed (CROW-1237).
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
