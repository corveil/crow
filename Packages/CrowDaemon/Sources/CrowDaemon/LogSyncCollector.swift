import Foundation
import Crypto
import CrowCore
import CrowEngine
import CrowPersistence

/// The daemon-side collector that drives the multi-harness session-log upload
/// (CROW-1056). One `sweep()` per poll tick: for every Crow session whose
/// workspace is opted in, it finds that session's harness log files, normalizes
/// them to NDJSON, gzips them, and uploads them to Corveil as a
/// session-transcript artifact with the session's metadata attached. A session
/// being deleted gets one last pass first (`uploadBeforeDelete`, CROW-1394).
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
struct LogSyncCollector: Sendable {
    let devRoot: String
    let uploader: TranscriptUploader
    /// Resolves an `op://…` reference to a secret (defaults to 1Password `op read`).
    let resolveSecret: @Sendable (String) -> String?
    /// Injected clock for testability.
    let now: @Sendable () -> Date
    /// A harness's log sources for an agent kind and worktree path; nil when
    /// Crow knows no agent of that kind. Injected for tests.
    let logSources: @Sendable (AgentKind, String) -> [AgentLogSource]?
    /// Every agent kind whose logs a worktree may hold, besides the session's
    /// own label (CROW-1394). Defaults to every agent Crow knows, installed or
    /// not: a transcript on disk is worth shipping whether or not its binary
    /// is on PATH today. Injected for tests.
    let harnessKinds: @Sendable () -> [AgentKind]
    /// Finds one Manager conversation's transcript file by agent kind,
    /// conversation id and cwd. Injected for tests.
    let locateConversation: @Sendable (AgentKind, String, String) -> (path: String, format: AgentLogFormat)?
    /// Reads `config.json` fresh on every pass. Injected for tests.
    let loadConfig: @Sendable (String) -> AppConfig?
    /// Where skip reasons and upload lines go (once per key for skips).
    let log: LogSyncLog
    /// How long a delete may wait on the upload before it goes ahead anyway.
    let deleteUploadTimeout: Duration

    /// Don't re-attempt a transiently-failed upload for this long.
    private let retryBackoff: TimeInterval = 30 * 60

    init(
        devRoot: String,
        uploader: TranscriptUploader = TranscriptUploader(),
        resolveSecret: @escaping @Sendable (String) -> String? = { GatewayResolver.opRead($0) },
        now: @escaping @Sendable () -> Date = { Date() },
        logSources: @escaping @Sendable (AgentKind, String) -> [AgentLogSource]? = { kind, worktreePath in
            AgentRegistry.shared.allKnownAgents().first(where: { $0.agent.kind == kind })?.agent
                .logSources(worktreePath: worktreePath, harnessSessionID: nil)
        },
        harnessKinds: @escaping @Sendable () -> [AgentKind] = {
            AgentRegistry.shared.allKnownAgents().map(\.agent.kind)
        },
        locateConversation: @escaping @Sendable (AgentKind, String, String) -> (path: String, format: AgentLogFormat)? = {
            HarnessTranscriptLocator.transcriptFile(kind: $0, conversationID: $1, cwd: $2)
        },
        loadConfig: @escaping @Sendable (String) -> AppConfig? = { ConfigStore.loadConfig(devRoot: $0) },
        log: LogSyncLog = .shared,
        deleteUploadTimeout: Duration = .seconds(10)
    ) {
        self.devRoot = devRoot
        self.uploader = uploader
        self.resolveSecret = resolveSecret
        self.now = now
        self.logSources = logSources
        self.harnessKinds = harnessKinds
        self.locateConversation = locateConversation
        self.loadConfig = loadConfig
        self.log = log
        self.deleteUploadTimeout = deleteUploadTimeout
    }

    /// A session as the collector needs it, captured on the main actor.
    ///
    /// A Manager has no worktree; what locates its transcripts is the cwd of
    /// its agent pane (the `.crow/managers/<uuid>` identity dir for an extra
    /// Manager), so that is captured instead (CROW-1382). The session's
    /// PRODUCED PR is resolved here too (CROW-1115) — `producedPR` reads the
    /// actor-isolated `prAttributions` and session `.pr` links.
    struct SessionSnapshot: Sendable {
        let session: Session
        let worktrees: [SessionWorktree]
        let producedPR: (url: String, number: Int)?
        let managerCwd: String?
    }

