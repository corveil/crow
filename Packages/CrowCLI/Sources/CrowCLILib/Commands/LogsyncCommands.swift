import ArgumentParser
import CrowIPC
import Foundation

// `crow logsync` (CROW-1056): opt-in controls for the multi-harness session-log
// collector. Like `crow gateway` / `crow web-password`, these verbs are
// LOCAL-ONLY — the `logsync-get`/`logsync-set` RPCs are refused on the remote
// `/rpc` path (RPCWebSocketHandler.localOnlyDenial) because they configure
// transcript uploads off the daemon host and carry a Corveil API-key reference.
//
// `set` is a PATCH: only the flags you pass change; passing none is an error.
// Booleans are `@Option ... Bool?` (three states: true / false / absent).

/// Parent command: `crow logsync <subcommand>`.
public struct Logsync: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logsync",
        abstract: "View or change session-log upload (opt-in, local-only)",
        discussion: """
        The session-log collector uploads each opted-in workspace's coding-session \
        transcripts to Corveil as session artifacts, attributed to your own Corveil \
        API key (no AWS credentials are stored on this machine). It is OFF by \
        default and uploads nothing until you both enable it and opt a workspace in.

        Uploads are best-effort and never block or fail a session. Only Claude Code \
        transcripts are collected today; other harnesses are wired as their on-disk \
        log locations are confirmed.
        """,
        subcommands: [LogsyncGet.self, LogsyncSet.self]
    )

    public init() {}
}

public struct LogsyncGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show the session-log collector settings")

    @Flag(name: .long, help: "Reveal a plaintext API key (op:// references are always shown)")
    var reveal = false

    public init() {}

    public func run() throws {
        let params: [String: JSONValue] = reveal ? ["reveal": .bool(true)] : [:]
        printJSON(try rpc("logsync-get", params: params))
    }
}

public struct LogsyncSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change session-log upload settings",
        discussion: """
        Only the flags you pass change; at least one is required.

        Turn the feature on with --enabled true, point it at your Corveil API with \
        --base-url and --api-key-ref (an op://… 1Password reference is resolved at \
        upload so the key never lands in config.json), then opt workspaces in with \
        --add-workspace. Nothing uploads until a workspace is opted in.

        Live: the collector re-reads config each tick, so changes apply within a \
        few minutes with no restart. Pass an empty string to --base-url/--api-key-ref \
        to clear it.
        """
    )

    @Option(name: .long, help: "Enable session-log upload (true or false)")
    var enabled: Bool?

    @Option(name: .customLong("base-url"), help: "Corveil API base URL (e.g. https://api.corveil.io)")
    var baseURL: String?

    @Option(
        name: .customLong("api-key-ref"),
        help: "Corveil API key: an op://… reference (preferred) or a plaintext key")
    var apiKeyRef: String?

    @Option(
        name: .customLong("add-workspace"),
        help: "Opt a workspace in (repeatable)")
    var addWorkspace: [String] = []

    @Option(
        name: .customLong("remove-workspace"),
        help: "Opt a workspace out (repeatable)")
    var removeWorkspace: [String] = []

    @Flag(name: .customLong("clear-workspaces"), help: "Opt every workspace out")
    var clearWorkspaces = false

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
        let anySet = enabled != nil || baseURL != nil || apiKeyRef != nil
            || retentionDays != nil || quietPeriodMinutes != nil || maxUploadBytes != nil
            || !addWorkspace.isEmpty || !removeWorkspace.isEmpty || clearWorkspaces
        guard anySet else {
            throw ValidationError(
                "Nothing to set — provide at least one flag (e.g. --enabled, --base-url, "
                + "--api-key-ref, --add-workspace).")
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
        if let enabled { params["enabled"] = .bool(enabled) }
        if let baseURL { params["base_url"] = .string(baseURL) }
        if let apiKeyRef { params["api_key_ref"] = .string(apiKeyRef) }
        if let retentionDays { params["retention_days"] = .int(retentionDays) }
        if let quietPeriodMinutes { params["quiet_period_minutes"] = .int(quietPeriodMinutes) }
        if let maxUploadBytes { params["max_upload_bytes"] = .int(maxUploadBytes) }
        if !addWorkspace.isEmpty {
            params["add_workspaces"] = .array(addWorkspace.map { .string($0) })
        }
        if !removeWorkspace.isEmpty {
            params["remove_workspaces"] = .array(removeWorkspace.map { .string($0) })
        }
        if clearWorkspaces { params["clear_workspaces"] = .bool(true) }
        printJSON(try rpc("logsync-set", params: params))
    }
}
