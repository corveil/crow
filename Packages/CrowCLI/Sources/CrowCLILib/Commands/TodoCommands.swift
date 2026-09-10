import ArgumentParser
import CrowIPC
import Foundation

/// Parent command for the durable pre-ticket Scratch list: `crow todo <subcommand>`.
///
/// Capture an idea in Crow, then promote it into a Manager / ticket / work
/// session. Mutations hit the daemon's injected `JSONStore` — the same store
/// sessions live in — and are exempt from the session retention reaper.
public struct Todo: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "todo",
        abstract: "Capture and promote pre-ticket ideas",
        subcommands: [
            TodoAdd.self,
            TodoList.self,
            TodoGet.self,
            TodoEdit.self,
            TodoDone.self,
            TodoReopen.self,
            TodoPark.self,
            TodoDrop.self,
            TodoDelete.self,
            TodoLink.self,
            TodoExplore.self,
            TodoTicket.self,
            TodoWork.self,
            TodoTalk.self,
        ]
    )

    public init() {}
}

public struct TodoAdd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Capture a pre-ticket idea"
    )

    @Argument(help: "Idea text")
    var text: String
    @Option(name: .long, help: "Comma-separated tags")
    var tag: String?
    @Option(name: .long, help: "Priority: p1, p2, p3, or p4")
    var priority: String?
    @Option(name: .long, help: "Longer note")
    var note: String?

    public init() {}

    public func validate() throws {
        try validateTodoText(text)
        if let priority { try validateTodoPriority(priority) }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["text": .string(text)]
        if let note { params["note"] = .string(note) }
        if let priority { params["priority"] = .string(priority) }
        let tags = splitTodoTags(tag)
        if !tags.isEmpty { params["tags"] = .array(tags.map { .string($0) }) }
        printJSON(try rpc("todo-add", params: params))
    }
}

public struct TodoList: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Scratch items"
    )

    @Option(name: .long, help: "Only items in this state")
    var state: String?
    @Option(name: .long, help: "Only items with this tag")
    var tag: String?

    public init() {}

    public func validate() throws {
        if let state { try validateTodoState(state) }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let state { params["state"] = .string(state) }
        if let tag { params["tag"] = .string(tag) }
        printJSON(try rpc("todo-list", params: params))
    }
}

public struct TodoGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show one Scratch item"
    )

    @Option(name: .long, help: "Todo UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
    }

    public func run() throws {
        printJSON(try rpc("todo-get", params: ["todo_id": .string(id)]))
    }
}

public struct TodoEdit: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Update fields on an existing Scratch item",
        discussion: """
        Only the provided flags change. --add-tag / --remove-tag compose; \
        they do not replace the whole list.
        """
    )

    @Option(name: .long, help: "Todo UUID") var id: String
    @Option(name: .long, help: "Replacement idea text") var text: String?
    @Option(name: .long, help: "Replacement note") var note: String?
    @Option(name: .long, help: "Priority: p1, p2, p3, or p4") var priority: String?
    @Option(name: .customLong("add-tag"), parsing: .singleValue, help: "Tag to add (repeatable)")
    var addTag: [String] = []
    @Option(name: .customLong("remove-tag"), parsing: .singleValue, help: "Tag to remove (repeatable)")
    var removeTag: [String] = []

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
        if let text { try validateTodoText(text) }
        if let priority { try validateTodoPriority(priority) }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["todo_id": .string(id)]
        if let text { params["text"] = .string(text) }
        if let note { params["note"] = .string(note) }
        if let priority { params["priority"] = .string(priority) }
        if !addTag.isEmpty { params["add_tags"] = .array(addTag.map { .string($0) }) }
        if !removeTag.isEmpty { params["remove_tags"] = .array(removeTag.map { .string($0) }) }
        printJSON(try rpc("todo-edit", params: params))
    }
}

public struct TodoDone: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark a Scratch item done")
    @Option(name: .long, help: "Todo UUID") var id: String
    public init() {}
    public func validate() throws { try validateUUID(id, label: "todo UUID") }
    public func run() throws {
        printJSON(try rpc("todo-done", params: ["todo_id": .string(id)]))
    }
}

public struct TodoReopen: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "reopen", abstract: "Reopen a done, parked, or dropped item")
    @Option(name: .long, help: "Todo UUID") var id: String
    public init() {}
    public func validate() throws { try validateUUID(id, label: "todo UUID") }
    public func run() throws {
        printJSON(try rpc("todo-reopen", params: ["todo_id": .string(id)]))
    }
}