    /// The settings one pass runs under.
    private struct Pass: Sendable {
        let appConfig: AppConfig
        let config: LogSyncConfig
        let ledgerStore: LogSyncLedgerStore
        let nowDate: Date
        /// Zero for an upload before delete: the session is going away, so
        /// there is nothing to wait for (CROW-1394).
        let quietPeriod: TimeInterval
        /// Set only before a delete: the slots in flight, so a timeout can
        /// record them as `failedTransient`.
        let inFlight: InFlightSlots?

        var nowEpoch: Double { nowDate.timeIntervalSince1970 }
        var cap: Int { max(1, config.maxUploadBytes) }
    }

    /// One collection pass. Reads config fresh so a Settings edit applies within
    /// one tick.
    func sweep(appState: AppState) async {
        guard let appConfig = loadConfig(devRoot) else { return }
        // Cheap exit before touching the store or disk: nothing opted in. Since
        // CROW-1070 the sole opt-in is the per-workspace `uploadSessionLogs`
        // checkbox — the legacy global master switch and `enabledWorkspaces` list
        // are gone (a legacy opt-in is migrated to this flag at boot).
        guard appConfig.workspaces.contains(where: { $0.uploadSessionLogs }) else { return }

        // Snapshot on the main actor, then do all filesystem/network work off it.
        let snapshot = await Self.snapshot(appState, only: nil)
        // Behavior tuning only (retention / quiet period / upload cap); an absent
        // block means all-default knobs (CROW-1070).
        let config = appConfig.logSync ?? LogSyncConfig()
        let pass = Pass(
            appConfig: appConfig, config: config,
            // Route ledger reads/writes through the shared, serialized store so the
            // user-initiated backfill (CROW-1075) can write concurrently without
            // losing updates. Both the poll loop and the backfill RPC handler resolve
            // the same actor via `shared(devRoot:)`.
            ledgerStore: LogSyncLedgerStore.shared(devRoot: devRoot),
            nowDate: now(),
            quietPeriod: TimeInterval(max(0, config.quietPeriodMinutes) * 60),
            inFlight: nil)

        for entry in snapshot {
            await collect(entry, pass)
        }

        await pass.ledgerStore.prune(retentionDays: config.retentionDays, now: pass.nowEpoch)
    }

    /// Upload whatever a session has not shipped yet, just before it is deleted
    /// (CROW-1394).
    ///
    /// A delete otherwise loses it: a sweep only sees sessions that still
    /// exist, and a Manager inside its quiet period, or a work session deleted
    /// between ticks, never got one. This runs the same path as a sweep for
    /// this one session, with no quiet period, while the worktree, the
    /// Manager's identity directory and every harness log are still on disk.
    /// The ledger still skips anything already `uploaded` or
    /// `skippedPermanent`, and the opt-in and gateway rules are unchanged.
    ///
    /// It never holds up the delete for long: after `deleteUploadTimeout` it
    /// returns, records each upload still in flight as `failedTransient`, and
    /// leaves the transcript on disk for `crow backfill upload`.
    func uploadBeforeDelete(sessionID: UUID, appState: AppState) async {
        // The primary Manager never uploads (CROW-1382), and cannot be deleted.
        guard sessionID != AppState.managerSessionID,
              let appConfig = loadConfig(devRoot),
              appConfig.workspaces.contains(where: { $0.uploadSessionLogs }),
              let entry = await Self.snapshot(appState, only: sessionID).first
        else { return }

        let inFlight = InFlightSlots()
        let pass = Pass(
            appConfig: appConfig, config: appConfig.logSync ?? LogSyncConfig(),
            ledgerStore: LogSyncLedgerStore.shared(devRoot: devRoot),
            nowDate: now(), quietPeriod: 0, inFlight: inFlight)

        let work = Task { await collect(entry, pass) }
        guard await !Self.finishes(work, within: deleteUploadTimeout) else { return }

        // Out of time. The upload may still land after the delete; if it does,
        // its own ledger write replaces this one.
        work.cancel()
        let stranded = await inFlight.drain()
        for key in stranded {
            await pass.ledgerStore.record(key: key, entry: LogSyncLedger.Entry(
                status: .failedTransient, sha256: "", sizeBytes: 0, at: pass.nowEpoch,
                reason: "delete_timeout"))
        }
        if !stranded.isEmpty {
            log.info("upload before deleting session \(sessionID.uuidString) timed out; \(stranded.count) transcript(s) left for `crow backfill upload`")
        }
    }

