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
        guard let config = ConfigStore.loadConfig(devRoot: devRoot)?.logSync,
              config.enabled,
              !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        guard let apiKey = resolveAPIKey(config.apiKeyRef) else {
            LogSyncLog.warnOnce("log-sync enabled but the Corveil API key could not be resolved; nothing will upload")
            return
        }
        // Nothing opted in — cheap exit before touching the store or disk.
        guard !config.enabledWorkspaces.isEmpty else { return }

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

            // Per-workspace opt-in.
            guard let workspaceName = SessionService.workspaceName(
                    forWorktreePath: worktree.worktreePath, devRoot: devRoot),
                  config.uploadsWorkspace(workspaceName)
            else { continue }

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
                baseURL: config.baseURL, apiKey: apiKey,
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
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("op://") {
            guard let secret = resolveSecret(trimmed), !secret.isEmpty else { return nil }
            return secret
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