public struct TodoPark: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "park", abstract: "Park a Scratch item for later")
    @Option(name: .long, help: "Todo UUID") var id: String
    public init() {}
    public func validate() throws { try validateUUID(id, label: "todo UUID") }
    public func run() throws {
        printJSON(try rpc("todo-park", params: ["todo_id": .string(id)]))
    }
}

public struct TodoDrop: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "drop", abstract: "Drop a Scratch item without filing a ticket")
    @Option(name: .long, help: "Todo UUID") var id: String
    public init() {}
    public func validate() throws { try validateUUID(id, label: "todo UUID") }
    public func run() throws {
        printJSON(try rpc("todo-drop", params: ["todo_id": .string(id)]))
    }
}

public struct TodoDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a Scratch item")
    @Option(name: .long, help: "Todo UUID") var id: String
    public init() {}
    public func validate() throws { try validateUUID(id, label: "todo UUID") }
    public func run() throws {
        printJSON(try rpc("todo-delete", params: ["todo_id": .string(id)]))
    }
}

public struct TodoLink: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Attach a session, ticket, PR, or custom URL to a Scratch item"
    )

    @Option(name: .long, help: "Todo UUID") var id: String
    @Option(name: .long, help: "Link type: session, ticket, pr, or custom") var type: String
    @Option(name: .long, help: "URL (required for ticket/pr/custom)") var url: String?
    @Option(name: .long, help: "Session UUID (for --type session)") var session: String?
    @Option(name: .long, help: "Badge label") var label: String?

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
        try validateTodoLinkType(type)
        if let session { try validateUUID(session, label: "session UUID") }
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "todo_id": .string(id),
            "type": .string(type),
        ]
        if let url { params["url"] = .string(url) }
        if let session { params["session_id"] = .string(session) }
        if let label { params["label"] = .string(label) }
        printJSON(try rpc("todo-link", params: params))
    }
}

public struct TodoExplore: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "explore",
        abstract: "Open a Manager and seed the item as an explore brief"
    )

    @Option(name: .long, help: "Todo UUID") var id: String
    @Option(name: .long, help: "Coding agent kind; default Manager agent when omitted")
    var agent: String?

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
        if let agent, agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--agent must not be blank (e.g. claude-code, cursor, codex).")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["todo_id": .string(id)]
        if let agent { params["agent_kind"] = .string(agent) }
        printJSON(try rpc("todo-explore", params: params, timeoutSeconds: 90))
    }
}

public struct TodoTicket: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ticket",
        abstract: "File a ticket from the item body and attach the URL"
    )

    @Option(name: .long, help: "Todo UUID") var id: String
    @Option(name: .long, help: "Workspace name or UUID") var workspace: String
    @Option(name: .long, help: "owner/repo slug (or Jira project key); defaults to the workspace's sole always-include repo")
    var repo: String?

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
        if let repo, repo.contains("/") { try validateRepoSlug(repo) }
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "todo_id": .string(id),
            "workspace": .string(workspace),
        ]
        if let repo { params["repo"] = .string(repo) }
        printJSON(try rpc("todo-ticket", params: params, timeoutSeconds: 60))
    }
}

public struct TodoWork: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "work",
        abstract: "Start a work session from the item's linked ticket"
    )

    @Option(name: .long, help: "Todo UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
    }

    public func run() throws {
        printJSON(try rpc("todo-work", params: ["todo_id": .string(id)], timeoutSeconds: 60))
    }
}

public struct TodoTalk: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "talk",
        abstract: "Send text to the item's linked Manager"
    )

    @Option(name: .long, help: "Todo UUID") var id: String
    @Argument(help: "Text to send (a trailing newline is added if missing)")
    var text: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "todo UUID")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("text must not be blank")
        }
    }

    public func run() throws {
        printJSON(try rpc("todo-talk", params: [
            "todo_id": .string(id),
            "text": .string(text),
        ]))
    }
}

func splitTodoTags(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

func validateTodoText(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("text must not be blank")
    }
}

func validateTodoPriority(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard ["p1", "p2", "p3", "p4"].contains(trimmed) else {
        throw ValidationError("priority must be one of: p1, p2, p3, p4")
    }
}

func validateTodoState(_ value: String) throws {
    let allowed = [
        "captured", "exploring", "ticketed", "working", "done", "parked", "dropped",
    ]
    guard allowed.contains(value) else {
        throw ValidationError("state must be one of: \(allowed.joined(separator: ", "))")
    }
}

func validateTodoLinkType(_ value: String) throws {
    let allowed = ["session", "ticket", "pr", "custom"]
    guard allowed.contains(value) else {
        throw ValidationError("type must be one of: \(allowed.joined(separator: ", "))")
    }
}
