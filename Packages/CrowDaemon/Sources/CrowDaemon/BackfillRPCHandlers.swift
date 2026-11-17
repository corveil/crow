import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// The `backfill-*` verb group — the historical session backfill (CROW-1075).
///
/// Own file (CROW-1134) so `makeCommandRouter` stays a thin assembler.
/// `scripts/check-cli-parity.sh` globs every `*RPCHandlers.swift` file.
///
/// - `backfill-scan` (read): reconcile the on-disk Claude transcripts against
///   the upload ledger and return the reconstructed rows + a summary. Disk- and
///   git-only; no provider calls, so it stays fast over hundreds of sessions.
///   With `output_path`, the rows go to that file instead and the reply carries
///   only the summary (CROW-1462) — see `backfillScanReply`.
/// - `backfill-upload` (write): upload a user-selected set through the live path,
///   idempotently, using the named workspace's gateway for destination +
///   credential (the same security invariant as the live collector — the
///   destination is never a browser-writable field). Serial and capped; never an
///   automatic or unbounded flood.
///
/// Not local-only: like `logsync`, no credential travels in the params (the key
/// is resolved server-side from the local-only gateway), so it backs a web
/// Settings panel.
func makeBackfillHandlers(devRoot: String) -> [String: CommandRouter.Handler] {
    [
        "backfill-scan": { params in
            try await mapRPCError {
                // Validate before the scan, which can take minutes on a large history.
                let outputPath = try backfillScanOutputPath(params)
                let sessions = await BackfillService(devRoot: devRoot).scan()
                return try backfillScanReply(sessions, outputPath: outputPath)
            }
        },
        "backfill-upload": { params in
            try await mapRPCError {
                guard let workspaceName = params["workspace"]?.stringValue,
                      !workspaceName.isEmpty else {
                    throw RPCError.invalidParams(
                        "workspace is required — its gateway supplies the upload destination and credential.")
                }
                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                guard let workspace = config.workspaces.first(where: {
                    $0.name.lowercased() == workspaceName.lowercased()
                }) else {
                    throw RPCError.invalidParams("No workspace named \"\(workspaceName)\".")
                }
                guard let upload = LogSyncCollector.resolvedUpload(
                    for: workspace, resolveSecret: { GatewayResolver.opRead($0) }) else {
                    throw RPCError.invalidParams(
                        "Workspace \"\(workspaceName)\" has no reusable Corveil gateway "
                        + "(needs a base URL and an x-citadel-api-key).")
                }
                let logSync = config.logSync ?? LogSyncConfig()
                let service = BackfillService(devRoot: devRoot)

                // Selection: an explicit UID list (what the Settings table sends),
                // or a `select` selector over a fresh scan scoped to this
                // workspace (the "import all high-confidence" convenience).
                let explicit = (params["sessions"]?.arrayValue ?? []).compactMap(\.stringValue)
                var toUpload: [BackfillSession] = []
                if !explicit.isEmpty {
                    let scanned = await service.scan()
                    // Select every scanned row whose UID was requested — a set
                    // membership test, not a uid→session map. A UID shared across
                    // harnesses (a Claude and a Codex session) therefore uploads
                    // BOTH rows instead of silently dropping one; each lands in its
                    // own harness-scoped ledger slot (CROW-1089). Cross-harness UID
                    // collisions are vanishingly rare, but keeping both reachable
                    // costs nothing and matches `--all`/`--all-high-confidence`.
                    let wanted = Set(explicit)
                    toUpload = scanned.filter { wanted.contains($0.claudeSessionUID) }
                } else if let selectMode = params["select"]?.stringValue {
                    let scanned = await service.scan()
                    let scope = scanned.filter { $0.workspace?.lowercased() == workspaceName.lowercased() }
                    switch selectMode {
                    case "high": toUpload = scope.filter { $0.confidence == .high && $0.uploadStatus != .uploaded }
                    case "all": toUpload = scope.filter { $0.uploadStatus != .uploaded }
                    default: throw RPCError.invalidParams("select must be \"high\" or \"all\".")
                    }
                } else {
                    throw RPCError.invalidParams(
                        "Provide sessions (a list of UIDs) or select (\"high\" | \"all\").")
                }

                // Manager transcripts and orphans are refused unless the caller
                // opts in (CROW-1382): the gateway is the named workspace's, and
                // neither kind of row belongs to it. Refused rows stay in the
                // results as `skipped` with a reason, so nothing vanishes silently.
                let allowOrphans = try SettingsRPC.patchBool(params, "allow_orphans") ?? false
                let allowManager = try SettingsRPC.patchBool(params, "allow_manager_transcripts") ?? false
                var results: [BackfillUploadOutcome] = []
                toUpload = toUpload.filter { session in
                    guard let reason = BackfillUploadGuard.refusalReason(
                        for: session, allowOrphans: allowOrphans,
                        allowManagerTranscripts: allowManager) else { return true }
                    results.append(BackfillUploadOutcome(
                        claudeSessionUID: session.claudeSessionUID, result: .skipped,
                        harness: session.harness, reason: reason))
                    return false
                }

                // Cap the batch — the user always chooses, never an unbounded
                // flood (acceptance). A larger selection uploads in chunks.
                let cap = 1000
                if toUpload.count > cap { toUpload = Array(toUpload.prefix(cap)) }

                results.reserveCapacity(results.count + toUpload.count)
                for session in toUpload {
                    let outcome = await service.upload(
                        session: session, upload: upload,
                        maxUploadBytes: max(1, logSync.maxUploadBytes))
                    results.append(outcome)
                }
                return [
                    "results": .array(results.map { backfillOutcomeJSON($0) }),
                    "summary": backfillResultSummaryJSON(results),
                ]
            }
        },
    ]
}

