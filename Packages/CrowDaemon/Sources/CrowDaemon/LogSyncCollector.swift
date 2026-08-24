import Foundation
import Crypto
import CrowCore
import CrowEngine
import CrowPersistence

/// The daemon-side collector that drives the multi-harness session-log upload
/// (CROW-1056). One `sweep()` per poll tick: for every Crow session whose
/// workspace is opted in, it finds that session's harness log files, normalizes
/// them to NDJSON, and uploads them to Corveil as a session-transcript artifact
/// with the session's metadata attached.
///
/// Design guarantees:
/// - **Opt-in, default OFF.** Nothing uploads unless a session's workspace ticks
///   `uploadSessionLogs` **and** that workspace has a `gateway` to reuse (the
///   upload destination + credential come from it — CROW-1070).
/// - **Non-blocking / best-effort.** This runs entirely off the session
///   lifecycle; a failed or slow upload never delays or fails a session. One
///   retry inside the uploader, then the ledger records and (for transient
///   failures) backs off.
/// - **Idempotent backfill.** A ledger + the server's write-once 409 make a
///   repeated sweep converge without re-uploading.
/// - **No AWS credentials on the laptop.** The client only POSTs bytes with the
///   user's Corveil API key; the server uploads to object storage itself.
struct LogSyncCollector {
    let devRoot: String
    let uploader: TranscriptUploader
    /// Resolves an `op://…` reference to a secret (defaults to 1Password `op read`).
    let resolveSecret: (String) -> String?
    /// Injected clock for testability.
    let now: () -> Date

    /// Don't re-attempt a transiently-failed upload for this long.
    private let retryBackoff: TimeInterval = 30 * 60

