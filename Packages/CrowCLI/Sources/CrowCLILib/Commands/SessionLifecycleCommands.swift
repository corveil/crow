import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Session Lifecycle Commands (#816)

/// The session row/menu actions from the web UI, as `crow` verbs.
///
/// Each maps 1:1 onto the RPC method of the same name, so the CLI and the
/// browser drive a session through its lifecycle by exactly the same path.
/// Preconditions (linked ticket, linked PR, not a Manager) are enforced
/// server-side — the browser hides the menu items instead, which a CLI can't do.
///
/// `mark-in-review` / `complete-session` / `set-session-active` write session
/// status only. To move the *provider's* board (Jira workflow, GitHub Projects),
/// use `crow transition-ticket --to …`.

/// Move a session to In Review.
public struct MarkInReview: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mark-in-review",
        abstract: "Move a session to In Review",
        discussion: """
        Requires a linked ticket (attach one with `crow set-ticket --url …`). \
        Writes session status only — use `crow transition-ticket --to inReview` \
        to move the provider's board.
        """
    )

    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws { try validateUUID(session, label: "session UUID") }

    public func run() throws {
        printJSON(try rpc("mark-in-review", params: ["session_id": .string(session)]))
    }
}

/// Mark a session complete.
public struct CompleteSession: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "complete-session", abstract: "Mark a session completed")

    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws { try validateUUID(session, label: "session UUID") }

    public func run() throws {
        printJSON(try rpc("complete-session", params: ["session_id": .string(session)]))
    }
}

/// Reopen a session — the inverse of `complete-session`.
public struct SetSessionActive: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set-session-active", abstract: "Return a session to active")

    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws { try validateUUID(session, label: "session UUID") }

    public func run() throws {
        printJSON(try rpc("set-session-active", params: ["session_id": .string(session)]))
    }
}

/// Close the session's linked issue on the provider, then complete the session.
public struct MarkIssueDone: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mark-issue-done",
        abstract: "Close the session's linked issue and complete the session",
        discussion: """
        GitHub/GitLab close the issue; Jira and Corveil transition it to the \
        mapped done status. On success the session flips to completed. \
        Requires a linked ticket and a provider-configured daemon.
        """
    )

    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws { try validateUUID(session, label: "session UUID") }

    public func run() throws {
        // Round-trips to the provider (gh / glab / Jira), so allow past the
        // default 30s — same reasoning as `crow job run`.
        printJSON(try rpc(
            "mark-issue-done", params: ["session_id": .string(session)], timeoutSeconds: 60))
    }
}

/// Add the auto-merge label to the session's linked PR.
public struct AddMergeLabel: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add-merge-label",
        abstract: "Add the crow:merge label to the session's PR",
        discussion: """
        Requires a linked PR (attach one with `crow add-link --type pr --url …`) \
        and a provider whose backend supports auto-merge labels.
        """
    )

    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws { try validateUUID(session, label: "session UUID") }

    public func run() throws {
        printJSON(try rpc(
            "add-merge-label", params: ["session_id": .string(session)], timeoutSeconds: 60))
    }
}
