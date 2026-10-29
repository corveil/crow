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
/// - `backfill-scan` (read): reconcile the on-disk transcripts against the
///   upload ledger. Disk- and git-only; no provider calls. A whole scan can
///   outgrow the 1 MB socket reply (CROW-1378), so it answers with counts by
///   default and pages the rows on request (`view: "sessions"`), every page cut
///   to a byte budget and served from one cached snapshot named by `scan_id`.
/// - `backfill-upload` (write): upload a user-selected set through the live path,
///   idempotently, using the named workspace's gateway for destination +
///   credential (the same security invariant as the live collector — the
///   destination is never a browser-writable field). Serial and capped; never an
///   automatic or unbounded flood.
///
/// Not local-only: like `logsync`, no credential travels in the params (the key
/// is resolved server-side from the local-only gateway), so it backs a web
/// Settings panel.
func makeBackfillHandlers(
    devRoot: String,
    scanCache: BackfillScanCache? = nil
) -> [String: CommandRouter.Handler] {
    // One snapshot per daemon: a scan takes minutes on a large history, so
    // pages and a follow-up upload reuse it rather than re-walking the disk.
    let cache = scanCache ?? BackfillScanCache(scan: { await BackfillService(devRoot: devRoot).scan() })
    return [
        "backfill-scan": { params in
            try await mapRPCError { try await backfillScan(params: params, cache: cache) }
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
                var results: [BackfillUploadOutcome] = []
                if !explicit.isEmpty {
                    // The cached scan can predate a transcript the caller just
                    // read off a newer listing: re-scan once if any UID is missing.
                    var scanned = await cache.snapshot(refresh: false).sessions
                    let wanted = Set(explicit)
                    if !wanted.isSubset(of: Set(scanned.map(\.claudeSessionUID))) {
                        scanned = await cache.snapshot(refresh: true).sessions
                    }
                    // Select every scanned row whose UID was requested — a set
                    // membership test, not a uid→session map. A UID shared across
                    // harnesses (a Claude and a Codex session) therefore uploads
                    // BOTH rows instead of silently dropping one; each lands in its
                    // own harness-scoped ledger slot (CROW-1089). Cross-harness UID
                    // collisions are vanishingly rare, but keeping both reachable
                    // costs nothing and matches `--all`/`--all-high-confidence`.
                    toUpload = scanned.filter { wanted.contains($0.claudeSessionUID) }
                    // Still missing after a fresh scan: report it, never drop it.
                    let found = Set(toUpload.map(\.claudeSessionUID))
                    var reported = Set<String>()
                    for uid in explicit where !found.contains(uid) && reported.insert(uid).inserted {
                        results.append(BackfillUploadOutcome(
                            claudeSessionUID: uid, result: .skipped, reason: "not_found"))
                    }
                } else if let selectMode = params["select"]?.stringValue {
                    let scanned = await cache.snapshot(refresh: false).sessions
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
                // The snapshot's upload statuses are now stale. A capped `--all`
                // re-run must see them, or it would spend its whole cap on rows
                // the ledger already answers `already`.
                if !toUpload.isEmpty { await cache.invalidate() }
                return [
                    "results": .array(results.map { backfillOutcomeJSON($0) }),
                    "summary": backfillResultSummaryJSON(results),
                ]
            }
        },
    ]
}

/// Byte budget for one page of `sessions`, under the socket cap with headroom
/// for the envelope, `summary` and `breakdown`.
let backfillScanPageByteBudget = SocketServer.maxMessageSize * 3 / 4
let backfillScanDefaultLimit = 200
let backfillScanMaxLimit = 1000

private func backfillScan(
    params: [String: JSONValue],
    cache: BackfillScanCache
) async throws -> [String: JSONValue] {
    let view = params["view"]?.stringValue ?? "summary"
    guard view == "summary" || view == "sessions" else {
        throw RPCError.invalidParams("view must be \"summary\" or \"sessions\".")
    }
    let filter = try backfillScanFilter(params)
    let offset = try backfillNonNegativeInt(params, "offset") ?? 0
    let limit = min(max(1, try backfillNonNegativeInt(params, "limit") ?? backfillScanDefaultLimit),
                    backfillScanMaxLimit)

    let snapshot: BackfillScanCache.Snapshot
    if let id = params["scan_id"]?.stringValue, !id.isEmpty {
        guard let pinned = await cache.snapshot(id: id) else {
            throw RPCError.invalidParams(
                "Scan snapshot \(id) has expired or been replaced — re-run without --scan-id to take a new one.")
        }
        snapshot = pinned
    } else {
        let refresh = try SettingsRPC.patchBool(params, "refresh") ?? false
        snapshot = await cache.snapshot(refresh: refresh)
    }

    let matching = filter.isEmpty ? snapshot.sessions : snapshot.sessions.filter(filter.matches)
    var result: [String: JSONValue] = [
        "scan_id": .string(snapshot.id),
        "scanned_at": .double(snapshot.scannedAt.timeIntervalSince1970),
        "view": .string(view),
        "summary": backfillSummaryJSON(BackfillSummary(sessions: snapshot.sessions)),
        "breakdown": backfillBreakdownJSON(BackfillScanBreakdown(sessions: matching)),
        "total_matching": .int(matching.count),
    ]
    guard view == "sessions" else { return result }

    let encoder = JSONEncoder()
    let rows = matching.map { backfillSessionJSON($0) }
    let page = BackfillScanQuery.page(
        rows, offset: offset, limit: limit, maxBytes: backfillScanPageByteBudget,
        size: { (try? encoder.encode($0).count) ?? 0 })
    result["paged"] = .bool(true)
    result["sessions"] = .array(page.rows)
    result["offset"] = .int(min(offset, matching.count))
    result["limit"] = .int(limit)
    result["returned"] = .int(page.rows.count)
    result["next_offset"] = page.nextOffset.map { .int($0) } ?? .null
    result["truncated_by_size"] = .bool(page.truncatedByBytes)
    return result
}

