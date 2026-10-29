import ArgumentParser
import CrowIPC
import Foundation

// `crow backfill` (CROW-1075): the historical session backfill. Captures the
// coding-session transcripts already on disk — sessions that predate the live
// upload path or were reaped from Crow's store — and uploads them as real,
// fully-linked Corveil session artifacts, reconstructing the workspace / repo /
// ticket a live run would have carried.
//
// Claude Code, Codex, Grok Build, Cursor, OpenCode, and Muse Code in v1 (CROW-1089 /
// CROW-1098 / CROW-1095 / CROW-1096 / CROW-1106): Claude and Grok partition their logs
// by working directory (Grok URL-encodes the cwd into its ~/.grok/sessions directory
// name), Codex records the real cwd in each ~/.codex/sessions rollout, Cursor records
// it in the sibling meta.json of each ~/.cursor/chats store, OpenCode records the
// directory on each session row of ~/.local/share/opencode/opencode.db, and Muse
// records it on each ~/.local/share/muse/sessions journal's line-1
// runtime.session.metadata record, so all reconstruct reliably. The upload is
// idempotent (a local ledger + the server's write-once 409), throttled, and
// always user-initiated — never automatic or unbounded.

/// Parent command: `crow backfill <subcommand>`.
public struct Backfill: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "backfill",
        abstract: "Reconcile and upload historical on-disk session transcripts",
        discussion: """
        Scans the coding-session transcripts already on disk (Claude Code under \
        ~/.claude/projects, Codex under ~/.codex/sessions, Grok Build under \
        ~/.grok/sessions, Cursor under ~/.cursor/chats, OpenCode in \
        ~/.local/share/opencode/opencode.db, and Muse Code under \
        ~/.local/share/muse/sessions), reconstructs each \
        one's workspace, repo, and ticket/PR, \
        and uploads the ones you choose to Corveil as session artifacts — so a \
        backfilled session lands in the ontology indistinguishable from a \
        live-captured one.

        A reconstructed ticket becomes a link only when the provider confirms it \
        exists; otherwise the session uploads repo-only, and a true orphan uploads \
        attributed but unlinked. Uploads reuse the named workspace's AI gateway for \
        the destination and credential (no AWS credentials on this machine) and are \
        idempotent — re-running never duplicates.
        """,
        subcommands: [BackfillScan.self, BackfillUpload.self]
    )

    public init() {}
}

