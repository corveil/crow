import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Metadata Commands

/// Set ticket metadata (URL, title, number) for a session.
///
/// At least one of `--url`, `--title`, or `--number` must be provided.
public struct SetTicket: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "set-ticket", abstract: "Set ticket metadata")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Ticket URL") var url: String?
    @Option(name: .long, help: "Ticket title") var title: String?
    @Option(name: .long, help: "Ticket number") var number: Int?

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateSetTicketHasField(url: url, title: title, number: number)
    }

    public func run() throws {
        var params: [String: JSONValue] = ["session_id": .string(session)]
        if let url { params["url"] = .string(url) }
        if let title { params["title"] = .string(title) }
        if let number { params["number"] = .int(number) }
        let result = try rpc("set-ticket", params: params)
        printJSON(result)
    }
}

/// Add a link to a session.
public struct AddLink: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "add-link", abstract: "Add a link to a session")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Link label") var label: String
    @Option(name: .long, help: "Link URL") var url: String
    @Option(name: .long, help: "Link type: ticket, pr, repo, custom") var type: String = "custom"

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateLinkType(type)
    }

    public func run() throws {
        let result = try rpc("add-link", params: [
            "session_id": .string(session),
            "label": .string(label),
            "url": .string(url),
            "type": .string(type),
        ])
        printJSON(result)
    }
}

/// Transition a session's linked ticket to a pipeline status (CROW-529).
///
/// For Jira this consults the workspace's `jiraStatusMap` and transitions via the
/// Jira Cloud REST API; for GitHub it moves the Projects-v2 status. `setup.sh`
/// calls this at session start (`--to inProgress`) so a Jira work item leaves
/// Backlog — the GitHub-only mutation in `setup.sh` had no Jira equivalent.
public struct TransitionTicket: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "transition-ticket", abstract: "Transition a session's ticket to a pipeline status")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Target status: inProgress, inReview, or done") var to: String

    public init() {}

    static let allowedStatuses = ["inProgress", "inReview", "done"]

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        let normalized = to.lowercased()
        guard Self.allowedStatuses.contains(where: { $0.lowercased() == normalized }) else {
            throw ValidationError("Invalid --to '\(to)' (expected one of: \(Self.allowedStatuses.joined(separator: ", ")))")
        }
    }

    public func run() throws {
        let result = try rpc("transition-ticket", params: [
            "session_id": .string(session),
            "to": .string(to),
        ])
        printJSON(result)
    }
}

/// Re-sync every Jira-backed session's ticket to the status implied by its Crow
/// session state (CROW-529) — one-shot remediation for tickets stuck in Backlog
/// because earlier sessions never transitioned them.
public struct ResyncJira: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "resync-jira", abstract: "Re-sync Jira ticket statuses from Crow session state")

    public init() {}

    public func run() throws {
        let result = try rpc("resync-jira")
        printJSON(result)
    }
}

/// List all links for a session.
public struct ListLinks: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list-links", abstract: "List links for a session")
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("list-links", params: ["session_id": .string(session)])
        printJSON(result)
    }
}

/// Remove a link from a session, identified by its link ID (from `list-links`)
/// or its URL. There is no way to re-derive links for a live session, so this is
/// the only way to detach a stale link (e.g. a closed PR) without deleting the
/// whole session.
public struct RemoveLink: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "remove-link", abstract: "Remove a link from a session")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Link ID (from list-links)") var id: String?
    @Option(name: .long, help: "Link URL (alternative to --id)") var url: String?

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        if let id { try validateUUID(id, label: "link ID") }
        guard id != nil || url != nil else {
            throw ValidationError("Provide --id or --url to identify the link to remove")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["session_id": .string(session)]
        if let id { params["link_id"] = .string(id) }
        if let url { params["url"] = .string(url) }
        let result = try rpc("remove-link", params: params)
        printJSON(result)
    }
}