    /// Snapshot every session (`only: nil`) or one, with what the collector
    /// needs from the main actor.
    private static func snapshot(_ appState: AppState, only id: UUID?) async -> [SessionSnapshot] {
        await MainActor.run {
            appState.sessions
                .filter { id == nil || $0.id == id }
                .map { session in
                    let managerCwd = session.isManager
                        ? appState.terminals(for: session.id)
                            .first(where: { $0.isAgentSurface(session: session) })?.cwd
                        : nil
                    return SessionSnapshot(
                        session: session, worktrees: appState.worktrees(for: session.id),
                        producedPR: appState.producedPR(for: session), managerCwd: managerCwd)
                }
        }
    }

    private func collect(_ entry: SessionSnapshot, _ pass: Pass) async {
        // Managers have no worktree to derive a workspace from. Only an
        // extra Manager tagged with an opted-in workspace ships; untagged
        // ones — the primary always among them — never do (CROW-1382).
        if entry.session.isManager {
            await collectManager(session: entry.session, cwd: entry.managerCwd, pass)
        } else {
            await collectWorkSession(entry, pass)
        }
    }

    /// Ship a work session's transcripts: one artifact per harness that left
    /// logs in its worktree (CROW-1394).
    ///
    /// Every known harness is asked, not just `session.agentKind`. A session
    /// handed from Codex to Claude in the same terminal keeps its Codex label
    /// while the transcript Claude wrote is the one on disk, and a label no
    /// registered agent answers to (`claude` rather than `claude-code`) would
    /// otherwise skip the session outright. The ledger key carries the harness,
    /// and Codex, Cursor and Muse filter their shared stores by the worktree's
    /// cwd, so each artifact is attributed to the harness that actually wrote it.
    private func collectWorkSession(_ entry: SessionSnapshot, _ pass: Pass) async {
        let session = entry.session
        // Every skip below is logged once per session (and harness) with
        // what was looked at, so a session that never reaches Corveil says
        // why (CROW-1395). Two exits stay quiet on purpose: a workspace
        // with `uploadSessionLogs` off (the operator's choice) and a
        // transcript still inside the quiet period (waiting, not skipped).
        guard let worktree = primaryWorktree(entry.worktrees) else {
            skip(session, "no-worktree", "has no worktree")
            return
        }

        guard let workspaceName = SessionService.workspaceName(
                forWorktreePath: worktree.worktreePath, devRoot: devRoot)
        else {
            skip(session, "no-workspace",
                 "worktree \(Self.displayPath(worktree.worktreePath)) is not under the dev root \(Self.displayPath(devRoot))")
            return
        }
        // The per-workspace checkbox is the whole opt-in (matched
        // case-insensitively, like every other workspace lookup).
        guard let workspace = pass.appConfig.workspaces.first(where: {
            $0.name.lowercased() == workspaceName.lowercased()
        }) else {
            skip(session, "no-workspace",
                 "no configured workspace \"\(workspaceName)\" for worktree \(Self.displayPath(worktree.worktreePath))")
            return
        }
        guard workspace.uploadSessionLogs else { return }

        // Destination + credential come SOLELY from this workspace's local-only
        // `gateway` (CROW-1070) — never a browser-flippable / web-writable
        // field, so a remote peer who ticked the checkbox
        // cannot redirect a credential-bearing upload to a host it chose. No
        // gateway (or no resolvable key / blank base URL) ⇒ nothing to reuse ⇒
        // skip. This is the security invariant, asserted in the tests.
        guard let upload = Self.resolvedUpload(for: workspace, resolveSecret: resolveSecret) else {
            log.warnOnce("log-sync: workspace \"\(workspaceName)\" opted in but has no reusable Corveil gateway (needs a base URL and an x-citadel-api-key); skipping")
            return
        }

        // The session's own label first, then every other known kind. A kind
        // that resolves no agent doesn't claim its harness slot, so an
        // unregistered label (`claude`) can't hide the registered one that
        // shares nothing with it but the logs. Kinds that do share a slot
        // (every unrecognized kind is `.unknown`) are asked once.
        var kinds = [session.agentKind]
        for kind in harnessKinds() where !kinds.contains(kind) { kinds.append(kind) }
        var seen = Set<LogSyncHarness>()
        var foundAny = false
        for kind in kinds {
            let harness = LogSyncHarness(agentKind: kind)
            guard !seen.contains(harness), let sources = logSources(kind, worktree.worktreePath) else { continue }
            seen.insert(harness)
            if await collectHarness(
                kind, harness: harness, sources: sources, entry: entry, worktree: worktree,
                upload: upload, pass) {
                foundAny = true
            }
        }
        guard !foundAny else { return }

        // Nothing on disk from any harness: say why in terms of the label,
        // the harness the session was launched with.
        let agentName = session.agentKind.rawValue
        let labelHarness = LogSyncHarness(agentKind: session.agentKind)
        guard let sources = logSources(session.agentKind, worktree.worktreePath) else {
            skip(session, harness: labelHarness, "no-agent", "no registered agent for \(agentName)")
            return
        }
        guard !sources.isEmpty else {
            skip(session, harness: labelHarness, "no-log-sources",
                 "\(agentName) has no on-disk transcript source wired for log sync")
            return
        }
        skip(session, harness: labelHarness, "no-transcript",
             "no \(agentName) transcript under \(Self.describe(sources))")
    }

