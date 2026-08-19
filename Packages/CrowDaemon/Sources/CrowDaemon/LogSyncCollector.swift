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
/// - **Opt-in, default OFF.** Nothing uploads unless `logSync.enabled` is true
///   *and* the session's workspace is listed in `logSync.enabledWorkspaces`.
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
        guard let appConfig = ConfigStore.loadConfig(devRoot: devRoot),
              let config = appConfig.logSync,
              config.enabled
        else { return }
        // Cheap exit before touching the store or disk: nothing opted in via
        // either surface — the per-workspace checkbox (CROW-1066) or the legacy,
        // local-only `enabledWorkspaces` list.
        let anyWorkspaceOptIn = appConfig.workspaces.contains { $0.uploadSessionLogs }
        guard anyWorkspaceOptIn || !config.enabledWorkspaces.isEmpty else { return }

        // The upload destination is the local-only, operator-set `logSync.baseURL`
        // — deliberately NOT the browser-flippable `corveilHost` (CROW-1066): a
        // remote peer who can tick the per-workspace checkbox must not also be able
        // to redirect a credential-bearing upload to a host it chose. Empty ⇒ off.
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty else {
            LogSyncLog.warnOnce("log-sync enabled but logSync.baseURL is empty; nothing will upload")
            return
        }
        // Global Corveil key (may be nil): authenticates the legacy list path and
        // is the fallback when a per-workspace opt-in has no reusable gateway
        // credential. Resolved once per sweep.
        let globalAPIKey = resolveAPIKey(config.apiKeyRef)

        // Snapshot the live sessions + their worktrees on the main actor, then do
        // all filesystem/network work off it.
        let snapshot: [(session: Session, worktrees: [SessionWorktree])] = await MainActor.run {
            appState.sessions.map { ($0, appState.worktrees(for: $0.id)) }
        }

        var ledger = LogSyncLedger.load(devRoot: devRoot)
        let nowDate = now()
        let nowEpoch = nowDate.timeIntervalSince1970
        let quietPeriod = TimeInterval(max(0, config.quietPeriodMinutes) * 60)

        for (session, worktrees) in snapshot {
            // Manager sessions run at the dev root, not in a workspace worktree.
            if session.isManager { continue }
            guard let worktree = primaryWorktree(worktrees) else { continue }

            guard let workspaceName = SessionService.workspaceName(
                    forWorktreePath: worktree.worktreePath, devRoot: devRoot)
            else { continue }
            let workspace = appConfig.workspaces.first {
                $0.name.lowercased() == workspaceName.lowercased()
            }

            // Opt-in via either surface: the per-workspace checkbox (CROW-1066) or
            // the legacy `enabledWorkspaces` list (matched case-insensitively).
            let optedInViaWorkspace = workspace?.uploadSessionLogs == true
            guard optedInViaWorkspace || config.uploadsWorkspace(workspaceName) else { continue }

            // Reuse the workspace's own gateway credential when it opted in that way
            // (CROW-1066) so the operator never re-enters a Corveil key; otherwise
            // fall back to the global `logSync` key.
            let resolvedKey: String? = {
                if optedInViaWorkspace, let gateway = workspace?.gateway, !gateway.isEmpty,
                   let key = Self.corveilAPIKey(from: gateway, resolveSecret: resolveSecret) {
                    return key
                }
                return globalAPIKey
            }()
            guard let apiKey = resolvedKey else {
                LogSyncLog.warnOnce("log-sync: no Corveil API key for workspace \"\(workspaceName)\" (no reusable gateway credential and no global logSync.apiKeyRef); skipping")
                continue
            }

            let harness = LogSyncHarness(agentKind: session.agentKind)
            let kind = LogSyncArtifactKind.sessionTranscript
            let ledgerKey = LogSyncLedger.key(sessionUID: session.id.uuidString, harness: harness, kind: kind)
            guard ledger.shouldUpload(key: ledgerKey, now: nowEpoch, retryBackoff: retryBackoff) else { continue }

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
            ledger.record(key: ledgerKey, entry: entry)
            if result.isSuccess {
                LogSyncLog.info("uploaded transcript for session \(session.id.uuidString) (\(harness.rawValue), \(transcript.data.count) bytes)")
            }
        }

        ledger.prune(retentionDays: config.retentionDays, now: nowEpoch)
        do {
            try ledger.save(devRoot: devRoot)
        } catch {
            LogSyncLog.info("failed to persist log-sync ledger: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Resolve an API key reference: `op://…` via `resolveSecret`, otherwise the
    /// literal value. Returns nil for a blank ref or a failed `op` read.
    func resolveAPIKey(_ ref: String) -> String? {
        Self.resolveRef(ref, resolveSecret: resolveSecret)
    }

    /// Resolve an `op://…` reference (via `resolveSecret`) or return a plaintext
    /// value literally. Nil for a blank ref or a failed `op` read. Shared by the
    /// global-key and per-workspace gateway-credential paths (CROW-1066).
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