    init(
        devRoot: String,
        uploader: TranscriptUploader = TranscriptUploader(),
        resolveSecret: @escaping (String) -> String? = { GatewayResolver.opRead($0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.devRoot = devRoot
        self.uploader = uploader
        self.resolveSecret = resolveSecret
        self.now = now
    }

    /// One collection pass. Reads config fresh so a Settings edit applies within
    /// one tick.
    func sweep(appState: AppState) async {
        guard let appConfig = ConfigStore.loadConfig(devRoot: devRoot) else { return }
        // Behavior tuning only (retention / quiet period / upload cap); an absent
        // block means all-default knobs (CROW-1070).
        let config = appConfig.logSync ?? LogSyncConfig()

        // Cheap exit before touching the store or disk: nothing opted in. Since
        // CROW-1070 the sole opt-in is the per-workspace `uploadSessionLogs`
        // checkbox — the legacy global master switch and `enabledWorkspaces` list
        // are gone (a legacy opt-in is migrated to this flag at boot).
        guard appConfig.workspaces.contains(where: { $0.uploadSessionLogs }) else { return }

        // Snapshot the live sessions + their worktrees on the main actor, then do
        // all filesystem/network work off it.
        let snapshot: [(session: Session, worktrees: [SessionWorktree])] = await MainActor.run {
            appState.sessions.map { ($0, appState.worktrees(for: $0.id)) }
        }

        let nowDate = now()
        let nowEpoch = nowDate.timeIntervalSince1970
        let quietPeriod = TimeInterval(max(0, config.quietPeriodMinutes) * 60)

        // Route ledger reads/writes through the shared, serialized store so the
        // user-initiated backfill (CROW-1075) can write concurrently without
        // losing updates. Both the poll loop and the backfill RPC handler resolve
        // the same actor via `shared(devRoot:)`.
        let ledgerStore = LogSyncLedgerStore.shared(devRoot: devRoot)

        for (session, worktrees) in snapshot {
            // Manager sessions run at the dev root, not in a workspace worktree.
            if session.isManager { continue }
            guard let worktree = primaryWorktree(worktrees) else { continue }

            guard let workspaceName = SessionService.workspaceName(
                    forWorktreePath: worktree.worktreePath, devRoot: devRoot)
            else { continue }
            // The per-workspace checkbox is the whole opt-in (matched
            // case-insensitively, like every other workspace lookup).
            guard let workspace = appConfig.workspaces.first(where: {
                $0.name.lowercased() == workspaceName.lowercased()
            }), workspace.uploadSessionLogs else { continue }

            // Destination + credential come SOLELY from this workspace's local-only
            // `gateway` (CROW-1070) — never a browser-flippable / web-writable
            // field, so a remote peer who ticked the checkbox
            // cannot redirect a credential-bearing upload to a host it chose. No
            // gateway (or no resolvable key / blank base URL) ⇒ nothing to reuse ⇒
            // skip. This is the security invariant, asserted in the tests.
            guard let upload = Self.resolvedUpload(for: workspace, resolveSecret: resolveSecret) else {
                LogSyncLog.warnOnce("log-sync: workspace \"\(workspaceName)\" opted in but has no reusable Corveil gateway (needs a base URL and an x-citadel-api-key); skipping")
                continue
            }
            let baseURL = upload.baseURL
            let apiKey = upload.apiKey

            let harness = LogSyncHarness(agentKind: session.agentKind)
            let kind = LogSyncArtifactKind.sessionTranscript
            let ledgerKey = LogSyncLedger.key(sessionUID: session.id.uuidString, harness: harness, kind: kind)
            guard await ledgerStore.shouldUpload(key: ledgerKey, now: nowEpoch, retryBackoff: retryBackoff) else { continue }

            // Where does this harness write its logs? Empty for harnesses whose
            // on-disk logs are not yet wired (everything but Claude, Codex, Grok,
            // Cursor, OpenCode, and Muse today — CROW-1089 / CROW-1098 / CROW-1095 /
            // CROW-1096 / CROW-1106). A globally-stored NDJSON/blob harness's source
            // carries a `cwdFilter` that `resolveFiles` applies to attribute one
            // worktree's sessions out of the shared tree (Codex/Cursor/Muse); Claude
            // and Grok partition by worktree directly; an OpenCode source
            // (`.openCodeStore`) is the single `opencode.db` file, cwd-attributed by
            // row inside `OpenCodeStore` rather than by dropping files.
            guard let agent = AgentRegistry.shared.agent(for: session.agentKind) else { continue }
            let sources = agent.logSources(worktreePath: worktree.worktreePath, harnessSessionID: nil)
            guard !sources.isEmpty else { continue }

            let files = sources.flatMap { Self.resolveFiles($0) }
            guard !files.isEmpty else { continue }

            // The source format and (for OpenCode) the worktree cwd drive both the
            // quiescence signal and the transcript build below.
            let format = sources.first?.format ?? .jsonl
            let openCodeCwd = sources.first?.cwdFilter ?? worktree.worktreePath

            // Only upload a quiescent transcript: a session still being written
            // to can grow, and the server's write-once 409 forbids replacing it.
            // File-per-session harnesses (Claude/Codex/Grok) use the newest file
            // mtime. OpenCode's one shared WAL database is different: a WAL commit
            // doesn't bump the main `.db` file's mtime, and that mtime reflects every
            // worktree's activity — so key on the newest write time of *this*
            // worktree's own top-level sessions instead (`OpenCodeStore.newestActivity`,
            // which a SQLite read sees even from the WAL).
            let newest = format == .openCodeStore
                ? OpenCodeStore.newestActivity(databaseFiles: files, cwd: openCodeCwd)
                : Self.newestModification(files)
            let terminal = session.status == .completed || session.status == .archived
            if !terminal {
                if let newest, nowDate.timeIntervalSince(newest) < quietPeriod { continue }
            }

            // Produce the NDJSON transcript. Claude and Grok sources are `.jsonl`;
            // Codex sources are `.logDir` (per-session rollouts concatenated); Cursor
            // sources are `.sqlite` (`CursorStore` extracts the messages) — all go
            // through the shared file-concatenation normalizer. OpenCode's
            // `.openCodeStore` is `opencode.db` (SQLite): its rows are selected by the
            // worktree cwd and reassembled by `OpenCodeStore` (stamped `.logDir` on
            // upload — see `artifactStamp`), a selector `normalize(files:)` can't
            // express.
            let cap = max(1, config.maxUploadBytes)
            let transcript: NormalizedTranscript?
            if format == .openCodeStore {
                transcript = OpenCodeStore.normalizeSessions(databaseFiles: files, cwd: openCodeCwd, maxBytes: cap)
            } else {
                transcript = TranscriptNormalizer.normalize(files: files, format: format, maxBytes: cap)
            }
            guard let transcript else { continue }

            let sha = Self.sha256Hex(transcript.data)
            // OpenCode's single `opencode.db` backs many sessions, so its filename
            // stem is not a harness session id — pass nil (the transcript may hold
            // several cwd-matched sessions anyway).
            let agentSessionID = format == .openCodeStore ? nil : Self.agentSessionID(from: files)
            let metadata = LogSyncSessionMetadata(
                name: session.name,
                status: session.status.rawValue,
                agentKind: session.agentKind.rawValue,
                ticketURL: session.ticketURL,
                ticketNumber: session.ticketNumber,
                repo: worktree.repoName,
                orgGoal: session.orgGoal)

            let result = await uploader.upload(
                baseURL: baseURL, apiKey: apiKey,
                sessionUID: session.id.uuidString,
                harness: harness, kind: kind, format: format.artifactStamp,
                transcript: transcript, metadata: metadata, agentSessionID: agentSessionID)

            let entry = Self.ledgerEntry(for: result, sha: sha, size: transcript.data.count, at: nowEpoch)
            await ledgerStore.record(key: ledgerKey, entry: entry)
            if result.isSuccess {
                LogSyncLog.info("uploaded transcript for session \(session.id.uuidString) (\(harness.rawValue), \(transcript.data.count) bytes)")
            }
        }

        await ledgerStore.prune(retentionDays: config.retentionDays, now: nowEpoch)
    }

    // MARK: - Pure helpers (unit-tested)

    /// The upload destination + credential for a workspace, derived **solely** from
    /// its local-only `gateway` (CROW-1070). This is the security invariant: the
    /// destination is `{gateway.baseURL}/api/crow-sessions/…` and the credential is
    /// the gateway's Corveil key — never a browser-writable
    /// field, so a remote peer who ticked the `uploadSessionLogs` checkbox cannot
    /// redirect a credential-bearing upload.
    ///
    /// Returns `nil` — meaning "upload nothing" — when the workspace has no gateway,
    /// the gateway carries no resolvable Corveil key, or its base URL is blank. A
    /// browser-writable field alone can therefore never produce an upload.
    static func resolvedUpload(
        for workspace: WorkspaceInfo, resolveSecret: (String) -> String?
    ) -> (baseURL: String, apiKey: String)? {
        guard let gateway = workspace.gateway, !gateway.isEmpty else { return nil }
        let baseURL = gateway.baseURL.trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty else { return nil }
        guard let apiKey = corveilAPIKey(from: gateway, resolveSecret: resolveSecret) else { return nil }
        return (baseURL, apiKey)
    }

    /// Resolve an `op://…` reference (via `resolveSecret`) or return a plaintext
    /// value literally. Nil for a blank ref or a failed `op` read. Used by the
    /// per-workspace gateway-credential path (CROW-1066).
    static func resolveRef(_ ref: String, resolveSecret: (String) -> String?) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("op://") {
            guard let secret = resolveSecret(trimmed) else { return nil }
            let cleaned = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        return trimmed
    }

    /// Gateway header names that may carry the Corveil API key, in preference
    /// order. `x-citadel-api-key` is Crow's established Corveil-gateway convention
    /// (see `docs/configuration.md`); the rest are accepted defensively so a
    /// differently-named credential header still resolves.
    static let corveilKeyHeaderNames = ["x-citadel-api-key", "authorization", "x-api-key", "x-corveil-key"]

    /// Extract the bare Corveil API key carried by a workspace's gateway (CROW-1066)
    /// so the upload can reuse it instead of asking for a second key. Finds the
    /// credential header by known name (case-insensitive), resolves an `op://…`
    /// reference the same way the gateway launch path does, and strips a leading
    /// `Bearer ` so the uploader can re-wrap it as `Authorization: Bearer <key>`.
    /// Returns nil when no known header is present or its value can't be resolved.
    static func corveilAPIKey(
        from gateway: WorkspaceGateway, resolveSecret: (String) -> String?
    ) -> String? {
        // Case-insensitive lookup; on a duplicate lowercased name keep the first
        // (deterministic).
        let byLowerName = Dictionary(
            gateway.customHeaders.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        for name in corveilKeyHeaderNames {
            guard let raw = byLowerName[name],
                  let resolved = resolveRef(raw, resolveSecret: resolveSecret)
            else { continue }
            let key = stripBearer(resolved)
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// Strip a leading, case-insensitive `Bearer ` scheme from a header value,
    /// leaving the bare key. A Corveil gateway stores `x-citadel-api-key: Bearer
    /// sk-…`, but `TranscriptUploader` assembles the `Authorization` header with
    /// its own `Bearer ` prefix — double-prefixing would authenticate as garbage.
    static func stripBearer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 7, trimmed.prefix(7).lowercased() == "bearer " {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// The worktree the agent runs in — the primary if flagged, else the first.
    private func primaryWorktree(_ worktrees: [SessionWorktree]) -> SessionWorktree? {
        worktrees.first(where: { $0.isPrimary }) ?? worktrees.first
    }

    /// Expand a log source to concrete regular files, oldest-modified first so a
    /// concatenated transcript reads chronologically. When the source carries a
    /// `cwdFilter` (a globally-stored harness like Codex), only files whose
    /// recorded working directory matches are kept — the attribution step that
    /// stops one worktree's upload from swallowing every session's rollouts
    /// (CROW-1089).
    static func resolveFiles(_ source: AgentLogSource) -> [URL] {
        let fm = FileManager.default
        switch source.selector {
        case .file:
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue else { return [] }
            return [URL(fileURLWithPath: source.path)]
        case .directory:
            let dir = URL(fileURLWithPath: source.path)
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
            var files: [URL] = []
            if source.recursive {
                guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
                for case let url as URL in en { files.append(url) }
            } else {
                guard let contents = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: keys) else { return [] }
                files = contents
            }
            var filtered = files.filter { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { return false }
                if let ext = source.fileExtension, url.pathExtension != ext { return false }
                if let prefix = source.fileNamePrefix, !url.lastPathComponent.hasPrefix(prefix) { return false }
                // Skip transcripts under an excluded directory component (Muse's
                // `subagent/` child sessions), in lockstep with the backfill scanner.
                if !source.excludePathComponents.isEmpty,
                   url.pathComponents.contains(where: { source.excludePathComponents.contains($0) }) {
                    return false
                }
                return true
            }
            filtered = applyingCwdFilter(filtered, source.cwdFilter, format: source.format)
            return filtered.sorted { a, b in
                (Self.modificationDate(a) ?? .distantPast) < (Self.modificationDate(b) ?? .distantPast)
            }
        }
    }

    /// Keep only files whose recorded `cwd` (read from the head for NDJSON via
    /// `AgentLogCwdReader`, or the sibling `meta.json` for a Cursor `.sqlite` store
    /// via `CursorStore`) equals `cwdFilter`, path-standardized on both sides.
    /// `nil` filter is a no-op (Claude, whose slug directory is already the filter;
    /// and OpenCode, whose single `opencode.db` is a `.file` source cwd-attributed by
    /// row inside `OpenCodeStore`, so it never reaches this directory-only path). A
    /// file with no readable cwd never matches — an unattributable transcript is
    /// dropped, not guessed (CROW-1089 / CROW-1095).
    static func applyingCwdFilter(
        _ files: [URL], _ cwdFilter: String?, format: AgentLogFormat = .logDir
    ) -> [URL] {
        guard let cwdFilter else { return files }
        let want = (cwdFilter as NSString).standardizingPath
        guard !want.isEmpty else { return [] }
        return files.filter { url in
            guard let cwd = recordedCwd(of: url, format: format) else { return false }
            return (cwd as NSString).standardizingPath == want
        }
    }

    /// The working directory a resolved log file recorded, choosing the reader by
    /// on-disk shape: a Cursor `.sqlite` store keeps its cwd in the sibling
    /// `meta.json` (`CursorStore.recordedCwd`), while Claude/Codex NDJSON records
    /// it in the transcript head (`AgentLogCwdReader`).
    static func recordedCwd(of url: URL, format: AgentLogFormat) -> String? {
        switch format {
        case .sqlite: return CursorStore.recordedCwd(forStoreDB: url)
        case .jsonl, .logDir: return AgentLogCwdReader.read(url)
        // OpenCode's `.openCodeStore` is a `.file` source cwd-attributed by row
        // inside `OpenCodeStore`, so it never reaches this directory-file probe.
        case .openCodeStore: return nil
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The newest mtime across `files` **and their SQLite `-wal`/`-shm`
    /// siblings**, so the quiet-period check sees a still-active store as active.
    /// A Cursor `store.db` in WAL mode commits to `store.db-wal`, not the main
    /// file, so checking only the resolved `store.db` could read a chat as
    /// quiescent while `cursor-agent` is still writing — and the server's
    /// write-once 409 would then freeze that partial transcript. Probing the
    /// siblings is a no-op for a harness (Claude/Codex) whose resolved files have
    /// none (CROW-1095).
    static func newestModification(_ files: [URL]) -> Date? {
        var newest: Date?
        for url in files {
            for candidate in [url,
                              URL(fileURLWithPath: url.path + "-wal"),
                              URL(fileURLWithPath: url.path + "-shm")] {
                if let d = modificationDate(candidate), d > (newest ?? .distantPast) {
                    newest = d
                }
            }
        }
        return newest
    }

    /// The harness's own session id when exactly one file backs the transcript;
    /// nil when several files were concatenated. For Claude/Codex it is the file's
    /// stem (the `.jsonl` UUID); for a Cursor `store.db` — always that literal name
    /// — it is the parent `<subId>` directory (the chat's agentId), since the stem
    /// "store" identifies nothing.
    static func agentSessionID(from files: [URL]) -> String? {
        guard files.count == 1 else { return nil }
        let file = files[0]
        if file.lastPathComponent == "store.db" {
            return file.deletingLastPathComponent().lastPathComponent
        }
        return file.deletingPathExtension().lastPathComponent
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func ledgerEntry(
        for result: TranscriptUploadResult, sha: String, size: Int, at: Double
    ) -> LogSyncLedger.Entry {
        if result.isSuccess {
            return LogSyncLedger.Entry(status: .uploaded, sha256: sha, sizeBytes: size, at: at)
        }
        if result.isPermanentFailure {
            let reason: String
            switch result {
            case .tooLarge: reason = "too_large"
            case .rejected(let s): reason = "rejected_\(s)"
            default: reason = "permanent"
            }
            return LogSyncLedger.Entry(status: .skippedPermanent, sha256: sha, sizeBytes: size, at: at, reason: reason)
        }
        return LogSyncLedger.Entry(status: .failedTransient, sha256: sha, sizeBytes: size, at: at, reason: "transient")
    }
}

/// Rate-limited logging for the collector so a persistent misconfiguration
/// (e.g. an unresolvable API key) is stated once, not every tick.
enum LogSyncLog {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var warned: Set<String> = []

    static func info(_ message: String) {
        CrowLog.info("[LogSync] \(message)")
    }

    static func warnOnce(_ message: String) {
        lock.lock()
        let firstTime = warned.insert(message).inserted
        lock.unlock()
        if firstTime { CrowLog.info("[LogSync] \(message)") }
    }
}