    /// Upload one harness's transcript for a work session. Returns whether
    /// that harness had any log files for the worktree.
    private func collectHarness(
        _ agentKind: AgentKind, harness: LogSyncHarness, sources: [AgentLogSource],
        entry: SessionSnapshot, worktree: SessionWorktree,
        upload: (baseURL: String, apiKey: String), _ pass: Pass
    ) async -> Bool {
        let session = entry.session
        let kind = LogSyncArtifactKind.sessionTranscript
        let ledgerKey = LogSyncLedger.key(sessionUID: session.id.uuidString, harness: harness, kind: kind)
        // Already shipped (or given up on) counts as found: there were files.
        guard await pass.ledgerStore.shouldUpload(key: ledgerKey, now: pass.nowEpoch, retryBackoff: retryBackoff) else { return true }

        // Where does this harness write its logs? Empty for harnesses whose
        // on-disk logs are not yet wired (everything but Claude, Codex, Grok,
        // Cursor, OpenCode, and Muse today — CROW-1089 / CROW-1098 / CROW-1095 /
        // CROW-1096 / CROW-1106). A globally-stored NDJSON/blob harness's source
        // carries a `cwdFilter` that `resolveFiles` applies to attribute one
        // worktree's sessions out of the shared tree (Codex/Cursor/Muse); Claude
        // and Grok partition by worktree directly; an OpenCode source
        // (`.openCodeStore`) is the single `opencode.db` file, cwd-attributed by
        // row inside `OpenCodeStore` rather than by dropping files.
        let files = sources.flatMap { Self.resolveFiles($0) }
        guard !files.isEmpty else { return false }

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
        let terminal = session.status == .completed || session.status == .archived
        if !terminal, pass.quietPeriod > 0 {
            let newest = format == .openCodeStore
                ? OpenCodeStore.newestActivity(databaseFiles: files, cwd: openCodeCwd)
                : Self.newestModification(files)
            if let newest, pass.nowDate.timeIntervalSince(newest) < pass.quietPeriod { return true }
        }

        await pass.inFlight?.begin(ledgerKey)
        // Produce the NDJSON transcript. Claude and Grok sources are `.jsonl`;
        // Codex sources are `.logDir` (per-session rollouts concatenated); Cursor
        // sources are `.sqlite` (`CursorStore` extracts the messages) — all go
        // through the shared file-concatenation normalizer. OpenCode's
        // `.openCodeStore` is `opencode.db` (SQLite): its rows are selected by the
        // worktree cwd and reassembled by `OpenCodeStore` (stamped `.logDir` on
        // upload — see `artifactStamp`), a selector `normalize(files:)` can't
        // express. Then gzip, with the cap on the compressed body (CROW-1394).
        let budget = TranscriptNormalizer.rawReadBudget(forCompressedCap: pass.cap)
        let raw: NormalizedTranscript? = format == .openCodeStore
            ? OpenCodeStore.normalizeSessions(databaseFiles: files, cwd: openCodeCwd, maxBytes: budget)
            : TranscriptNormalizer.normalize(files: files, format: format, maxBytes: budget)
        guard let transcript = raw.flatMap({ TranscriptNormalizer.gzipForUpload($0, maxBytes: pass.cap) }) else {
            await pass.inFlight?.end(ledgerKey)
            skip(session, harness: harness, "empty-transcript",
                 "\(agentKind.rawValue) transcript normalized to nothing (\(files.count) file(s) under \(Self.describe(sources)))")
            return true
        }
        logTruncation(session, harness: harness, scope: nil,
                      transcript: transcript, files: files, cap: pass.cap)

        // OpenCode's single `opencode.db` backs many sessions, so its filename
        // stem is not a harness session id — pass nil (the transcript may hold
        // several cwd-matched sessions anyway).
        let agentSessionID = format == .openCodeStore ? nil : Self.agentSessionID(from: files)
        let metadata = LogSyncSessionMetadata(
            name: session.name,
            status: session.status.rawValue,
            // The harness that wrote these logs, which after a handoff need
            // not be the session's label.
            agentKind: agentKind.rawValue,
            ticketURL: session.ticketURL,
            ticketNumber: session.ticketNumber,
            prURL: entry.producedPR?.url,
            prNumber: entry.producedPR?.number,
            repo: worktree.repoName,
            orgGoal: session.orgGoal)

        let result = await uploader.upload(
            baseURL: upload.baseURL, apiKey: upload.apiKey,
            sessionUID: session.id.uuidString,
            harness: harness, kind: kind, format: format.artifactStamp,
            transcript: transcript, metadata: metadata, agentSessionID: agentSessionID)
        await finish(
            ledgerKey, result: result, transcript: transcript, pass,
            label: "transcript for session \(session.id.uuidString) (\(harness.rawValue)")
        return true
    }

