import ArgumentParser
import CrowIPC
import Foundation

// `crow backfill` (CROW-1075): the historical session backfill. Captures the
// coding-session transcripts already on disk — sessions that predate the live
// upload path or were reaped from Crow's store — and uploads them as real,
// fully-linked Corveil session artifacts, reconstructing the workspace / repo /
// ticket a live run would have carried.
//
// Claude Code, Codex, and Grok Build in v1 (CROW-1089, CROW-1098): Claude and
// Grok partition their logs by working directory (Grok URL-encodes the cwd into
// its ~/.grok/sessions directory name), and Codex records the real cwd in each
// ~/.codex/sessions rollout, so all three reconstruct reliably. The upload is
// idempotent (a local ledger + the server's write-once 409), throttled, and
// always user-initiated — never automatic or unbounded.

/// Parent command: `crow backfill <subcommand>`.
public struct Backfill: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "backfill",
        abstract: "Reconcile and upload historical on-disk session transcripts",
        discussion: """
        Scans the coding-session transcripts already on disk (Claude Code under \
        ~/.claude/projects, Codex under ~/.codex/sessions, and Grok Build under \
        ~/.grok/sessions), reconstructs each one's workspace, repo, and ticket/PR, \
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
        abstract: "List on-disk sessions with reconstructed metadata and upload status",
        discussion: """
        Disk- and git-only (no provider calls), so it's fast over hundreds of \
        sessions. Each row carries the recovered workspace/repo/ticket, a \
        confidence tier (high = repo + ticket, medium = repo only, low = orphan), \
        and its ledger upload status. Ticket links are validated at upload, not here.
        """
    )

    public init() {}

    public func run() throws {
        // A scan reads every transcript's head and resolves git remotes — allow
        // well past the 30s default on a large history.
        printJSON(try rpc("backfill-scan", params: [:], timeoutSeconds: 180))
    }
}

public struct BackfillUpload: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload selected historical sessions (idempotent)",
        discussion: """
        Choose sessions with repeated --session <uid> (UIDs come from \
        `crow backfill scan`), or bulk-select this workspace's history with \
        --all-high-confidence (repo + validated ticket) or --all. Exactly one \
        selection mode is required.

        --workspace names the workspace whose AI gateway supplies the upload \
        destination and credential; it must have a gateway configured. Uploads are \
        serial and idempotent, so a re-run only fills gaps.
        """
    )

    @Option(name: .customLong("workspace"), help: "Workspace whose gateway supplies the upload destination + credential")
    var workspace: String

    @Option(
        name: .customLong("session"),
        help: "A session UID to upload (repeatable; Claude or Codex — UIDs come from `crow backfill scan`). Mutually exclusive with --all/--all-high-confidence.")
    var sessions: [String] = []

    @Flag(name: .customLong("all-high-confidence"), help: "Upload every not-yet-uploaded high-confidence session in this workspace")
    var allHighConfidence = false

    @Flag(name: .customLong("all"), help: "Upload every not-yet-uploaded session in this workspace")
    var all = false

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
        // A large upload run is serial network I/O — give it real headroom.
        printJSON(try rpc("backfill-upload", params: params, timeoutSeconds: 600))
    }
}
