import ArgumentParser
import CrowIPC
import Foundation

// Board & workflow verbs (CROW-817) — the CLI half of the actions the web
// Ticket Board / Reviews board expose as buttons. Every method already exists
// on the daemon's command router; these are the `ParsableCommand` wrappers, so
// a Manager agent or a shell script can drive the board without a browser.
//
// None of these are gated in `RPCWebSocketHandler.localOnlyDenial`, and they
// must not be: they are the web board's own RPCs, so gating them to loopback
// would break the board for a remote session.
//
// Every one of them hops onto the daemon's `MainActor` to read `appState`, so
// they queue behind whatever else holds it. On a loaded host that hop alone was
// measured past the 30s `SocketClient` default, which surfaced as a spurious
// "Socket read timed out" on a call the daemon then completed fine — hence the
// explicit 60s floor below, and longer where the handler does real work.
private let boardTimeout = 60

/// `crow work-on-issue` — types `/crow-workspace <url>` into the primary
/// Manager terminal and lets that agent do the worktree/session setup. Same
/// behavior as the board's "Start Working" button.
public struct WorkOnIssue: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "work-on-issue",
        abstract: "Start working on a ticket (types /crow-workspace into the Manager)"
    )

    @Option(name: .long, help: "Ticket / issue URL") var url: String

    public init() {}

    public func validate() throws {
        try validateIssueURL(url)
    }

    public func run() throws {
        let result = try rpc("work-on-issue", params: ["url": .string(url)],
                             timeoutSeconds: boardTimeout)
        printJSON(result)
    }
}

/// `crow batch-work-on-issues` — types ONE `/crow-batch-workspace <url…>` line
/// so the Manager runs the parallel batch skill once instead of N sequential
/// submissions. Same behavior as the board's "Start Working (N)" button.
public struct BatchWorkOnIssues: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "batch-work-on-issues",
        abstract: "Start working on several tickets in one batch",
        discussion: """
        URLs are sent in order: every --url first, then the lines of --urls-file. \
        Malformed URLs are not rejected locally — the daemon drops them into the \
        `rejected` array and starts the rest, so one bad ticket can't block the batch.
        """
    )

    @Option(name: .long, parsing: .singleValue, help: "Ticket / issue URL (repeatable)")
    var url: [String] = []
    @Option(name: .customLong("urls-file"),
            help: "Read newline-delimited URLs from a file; '-' reads stdin")
    var urlsFile: String?

    public init() {}

    public func validate() throws {
        guard !url.isEmpty || urlsFile != nil else {
            throw ValidationError("At least one --url or --urls-file is required.")
        }
        // With a file we can't check emptiness until run() reads it; inline-only
        // is checkable now, and blank values would otherwise reach the daemon as
        // rejected entries.
        if urlsFile == nil, try BoardArgs.urlList(url: url, urlsFile: nil).isEmpty {
            throw ValidationError("--url must not be blank.")
        }
    }

    public func run() throws {
        let urls = try BoardArgs.urlList(url: url, urlsFile: urlsFile)
        guard !urls.isEmpty else {
            throw ValidationError("No URLs to send — --urls-file was empty.")
        }
        let result = try rpc("batch-work-on-issues",
                             params: ["urls": .array(urls.map { .string($0) })],
                             timeoutSeconds: boardTimeout)
        printJSON(result)
    }
}

/// `crow start-review` — clones the PR, scaffolds the review skill and spawns a
/// review session. Same behavior as the Reviews board's "Start Review" button.
public struct StartReview: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start-review",
        abstract: "Start a review session for a pull request"
    )

    @Option(name: .long, help: "Pull request URL") var url: String

    public init() {}

    /// The URL with surrounding whitespace removed — what actually goes on the
    /// wire, matching how `BoardArgs.urlList` trims the batch verb's inputs.
    var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate() throws {
        // Only a non-empty check, deliberately: unlike work-on-issue this URL
        // goes to git clone / SessionService rather than terminal keystrokes,
        // so the daemon does not run `isSafeIssueURL` on it either.
        guard !trimmedURL.isEmpty else {
            throw ValidationError("--url must not be blank.")
        }
    }

    public func run() throws {
        // Cloning a repo can run well past the default 30s (cf. `crow job run`).
        let result = try rpc("start-review", params: ["url": .string(trimmedURL)],
                             timeoutSeconds: 120)
        printJSON(result)
    }
}

/// `crow create-manager` — spawns an additional Manager session, named with the
/// lowest unused "Manager N". Same behavior as the sidebar's `+` button.
public struct CreateManager: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create-manager",
        abstract: "Create an additional Manager session"
    )

    @Option(name: .long, help: "Coding agent kind (claude-code, cursor, codex, opencode); default agent when omitted")
    var agent: String?

    public init() {}

    public func validate() throws {
        // Non-empty only — `AgentKind` is an open RawRepresentable that
        // downstream packages extend, so a hardcoded allowlist would go stale
        // (same reasoning as `crow handoff-agent`).
        if let agent, agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--agent must not be blank (claude-code, cursor, codex, or opencode).")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let agent { params["agent_kind"] = .string(agent) }
        // Spawns a tmux window and launches the agent in it.
        let result = try rpc("create-manager", params: params, timeoutSeconds: boardTimeout)
        printJSON(result)
    }
}

/// `crow refresh-tickets` — re-polls the ticket provider now instead of waiting
/// for the next automatic poll. Same behavior as the board's refresh button.
public struct RefreshTickets: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "refresh-tickets",
        abstract: "Re-poll the ticket provider now"
    )

    public init() {}

    public func run() throws {
        // Shells out to gh/glab/Jira across every configured repo.
        let result = try rpc("refresh-tickets", timeoutSeconds: 120)
        printJSON(result)
    }
}

/// `crow quick-action` — pastes the deterministic prompt for a PR next-step
/// into the session's managed agent terminal. Same behavior as the PR badge
/// buttons on a session card.
public struct QuickActionCmd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "quick-action",
        abstract: "Dispatch a PR quick action into a session's agent terminal",
        discussion: """
        A skipped dispatch is reported as {"dispatched": false, "reason": "…"} with \
        a zero exit code — the RPC succeeded, the session just had no terminal to \
        send to (or no linked PR). Check `dispatched` rather than the exit code.
        """
    )

    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Action: \(validQuickActions.joined(separator: ", "))")
    var action: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateQuickAction(action)
    }

    public func run() throws {
        let result = try rpc("quick-action", params: [
            "session_id": .string(session),
            "action": .string(action),
        ], timeoutSeconds: boardTimeout)
        printJSON(result)
    }
}

/// `crow list-tickets` — the Ticket Board payload, verbatim.
public struct ListTickets: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-tickets",
        abstract: "List the ticket board (issues, per-status counts, loading state)"
    )

    public init() {}

    public func run() throws {
        let result = try rpc("list-tickets", timeoutSeconds: boardTimeout)
        printJSON(result)
    }
}

/// `crow list-reviews` — the Reviews board payload, verbatim.
public struct ListReviews: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-reviews",
        abstract: "List requested PR reviews (with unseen count and loading state)"
    )

    public init() {}

    public func run() throws {
        let result = try rpc("list-reviews", timeoutSeconds: boardTimeout)
        printJSON(result)
    }
}
