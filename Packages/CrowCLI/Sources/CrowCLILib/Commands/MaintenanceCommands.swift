import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Maintenance Commands
//
// CLI parity for the maintenance actions that were previously web-only:
// Settings → About's maintenance group (restart Manager / restart tmux server /
// reload tmux config) and the session-header host-app buttons (CROW-818).
// Each verb maps 1:1 to an existing daemon RPC method — same name, same params —
// so there is no second naming layer to keep in sync.
//
// All of these need tmux on the daemon host; without a `SessionService` the
// daemon answers with "… requires tmux on the daemon host".

/// Restart the Manager's agent process in place after it has exited.
public struct RestartManager: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restart-manager",
        abstract: "Relaunch the Manager's agent process in place",
        discussion: """
            Tears down the Manager's dead terminal surface and recreates a fresh one \
            (new terminal UUID) with the current remote-control / auto-permission args. \
            The Manager session row and its id are preserved.

            Only the primary Manager session is restarted — secondary Managers are \
            untouched.
            """
    )

    public init() {}

    public func run() throws {
        let result = try rpc("restart-manager")
        printJSON(result)
    }
}

/// Restart the shared tmux server, rebuilding every terminal surface.
public struct RestartTmuxServer: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restart-tmux-server",
        abstract: "Restart the tmux server, rebuilding every terminal (destructive)",
        discussion: """
            Kills the shared tmux server — every agent in every session dies — then \
            relaunches each persisted terminal (the Manager via its stored command, \
            work sessions via `claude --continue`).

            The web UI confirms first; from the CLI the caller owns that choice, the \
            same stance as `recreate-terminal`.

            Returns as soon as the teardown is done — the per-terminal rebuild \
            continues in the background, so don't chain a `crow send` straight after \
            this or you'll race a half-rebuilt surface.
            """
    )

    public init() {}

    public func run() throws {
        let result = try rpc("restart-tmux-server")
        printJSON(result)
    }
}

/// Reload the bundled tmux config into the live server without restarting it.
public struct ReloadTmuxConfig: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reload-tmux-config",
        abstract: "Reload the bundled tmux config into the running server",
        discussion: """
            Runs `tmux source-file` against the bundled crow-tmux.conf. Non-destructive: \
            windows, sessions, and running agents are unaffected. Errors if the tmux \
            server isn't running or the bundled config is missing.
            """
    )

    public init() {}

    public func run() throws {
        let result = try rpc("reload-tmux-config")
        printJSON(result)
    }
}

/// (Re)launch the coding agent in a terminal whose shell is ready.
public struct LaunchAgent: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "launch-agent",
        abstract: "Launch the session's coding agent in a ready terminal",
        discussion: """
            Takes only `--terminal` — the terminal id alone identifies the surface, so \
            unlike `new-terminal` / `send` there is no `--session` flag.

            The daemon applies this only to a terminal that is shell-ready and still \
            pending auto-launch; in any other state it is a no-op. `{"ok": true}` means \
            the request was accepted, not that an agent was started.
            """
    )
    @Option(name: .long, help: "Terminal UUID") var terminal: String

    public init() {}

    public func validate() throws {
        try validateUUID(terminal, label: "terminal UUID")
    }

    public func run() throws {
        let result = try rpc("launch-agent", params: ["terminal_id": .string(terminal)])
        printJSON(result)
    }
}

/// Re-arm the tmux readiness watch for a terminal whose first attempt timed out.
public struct RetryReadiness: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "retry-readiness",
        abstract: "Re-arm the readiness watch for a stuck terminal",
        discussion: """
            Starts a longer-budget readiness watch on a terminal whose first attempt \
            timed out, clearing the Retry overlay in the UI.

            Takes only `--terminal` — no `--session` flag.

            The daemon applies this only to a terminal that timed out or never reached \
            shell-ready; in any other state it is a no-op. `{"ok": true}` means the \
            request was accepted, not that a watch was re-armed.
            """
    )
    @Option(name: .long, help: "Terminal UUID") var terminal: String

    public init() {}

    public func validate() throws {
        try validateUUID(terminal, label: "terminal UUID")
    }

    public func run() throws {
        let result = try rpc("retry-readiness", params: ["terminal_id": .string(terminal)])
        printJSON(result)
    }
}

/// Open a session's primary worktree in VS Code on the daemon host.
public struct OpenInVSCode: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "open-in-vscode",
        abstract: "Open the session's worktree in VS Code on the host",
        discussion: """
            Launches the `code` CLI at the session's primary worktree. Requires that \
            CLI on PATH (or in a standard VS Code install location) and a worktree \
            attached to the session.

            Host-app launches are restricted to local callers; the CLI qualifies, since \
            it talks to the daemon over its Unix socket.
            """
    )
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("open-in-vscode", params: ["session_id": .string(session)])
        printJSON(result)
    }
}

/// Open a host Terminal.app window at a session's primary worktree.
public struct OpenTerminal: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "open-terminal",
        abstract: "Open a macOS Terminal.app window at the session's worktree (host GUI)",
        discussion: """
            This is NOT a Crow terminal tab — it opens Terminal.app on the daemon host, \
            cd'd to the session's primary worktree. Use `new-terminal` to create a tab \
            inside Crow.

            macOS only. Host-app launches are restricted to local callers; the CLI \
            qualifies, since it talks to the daemon over its Unix socket.
            """
    )
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("open-terminal", params: ["session_id": .string(session)])
        printJSON(result)
    }
}