public struct BackfillScan: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Summarize on-disk sessions, or list them a page at a time",
        discussion: """
        Disk- and git-only (no provider calls). Reconstructs each transcript's \
        workspace/repo/ticket, a confidence tier (high = repo + ticket, medium = \
        repo only, low = orphan), and its ledger upload status. Ticket links are \
        validated at upload, not here.

        By default it prints counts only — totals plus a breakdown by harness, \
        workspace, confidence and upload status — because a large history does \
        not fit in one reply. Pass --sessions to list rows, a page at a time \
        (--limit, --offset); a page may hold fewer than --limit rows when the \
        rows are large, so follow next_offset, not offset + limit. A note on \
        stderr says when output was summarized or paged.

        Every reply names a scan_id. The daemon keeps that scan for reuse (about \
        15 minutes for an unpinned call); pass --scan-id with each later page so \
        the walk reads one snapshot and returns every session exactly once. \
        --refresh takes a new scan; so does an upload, which retires the snapshot.

        Filters (--workspace, --confidence, --status, --harness) narrow both the \
        breakdown and the rows; the summary block always covers the whole scan.
        """
    )

    @Flag(name: .customLong("sessions"), help: "List session rows (paged) instead of the summary")
    var listSessions = false

    @Option(name: .customLong("limit"), help: "Rows per page with --sessions (default 200, max 1000)")
    var limit: Int?

    @Option(name: .customLong("offset"), help: "Row to start the page at with --sessions (use the previous page's next_offset)")
    var offset: Int?

    @Option(name: .customLong("scan-id"), help: "Page through the snapshot a previous call returned, instead of the latest scan")
    var scanID: String?

    @Option(name: .customLong("workspace"), help: "Only rows reconstructed to this workspace (case-insensitive)")
    var workspace: String?

    @Option(name: .customLong("confidence"), help: "Only rows of this confidence: high, medium, or low")
    var confidence: String?

    @Option(name: .customLong("status"), help: "Only rows with this upload status: new, uploaded, skipped, failed, or not-uploaded")
    var status: String?

    @Option(name: .customLong("harness"), help: "Only rows from this harness (claude, codex, cursor, opencode, grok, antigravity, muse)")
    var harness: String?

    @Flag(name: .customLong("refresh"), help: "Re-scan the disk instead of reusing the daemon's recent scan")
    var refresh = false

    static let confidences = ["high", "medium", "low"]
    static let statuses = ["new", "uploaded", "skipped", "failed", "not-uploaded"]

    public init() {}

    public func validate() throws {
        if let limit, limit < 1 { throw ValidationError("--limit must be at least 1.") }
        if let offset, offset < 0 { throw ValidationError("--offset must not be negative.") }
        if let confidence, !Self.confidences.contains(confidence.lowercased()) {
            throw ValidationError("--confidence must be one of: \(Self.confidences.joined(separator: ", ")).")
        }
        if let status, !Self.statuses.contains(status.lowercased().replacingOccurrences(of: "_", with: "-")) {
            throw ValidationError("--status must be one of: \(Self.statuses.joined(separator: ", ")).")
        }
        if !listSessions, limit != nil || offset != nil {
            throw ValidationError("--limit and --offset page the rows; add --sessions.")
        }
        if scanID != nil, refresh {
            throw ValidationError("--scan-id reads an existing snapshot; it can't be combined with --refresh.")
        }
    }

    var params: [String: JSONValue] {
        var p: [String: JSONValue] = ["view": .string(listSessions ? "sessions" : "summary")]
        if let limit { p["limit"] = .int(limit) }
        if let offset { p["offset"] = .int(offset) }
        if let scanID { p["scan_id"] = .string(scanID) }
        if let workspace { p["workspace"] = .string(workspace) }
        if let confidence { p["confidence"] = .string(confidence.lowercased()) }
        if let status { p["status"] = .string(status.lowercased()) }
        if let harness { p["harness"] = .string(harness.lowercased()) }
        if refresh { p["refresh"] = .bool(true) }
        return p
    }

    public func run() throws {
        let result: [String: JSONValue]
        do {
            // A scan reads every transcript's head and resolves git remotes — allow
            // well past the 30s default on a large history.
            result = try rpc("backfill-scan", params: params, timeoutSeconds: 180)
        } catch SocketError.responseTooLarge {
            // Pages are cut to a byte budget daemon-side, so this means a daemon
            // that predates paging (CROW-1378).
            throw ValidationError("""
            The scan reply exceeded the 1 MB socket message limit. Narrow it with \
            --workspace / --confidence / --status / --harness or a smaller --limit, \
            or update crowd — older daemons return every row at once.
            """)
        }
        printJSON(result)
        // stderr, so stdout stays one parseable JSON object.
        if let note = Self.note(for: result, filterArgs: filterArgs) {
            FileHandle.standardError.write(Data("crow: \(note)\n".utf8))
        }
    }

    /// The filter flags, as typed, so the "next page" hint can be pasted back.
    private var filterArgs: [String] {
        var args: [String] = []
        if let workspace { args += ["--workspace", workspace] }
        if let confidence { args += ["--confidence", confidence] }
        if let status { args += ["--status", status] }
        if let harness { args += ["--harness", harness] }
        if let limit { args += ["--limit", String(limit)] }
        return args
    }

    /// Says on stderr whether the output was summarized or paged (CROW-1378),
    /// and how to get the next page.
    static func note(for result: [String: JSONValue], filterArgs: [String]) -> String? {
        let total = result["total_matching"]?.intValue ?? 0
        guard result["paged"] == .bool(true) else {
            if result["sessions"] != nil { return nil }  // an older daemon's full list
            return "summary only (\(total) matching session\(total == 1 ? "" : "s")) — pass --sessions to list rows."
        }
        let offset = result["offset"]?.intValue ?? 0
        let returned = result["returned"]?.intValue ?? 0
        let shown = returned == 0 ? "no rows" : "rows \(offset + 1)–\(offset + returned)"
        guard let next = result["next_offset"]?.intValue, let scanID = result["scan_id"]?.stringValue else {
            return "showing \(shown) of \(total) (last page)."
        }
        let command = (["crow", "backfill", "scan", "--sessions", "--scan-id", scanID, "--offset", String(next)]
            + filterArgs).map(shellQuote).joined(separator: " ")
        return "showing \(shown) of \(total); next page: \(command)"
    }

    private static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_./=".contains($0) } ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct BackfillUpload: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload selected historical sessions (idempotent)",
        discussion: """
        Choose sessions with repeated --session <uid> (UIDs come from \
        `crow backfill scan --sessions`), or bulk-select this workspace's history with \
        --all-high-confidence (repo + validated ticket) or --all. Exactly one \
        selection mode is required.

        --workspace names the workspace whose AI gateway supplies the upload \
        destination and credential; it must have a gateway configured. Uploads are \
        serial and idempotent, so a re-run only fills gaps. Bulk selection runs \
        inside the daemon over its own scan, so it works however large the \
        history is; a run uploads at most 1000 sessions, and re-running picks up \
        the rest.

        Two kinds of row are refused (reported as skipped, with a reason) unless \
        you opt in, because neither belongs to the workspace whose gateway would \
        carry it: orphans (low confidence — no repo could be attributed; \
        --allow-orphans) and Manager transcripts (workspace `.crow`; \
        --allow-manager-transcripts). A Manager tagged with a workspace ships its \
        own transcripts through that workspace's gateway as it runs.
        """
    )

    @Option(name: .customLong("workspace"), help: "Workspace whose gateway supplies the upload destination + credential")
    var workspace: String

    @Option(
        name: .customLong("session"),
        help: "A session UID to upload (repeatable; Claude Code, Codex, Grok Build, Cursor, OpenCode, or Muse Code — UIDs come from `crow backfill scan --sessions`). Mutually exclusive with --all/--all-high-confidence.")
    var sessions: [String] = []

    @Flag(name: .customLong("all-high-confidence"), help: "Upload every not-yet-uploaded high-confidence session in this workspace")
    var allHighConfidence = false

    @Flag(name: .customLong("all"), help: "Upload every not-yet-uploaded session in this workspace")
    var all = false

    @Flag(name: .customLong("allow-orphans"), help: "Also upload selected rows no repo could be attributed to (confidence low)")
    var allowOrphans = false

    @Flag(name: .customLong("allow-manager-transcripts"), help: "Also upload selected Manager transcripts (workspace .crow) under this workspace's gateway")
    var allowManagerTranscripts = false

    public init() {}

    public func validate() throws {
        if workspace.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--workspace is required — its gateway supplies the upload destination and credential.")
        }
        let modes = [!sessions.isEmpty, allHighConfidence, all].filter { $0 }.count
        guard modes == 1 else {
            throw ValidationError(
                "Choose exactly one selection: one or more --session <uid>, "
                + "or --all-high-confidence, or --all.")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["workspace": .string(workspace)]
        if !sessions.isEmpty {
            params["sessions"] = .array(sessions.map { .string($0) })
        } else if allHighConfidence {
            params["select"] = .string("high")
        } else if all {
            params["select"] = .string("all")
        }
        if allowOrphans { params["allow_orphans"] = .bool(true) }
        if allowManagerTranscripts { params["allow_manager_transcripts"] = .bool(true) }
        // A large upload run is serial network I/O — give it real headroom.
        printJSON(try rpc("backfill-upload", params: params, timeoutSeconds: 600))
    }
}
