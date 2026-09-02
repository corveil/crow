import ArgumentParser
import CrowIPC
import Foundation

// Read-only inspection and analytics surfaces that were web-only until #819:
// the efficiency scorecard, the daemon's render-state snapshot, and per-session
// generated images. All local; none of them mutate anything except
// rebuild-scorecard, which is idempotent.

public struct GetScorecard: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get-scorecard",
        abstract: "Print the efficiency scorecard as JSON",
        discussion: """
        Grade, weekly rollups, baseline medians, and per-session rows. Grading \
        runs daemon-side so the CLI, web, and desktop can never drift. With \
        telemetry off the result is an empty shell — check telemetryEnabled and \
        snapshotCount. All timestamps are epoch milliseconds.
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("get-scorecard"))
    }
}

public struct RebuildScorecard: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rebuild-scorecard",
        abstract: "Backfill analytics snapshots and recompute the scorecard",
        discussion: """
        Idempotent, and overlapping callers coalesce into one rebuild. Errors \
        when telemetry is disabled — there is no database to rebuild from.
        """
    )

    public init() {}

    public func run() throws {
        // Backfills snapshots out of telemetry.db — well past the 30s default.
        printJSON(try rpc("rebuild-scorecard", timeoutSeconds: 180))
    }
}

public struct GetState: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get-state",
        abstract: "Print the daemon's full render-state snapshot as JSON",
        discussion: """
        Sessions, terminals, worktrees, links, PR status, review requests, \
        assigned issues, and config (credentials stripped). \
        This is the whole snapshot in one call and it is large — prefer \
        list-sessions / get-session / list-links when you want one slice.
        """
    )

    public init() {}

    public func run() throws {
        do {
            printJSON(try rpc("get-state", timeoutSeconds: 60))
        } catch SocketError.responseTooLarge {
            // The snapshot carries every assigned issue's full body, so a busy
            // install can exceed the 1 MB socket frame. Name the alternatives
            // rather than surfacing the bare "Response exceeded maximum size".
            throw ValidationError("""
            The state snapshot exceeded the 1 MB socket message limit. Use a \
            narrower read instead: crow list-sessions, crow get-session \
            --session <uuid>, crow list-links, or crow list-terminals.
            """)
        }
    }
}

public struct ListArtifacts: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-artifacts",
        abstract: "List images an agent dropped in a session's artifacts directory",
        discussion: """
        Each image reports an absolute on-disk path plus a url that only \
        resolves against the daemon's own web server. The directory is the one \
        agents see as $CROW_ARTIFACTS_DIR; it lives under $TMPDIR and does not \
        survive a reboot.
        """
    )

    @Option(name: .long, help: "Session UUID")
    var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        printJSON(try rpc("list-artifacts", params: ["session_id": .string(session)]))
    }
}