    /// Ship a tagged Manager's transcripts (CROW-1382).
    ///
    /// Same opt-in and security invariant as a workspace session: the Manager's
    /// tagged workspace must have `uploadSessionLogs` on, and the destination +
    /// credential come solely from that workspace's local-only gateway — never
    /// `AppConfig.managerGateway`, which the Manager may *launch* with when its
    /// workspace has none, but which is no workspace's upload address.
    ///
    /// Unlike a work session, a Manager is long-lived and resumes: it can run
    /// many harness conversations, and the server keeps one artifact per
    /// `(uid, harness, kind)` forever. Uploading under the Crow session id
    /// would ship the first conversation and 409 every later one. So each
    /// conversation is its own upload, keyed — in the ledger and in the URL —
    /// by the harness's conversation id. That is also the uid `backfill scan`
    /// reports for the same file, so a conversation shipped here reads as
    /// uploaded there too.
    private func collectManager(session: Session, cwd: String?, _ pass: Pass) async {
        // Untagged — the primary Manager is always among them — never ships,
        // by design; that is not a skip worth stating.
        guard let tag = session.managerWorkspaceTag else { return }
        guard let workspace = pass.appConfig.workspaces.first(where: { $0.id == tag }) else {
            skip(session, "no-workspace", "tagged with workspace \(tag.uuidString), which is no longer configured")
            return
        }
        guard workspace.uploadSessionLogs else { return }
        guard let cwd else {
            skip(session, "no-cwd", "Manager has no agent terminal to read a working directory from")
            return
        }
        guard let upload = Self.resolvedUpload(for: workspace, resolveSecret: resolveSecret) else {
            log.warnOnce("log-sync: workspace \"\(workspace.name)\" opted in but has no reusable Corveil gateway (needs a base URL and an x-citadel-api-key); skipping")
            return
        }
        let kind = LogSyncArtifactKind.sessionTranscript
        let conversations = Self.managerConversations(session)
        if conversations.isEmpty {
            skip(session, "no-conversation", "Manager has no harness conversation ID recorded yet")
        }
        for ref in conversations {
            let harness = LogSyncHarness(agentKind: ref.agentKind)
            let ledgerKey = LogSyncLedger.key(sessionUID: ref.id, harness: harness, kind: kind)
            guard await pass.ledgerStore.shouldUpload(key: ledgerKey, now: pass.nowEpoch, retryBackoff: retryBackoff) else { continue }
            // By conversation id, never by "whatever is in the cwd" — see
            // `HarnessTranscriptLocator.transcriptFile`. Cursor and OpenCode
            // have no per-conversation file and are skipped.
            guard let located = locateConversation(ref.agentKind, ref.id, cwd) else {
                skip(session, harness: harness, scope: ref.id, "no-transcript",
                     "no \(ref.agentKind.rawValue) transcript file for conversation \(ref.id) (cwd \(Self.displayPath(cwd)))")
                continue
            }
            let file = URL(fileURLWithPath: located.path)
            // The conversation still being written to can grow, and the
            // server's write-once 409 forbids replacing it. A Manager is never
            // `completed`, so quiescence is the only gate — except right
            // before a delete, when nothing more will be written.
            if pass.quietPeriod > 0, let newest = Self.newestModification([file]),
               pass.nowDate.timeIntervalSince(newest) < pass.quietPeriod { continue }

            await pass.inFlight?.begin(ledgerKey)
            let raw = TranscriptNormalizer.normalize(
                files: [file], format: located.format,
                maxBytes: TranscriptNormalizer.rawReadBudget(forCompressedCap: pass.cap))
            guard let transcript = raw.flatMap({ TranscriptNormalizer.gzipForUpload($0, maxBytes: pass.cap) }) else {
                await pass.inFlight?.end(ledgerKey)
                skip(session, harness: harness, scope: ref.id, "empty-transcript",
                     "\(ref.agentKind.rawValue) transcript for conversation \(ref.id) normalized to nothing (\(Self.displayPath(located.path)))")
                continue
            }
            logTruncation(session, harness: harness, scope: ref.id,
                          transcript: transcript, files: [file], cap: pass.cap)

            let metadata = LogSyncSessionMetadata(
                name: session.name,
                status: session.status.rawValue,
                agentKind: ref.agentKind.rawValue,
                orgGoal: session.orgGoal)
            let result = await uploader.upload(
                baseURL: upload.baseURL, apiKey: upload.apiKey,
                sessionUID: ref.id,
                harness: harness, kind: kind, format: located.format.artifactStamp,
                transcript: transcript, metadata: metadata, agentSessionID: ref.id)
            await finish(
                ledgerKey, result: result, transcript: transcript, pass,
                label: "Manager transcript \(ref.id) for session \(session.id.uuidString) (\(harness.rawValue)")
        }
    }

