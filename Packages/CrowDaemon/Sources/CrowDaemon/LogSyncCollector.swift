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
            // on-disk logs are not yet wired (everything but Claude today).
            guard let agent = AgentRegistry.shared.agent(for: session.agentKind) else { continue }
            let sources = agent.logSources(worktreePath: worktree.worktreePath, harnessSessionID: nil)
            guard !sources.isEmpty else { continue }

            let files = sources.flatMap { Self.resolveFiles($0) }
            guard !files.isEmpty else { continue }

            // Only upload a quiescent transcript: a session still being written
            // to can grow, and the server's write-once 409 forbids replacing it.
            let newest = Self.newestModification(files)
            let terminal = session.status == .completed || session.status == .archived
            if !terminal {
                if let newest, nowDate.timeIntervalSince(newest) < quietPeriod { continue }
            }

            // Pick the single format (all Claude sources are .jsonl; a mixed set
            // would be unusual — take the first source's format).
            let format = sources.first?.format ?? .jsonl
            guard let transcript = TranscriptNormalizer.normalize(
                files: files, format: format, maxBytes: max(1, config.maxUploadBytes))
            else { continue }

            let sha = Self.sha256Hex(transcript.data)
            let agentSessionID = Self.agentSessionID(from: files)
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
                harness: harness, kind: kind, format: format,
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
    /// concatenated transcript reads chronologically.
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
            let filtered = files.filter { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { return false }
                if let ext = source.fileExtension { return url.pathExtension == ext }
                return true
            }
            return filtered.sorted { a, b in
                (Self.modificationDate(a) ?? .distantPast) < (Self.modificationDate(b) ?? .distantPast)
            }
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func newestModification(_ files: [URL]) -> Date? {
        files.compactMap { modificationDate($0) }.max()
    }

    /// The harness's own session id when exactly one file backs the transcript
    /// (its filename stem, e.g. the Claude `.jsonl` UUID); nil when several files
    /// were concatenated.
    static func agentSessionID(from files: [URL]) -> String? {
        guard files.count == 1 else { return nil }
        return files[0].deletingPathExtension().lastPathComponent
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