private func backfillScanFilter(_ params: [String: JSONValue]) throws -> BackfillScanFilter {
    func parse<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T?
    where T.RawValue == String {
        guard let raw = params[key]?.stringValue, !raw.isEmpty else { return nil }
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let value = T(rawValue: normalized) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw RPCError.invalidParams("\(key) must be one of: \(allowed).")
        }
        return value
    }
    let workspace = params["workspace"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    return BackfillScanFilter(
        workspace: workspace,
        confidence: try parse("confidence", BackfillConfidence.self),
        status: try parse("status", BackfillStatusFilter.self),
        harness: try parse("harness", LogSyncHarness.self))
}

private func backfillNonNegativeInt(_ params: [String: JSONValue], _ key: String) throws -> Int? {
    guard let value = params[key], value != .null else { return nil }
    guard let n = value.intValue, n >= 0 else {
        throw RPCError.invalidParams("\(key) must be a non-negative integer.")
    }
    return n
}

/// The last `backfill-scan`, held so pages and uploads reuse one walk of the
/// disk (CROW-1378). Rows are stored pre-sorted (`BackfillScanQuery.ordered`),
/// so an offset names the same row on every call over a snapshot.
actor BackfillScanCache {
    struct Snapshot: Sendable {
        let id: String
        let scannedAt: Date
        let sessions: [BackfillSession]
    }

    /// How long an unpinned call reuses the last scan before re-walking.
    static let defaultTTL: TimeInterval = 15 * 60

    private let scan: @Sendable () async -> [BackfillSession]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var current: Snapshot?
    private var inFlight: Task<Snapshot, Never>?
    /// Bumped by `invalidate()`. A scan that started under an older generation
    /// read the ledger before the invalidating upload, so it is never published.
    private var generation = 0

    init(
        ttl: TimeInterval = BackfillScanCache.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        scan: @escaping @Sendable () async -> [BackfillSession]
    ) {
        self.ttl = ttl
        self.now = now
        self.scan = scan
    }

    /// The current snapshot, or a new scan when there is none, it is older
    /// than the TTL, or `refresh` is set. Concurrent callers share one scan.
    func snapshot(refresh: Bool) async -> Snapshot {
        if !refresh, let current, now().timeIntervalSince(current.scannedAt) < ttl {
            return current
        }
        if let inFlight { return await inFlight.value }
        let startedAt = generation
        let task = Task { [scan, now] in
            let sessions = BackfillScanQuery.ordered(await scan())
            return Snapshot(id: UUID().uuidString, scannedAt: now(), sessions: sessions)
        }
        inFlight = task
        let snapshot = await task.value
        // `invalidate()` already cleared `inFlight` if it ran mid-scan; only the
        // task that is still current may clear it.
        if startedAt == generation {
            inFlight = nil
            current = snapshot
        }
        return snapshot
    }

    /// The snapshot a paging caller pinned with `scan_id`, while it is still
    /// the current one. A pinned walk is never re-scanned under it: once the
    /// snapshot is replaced or invalidated this returns nil.
    func snapshot(id: String) -> Snapshot? {
        guard let current, current.id == id else { return nil }
        return current
    }

    /// Drop the snapshot (its upload statuses went stale).
    func invalidate() {
        current = nil
        inFlight = nil
        generation += 1
    }
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

private func backfillBreakdownJSON(_ b: BackfillScanBreakdown) -> JSONValue {
    func counts(_ d: [String: Int]) -> JSONValue { .object(d.mapValues { .int($0) }) }
    return .object([
        "total": .int(b.total),
        "by_harness": counts(b.byHarness),
        "by_workspace": counts(b.byWorkspace),
        "by_confidence": counts(b.byConfidence),
        "by_upload_status": counts(b.byUploadStatus),
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