    /// Record an upload's outcome. The ledger's `sha256`/`sizeBytes` describe
    /// the body as sent — compressed (CROW-1394).
    private func finish(
        _ ledgerKey: String, result: TranscriptUploadResult, transcript: NormalizedTranscript,
        _ pass: Pass, label: String
    ) async {
        // Leave the in-flight set before writing, so a delete timeout firing
        // in between can't overwrite this outcome with its own.
        await pass.inFlight?.end(ledgerKey)
        let entry = Self.ledgerEntry(
            for: result, sha: Self.sha256Hex(transcript.data), size: transcript.data.count, at: pass.nowEpoch)
        await pass.ledgerStore.record(key: ledgerKey, entry: entry)
        if result.isSuccess {
            log.info("uploaded \(label), \(transcript.data.count) bytes)")
        } else if pass.inFlight != nil {
            log.info("upload before delete failed: \(label), \(result)); left for `crow backfill upload`")
        }
    }

    /// Whether `task` completes within `timeout`. Returns at the deadline even
    /// if the task is stuck in work that ignores cancellation, which a task
    /// group could not: it waits for every child before returning.
    static func finishes(_ task: Task<Void, Never>, within timeout: Duration) async -> Bool {
        let gate = FirstResume()
        return await withCheckedContinuation { continuation in
            gate.arm(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                gate.resume(false)
            }
            Task {
                await task.value
                gate.resume(true)
                timer.cancel()
            }
        }
    }

    // MARK: - Skip logging (CROW-1395)

    /// State why `session` is not uploading, once per session, harness,
    /// `scope` (a Manager conversation id) and `reason`. The message names what
    /// was looked at — paths, ids, the agent — and never transcript text or a
    /// credential.
    private func skip(
        _ session: Session, harness: LogSyncHarness? = nil, scope: String? = nil,
        _ reason: String, _ detail: String
    ) {
        let key = [session.id.uuidString, harness?.rawValue ?? "", scope ?? "", reason]
            .joined(separator: "|")
        log.once(key: key, "log-sync: session \(session.id.uuidString) \"\(session.name)\": \(detail); skipping")
    }

