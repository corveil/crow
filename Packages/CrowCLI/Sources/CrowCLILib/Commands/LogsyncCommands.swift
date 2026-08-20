import ArgumentParser
import CrowIPC
import Foundation

// `crow logsync` (CROW-1056; slimmed in CROW-1070): the session-log collector's
// global behavior knobs. The upload destination + credential are per-workspace
// now (they reuse the workspace's AI gateway), and the opt-in is the per-workspace
// `crow workspace edit --upload-session-logs` flag / Settings → Workspaces
// checkbox — so this block carries no credential and is no longer local-only.
//
// `set` is a PATCH: only the flags you pass change; passing none is an error.

/// Parent command: `crow logsync <subcommand>`.
public struct Logsync: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logsync",
        abstract: "View or change session-log upload behavior knobs",
        discussion: """
        The session-log collector uploads each opted-in workspace's coding-session \
        transcripts to Corveil as session artifacts, reusing that workspace's AI \
        gateway for the destination and credential (no AWS credentials are stored \
        on this machine). Opt a workspace in with \
        `crow workspace edit --workspace NAME --upload-session-logs true` (or the \
        Settings → Workspaces checkbox); it uploads once it also has a gateway.

        These verbs tune only global behavior — ledger retention, the quiet period \
        before a transcript is captured, and the per-upload size cap. Uploads are \
        best-effort and never block or fail a session. Only Claude Code transcripts \
        are collected today; other harnesses are wired as their on-disk log \
        locations are confirmed.
        """,
        subcommands: [LogsyncGet.self, LogsyncSet.self]
    )

    public init() {}
}

public struct LogsyncGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show the session-log collector behavior knobs")

    public init() {}

    public func run() throws {
        printJSON(try rpc("logsync-get", params: [:]))
    }
}

public struct LogsyncSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change session-log upload behavior knobs",
        discussion: """
        Only the flags you pass change; at least one is required.

        Opt a workspace in (and set its gateway) elsewhere — with \
        `crow workspace edit --upload-session-logs true` and `crow gateway set`. \
        These flags only tune collector behavior.

        Live: the collector re-reads config each tick, so changes apply within a \
        few minutes with no restart.
        """
    )

    @Option(
        name: .customLong("retention-days"),
        help: "Days to keep the local upload ledger (0 = forever, default 30)")
    var retentionDays: Int?

    @Option(
        name: .customLong("quiet-period-minutes"),
        help: "Wait this long after a session's last activity before uploading (default 30)")
    var quietPeriodMinutes: Int?

    @Option(
        name: .customLong("max-upload-bytes"),
        help: "Per-transcript upload cap in bytes (default 8000000)")
    var maxUploadBytes: Int?

    public init() {}

    public func validate() throws {
        let anySet = retentionDays != nil || quietPeriodMinutes != nil || maxUploadBytes != nil
        guard anySet else {
            throw ValidationError(
                "Nothing to set — provide at least one flag (--retention-days, "
                + "--quiet-period-minutes, --max-upload-bytes).")
        }
        if let retentionDays, retentionDays < 0 {
            throw ValidationError("--retention-days must be 0 or greater (0 = forever).")
        }
        if let quietPeriodMinutes, quietPeriodMinutes < 0 {
            throw ValidationError("--quiet-period-minutes must be 0 or greater.")
        }
        if let maxUploadBytes, maxUploadBytes < 1 {
            throw ValidationError("--max-upload-bytes must be at least 1.")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let retentionDays { params["retention_days"] = .int(retentionDays) }
        if let quietPeriodMinutes { params["quiet_period_minutes"] = .int(quietPeriodMinutes) }
        if let maxUploadBytes { params["max_upload_bytes"] = .int(maxUploadBytes) }
        printJSON(try rpc("logsync-set", params: params))
    }
}