// MARK: - backfill-scan rows file (CROW-1462)

/// The scan's `output_path` param: `nil` when absent, else an absolute path
/// whose directory exists and is writable. Checked up front so a bad path fails
/// in milliseconds rather than after the scan.
///
/// `/rpc` refuses this param from a remote peer
/// (`RPCWebSocketHandler.localOnlyDenial`): it makes the daemon write a file.
func backfillScanOutputPath(_ params: [String: JSONValue]) throws -> String? {
    guard let raw = params["output_path"] else { return nil }
    guard let path = raw.stringValue, !path.isEmpty else {
        throw RPCError.invalidParams("output_path must be a non-empty string.")
    }
    guard path.hasPrefix("/") else {
        throw RPCError.invalidParams("output_path must be absolute: \(path)")
    }
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        throw RPCError.invalidParams("output_path is a directory: \(path)")
    }
    let parent = (path as NSString).deletingLastPathComponent
    guard FileManager.default.isWritableFile(atPath: parent) else {
        throw RPCError.invalidParams("Cannot write output_path \(path): \(parent) is missing or not writable.")
    }
    return path
}

/// The `backfill-scan` reply. Without `outputPath` it is every row plus the
/// summary, as it always was — the Settings dialog reads that over `/rpc`,
/// where replies aren't capped. With `outputPath` the same JSON goes to that
/// file (mode 0600) and the reply carries only the summary, the path and the
/// row count, so it stays far under the Unix socket's 1 MiB reply cap no matter
/// how much history there is (#1378).
func backfillScanReply(_ sessions: [BackfillSession], outputPath: String?) throws -> [String: JSONValue] {
    let summary = backfillSummaryJSON(BackfillSummary(sessions: sessions))
    let full: [String: JSONValue] = [
        "sessions": .array(sessions.map { backfillSessionJSON($0) }),
        "summary": summary,
    ]
    guard let outputPath else { return full }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try writePrivateFile(try encoder.encode(full), to: outputPath)
    return [
        "summary": summary,
        "rows_file": .string(outputPath),
        "row_count": .int(sessions.count),
    ]
}

/// Write `data` to `path` with mode 0600 from the first byte: the file is
/// created 0600, and an existing file is truncated and re-moded, so the rows
/// (paths, branches, repos) are never briefly readable by other users.
private func writePrivateFile(_ data: Data, to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else {
        throw RPCError.applicationError(
            "Cannot write output_path \(path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    guard fchmod(fd, 0o600) == 0 else {
        throw RPCError.applicationError(
            "Cannot set mode 0600 on output_path \(path): \(String(cString: strerror(errno)))")
    }
    try handle.write(contentsOf: data)
}

/// Serialize one reconstructed session for the Settings table (snake_case keys,
/// matching the other RPC payloads).
private func backfillSessionJSON(_ s: BackfillSession) -> JSONValue {
    var obj: [String: JSONValue] = [
        "uid": .string(s.claudeSessionUID),
        "harness": .string(s.harness.rawValue),
        "file_path": .string(s.filePath),
        "slug": .string(s.slug),
        "modified_at": .double(s.modifiedAt),
        "size_bytes": .int(s.sizeBytes),
        "confidence": .string(s.confidence.rawValue),
        "upload_status": .string(s.uploadStatus.rawValue),
        "ticket_kind": .string(s.ticketKind.rawValue),
        "worktree_exists": .bool(s.worktreeExists),
    ]
    func put(_ key: String, _ value: String?) { if let value { obj[key] = .string(value) } }
    put("cwd", s.cwd)
    put("git_branch", s.gitBranch)
    put("workspace", s.workspace)
    put("worktree_name", s.worktreeName)
    put("repo_name", s.repoName)
    put("owner_repo", s.ownerRepo)
    put("host", s.host)
    if let n = s.ticketNumber { obj["ticket_number"] = .int(n) }
    return .object(obj)
}

private func backfillSummaryJSON(_ s: BackfillSummary) -> JSONValue {
    .object([
        "total": .int(s.total),
        "uploaded": .int(s.uploaded),
        "linkable": .int(s.linkable),
        "repo_only": .int(s.repoOnly),
        "orphan": .int(s.orphan),
    ])
}

private func backfillOutcomeJSON(_ o: BackfillUploadOutcome) -> JSONValue {
    var obj: [String: JSONValue] = [
        "uid": .string(o.claudeSessionUID),
        "harness": .string(o.harness.rawValue),
        "result": .string(o.result.rawValue),
        "linked": .bool(o.linked),
    ]
    if let r = o.ownerRepo { obj["owner_repo"] = .string(r) }
    if let n = o.ticketNumber { obj["ticket_number"] = .int(n) }
    if let k = o.ticketKind { obj["ticket_kind"] = .string(k.rawValue) }
    if let reason = o.reason { obj["reason"] = .string(reason) }
    return .object(obj)
}

private func backfillResultSummaryJSON(_ results: [BackfillUploadOutcome]) -> JSONValue {
    .object([
        "total": .int(results.count),
        "uploaded": .int(results.filter { $0.result == .uploaded }.count),
        "already": .int(results.filter { $0.result == .alreadyUploaded }.count),
        "linked": .int(results.filter { $0.linked }.count),
        "skipped": .int(results.filter { $0.result == .skipped }.count),
        "failed": .int(results.filter { $0.result == .failed }.count),
    ])
}