    /// A transcript cut at the size cap still uploads; say so once, with how
    /// much was on disk and how much was sent.
    private func logTruncation(
        _ session: Session, harness: LogSyncHarness, scope: String?,
        transcript: NormalizedTranscript, files: [URL], cap: Int
    ) {
        guard transcript.truncated else { return }
        let key = [session.id.uuidString, harness.rawValue, scope ?? "", "truncated"]
            .joined(separator: "|")
        let onDisk = files.reduce(0) { $0 + Self.fileSize($1) }
        let which = scope.map { "conversation \($0) " } ?? ""
        log.once(key: key, "log-sync: session \(session.id.uuidString) \"\(session.name)\": \(which)transcript truncated at the \(cap)-byte cap (\(onDisk) bytes on disk, \(transcript.data.count) bytes sent)")
    }

    /// The paths a harness's sources point at, home-abbreviated, plus the cwd
    /// filter when one narrows a shared tree.
    static func describe(_ sources: [AgentLogSource]) -> String {
        sources.map { source in
            let path = displayPath(source.path)
            guard let cwd = source.cwdFilter else { return path }
            return "\(path) (matching cwd \(displayPath(cwd)))"
        }.joined(separator: ", ")
    }

    /// `path` with the home directory shown as `~`.
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if !home.isEmpty, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    // MARK: - Pure helpers (unit-tested)

    /// Every conversation a Manager has run, oldest first: its recorded
    /// history, plus the current id when it predates the history (a Manager
    /// whose last hook fired before CROW-1382 recorded one).
    static func managerConversations(_ session: Session) -> [HarnessConversationRef] {
        var refs = session.harnessConversationHistory
        if let current = session.harnessConversationID,
           !refs.contains(where: { $0.id == current }) {
            refs.append(HarnessConversationRef(agentKind: session.agentKind, id: current))
        }
        return refs
    }

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
            guard let cwd = recordedCwdCache.cwd(of: url, format: format) else { return false }
            return (cwd as NSString).standardizingPath == want
        }
    }

    /// Every session now asks every harness (CROW-1394), so each tick would
    /// otherwise re-read the head of every file in the shared Codex, Cursor
    /// and Muse stores once per session.
    static let recordedCwdCache = RecordedCwdCache()

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

/// The ledger keys an upload-before-delete has started but not recorded, so
/// a timeout knows which ones to mark `failedTransient` (CROW-1394).
actor InFlightSlots {
    private var keys: Set<String> = []
    func begin(_ key: String) { keys.insert(key) }
    func end(_ key: String) { keys.remove(key) }
    func drain() -> Set<String> {
        defer { keys.removeAll() }
        return keys
    }
}

/// The cwd each log file recorded, remembered per path and mtime so a file is
/// read once until it changes. Only found cwds are kept: a file whose head
/// isn't written yet is asked again next time.
final class RecordedCwdCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (modified: Date, cwd: String)] = [:]
    /// A backstop; there is one entry per transcript file on disk.
    private let limit = 50_000

    func cwd(of url: URL, format: AgentLogFormat) -> String? {
        guard let modified = LogSyncCollector.modificationDate(url) else {
            return LogSyncCollector.recordedCwd(of: url, format: format)
        }
        if let hit = lock.withLock({ entries[url.path] }), hit.modified == modified {
            return hit.cwd
        }
        guard let cwd = LogSyncCollector.recordedCwd(of: url, format: format) else { return nil }
        lock.withLock {
            if entries.count >= limit { entries.removeAll() }
            entries[url.path] = (modified, cwd)
        }
        return cwd
    }
}

/// Resumes a continuation once, for whichever racer gets there first.
private final class FirstResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Rate-limited logging for the collector so a persistent misconfiguration
/// (e.g. an unresolvable API key) or a skipped session is stated once, not
/// every tick. `shared` writes to `CrowLog`; a test passes its own `sink`.
final class LogSyncLog: @unchecked Sendable {
    static let shared = LogSyncLog()

    private let lock = NSLock()
    /// Only touched while holding `lock`.
    private var seen: Set<String> = []
    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void = { CrowLog.info("[LogSync] \($0)") }) {
        self.sink = sink
    }

    func info(_ message: String) {
        sink(message)
    }

    func warnOnce(_ message: String) {
        once(key: message, message)
    }

    /// Emit `message` the first time `key` is seen, so a message whose detail
    /// changes between sweeps (a size, a path) still logs once.
    func once(key: String, _ message: String) {
        lock.lock()
        let firstTime = seen.insert(key).inserted
        lock.unlock()
        if firstTime { sink(message) }
    }
}
