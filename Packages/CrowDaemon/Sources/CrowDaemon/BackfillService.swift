import Foundation
import CrowCore
import CrowCodex
import CrowGrok

/// The daemon-side orchestration behind `backfill-scan` / `backfill-upload`
/// (CROW-1075). It composes the CrowCore pieces — the disk scanner, the ticket
/// validator, the shared ledger store — with the **live** upload path
/// (`TranscriptNormalizer` + `TranscriptUploader`), so a back-filled session
/// lands through exactly the same endpoint and idempotency machinery as a
/// live-captured one; only the `{uid}` (a Claude session UUID rather than a Crow
/// session UUID) and the reconstructed sidecar differ.
///
/// Lives in CrowDaemon because it reuses `LogSyncCollector`'s `sha256Hex` /
/// `ledgerEntry` (Crypto isn't a CrowCore dependency) and the same
/// `GatewayResolver`-backed credential path.
struct BackfillService: Sendable {
    let devRoot: String
    let uploader: TranscriptUploader
    let validator: TicketValidator
    /// Resolves an `op://…` reference to a secret (defaults to 1Password).
    let resolveSecret: @Sendable (String) -> String?
    let now: @Sendable () -> Date

    init(
        devRoot: String,
        uploader: TranscriptUploader = TranscriptUploader(),
        validator: TicketValidator = TicketValidator(),
        resolveSecret: @escaping @Sendable (String) -> String? = { GatewayResolver.opRead($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.devRoot = devRoot
        self.uploader = uploader
        self.validator = validator
        self.resolveSecret = resolveSecret
        self.now = now
    }

    // MARK: - Scan

    /// Reconcile the on-disk transcripts against the ledger.
    func scan(scanner: BackfillScanner? = nil) async -> [BackfillSession] {
        let store = LogSyncLedgerStore.shared(devRoot: devRoot)
        let ledger = await store.snapshot()
        // Resolve the Codex sessions tree through `CodexHome` (honors `$CODEX_HOME`)
        // and the Grok sessions tree through `GrokHome` (honors `$GROK_HOME`) — the
        // same trees the live collector and the launch paths read. CrowCore's
        // `BackfillScanner` can't import CrowCodex/CrowGrok, so the daemon injects
        // both (CROW-1089, CROW-1098).
        let s = scanner ?? BackfillScanner(
            devRoot: devRoot,
            codexSessionsDir: URL(fileURLWithPath: CodexHome.sessionsDir()),
            grokSessionsDir: URL(fileURLWithPath: GrokHome.sessionsDir()),
            now: now)
        return await s.scan(ledger: ledger)
    }

    // MARK: - Upload one session

    /// Upload one reconstructed session through the live path, gating the ticket
    /// REFERENCE on provider validation (decision #3). `upload` is the resolved
    /// `(baseURL, apiKey)` from the chosen workspace's gateway — the same
    /// destination + credential the live collector uses.
    func upload(
        session: BackfillSession,
        upload: (baseURL: String, apiKey: String),
        maxUploadBytes: Int
    ) async -> BackfillUploadOutcome {
        let store = LogSyncLedgerStore.shared(devRoot: devRoot)
        let uid = session.claudeSessionUID
        let harness = session.harness
        let format = Self.uploadFormat(for: harness)
        let key = LogSyncLedger.key(sessionUID: uid, harness: harness, kind: .sessionTranscript)
        let nowEpoch = now().timeIntervalSince1970

        // Idempotent: a slot the ledger records as uploaded or permanently
        // skipped is never re-attempted (retryBackoff 0 still lets a prior
        // transient failure retry).
        guard await store.shouldUpload(key: key, now: nowEpoch, retryBackoff: 0) else {
            return BackfillUploadOutcome(
                claudeSessionUID: uid, result: .alreadyUploaded, harness: harness,
                ownerRepo: session.ownerRepo, ticketNumber: session.ticketNumber)
        }

        let file = URL(fileURLWithPath: session.filePath)
        guard let transcript = TranscriptNormalizer.normalize(
            files: [file], format: format, maxBytes: max(1, maxUploadBytes)) else {
            return BackfillUploadOutcome(
                claudeSessionUID: uid, result: .skipped, harness: harness,
                ownerRepo: session.ownerRepo, reason: "empty_or_unreadable")
        }

        // Validate the reconstructed ticket before asserting any link.
        var ticketURL: String?
        var linkedNumber: Int?
        var ticketKind: BackfillTicketKind?
        var linked = false
        if let ownerRepo = session.ownerRepo, let host = session.host,
           let number = session.ticketNumber, let remote = Self.remote(ownerRepo: ownerRepo, host: host) {
            let kind = await validator.validate(remote: remote, number: number)
            ticketKind = kind
            if kind == .issue || kind == .pullRequest {
                ticketURL = BackfillReconstructor.ticketURL(remote: remote, number: number, kind: kind)
                linkedNumber = ticketURL != nil ? number : nil
                linked = ticketURL != nil
            }
        }

        let metadata = LogSyncSessionMetadata(
            name: session.worktreeName ?? session.slug,
            status: nil, // a historical session's Crow status is genuinely unknown
            agentKind: Self.agentKindRawValue(for: harness),
            ticketURL: ticketURL,
            ticketNumber: linkedNumber,
            repo: session.ownerRepo,
            orgGoal: nil)

        let result = await uploader.upload(
            baseURL: upload.baseURL, apiKey: upload.apiKey,
            sessionUID: uid, harness: harness, kind: .sessionTranscript, format: format,
            transcript: transcript, metadata: metadata, agentSessionID: uid)

        let sha = LogSyncCollector.sha256Hex(transcript.data)
        let entry = LogSyncCollector.ledgerEntry(
            for: result, sha: sha, size: transcript.data.count, at: nowEpoch)
        await store.record(key: key, entry: entry)

        return Self.outcome(
            uid: uid, result: result, harness: harness, linked: linked,
            ownerRepo: session.ownerRepo, ticketNumber: linkedNumber, ticketKind: ticketKind)
    }

    // MARK: - Helpers

    /// The upload `format` stamp for a harness's on-disk transcript. Claude and
    /// Grok each write a single NDJSON transcript (`.jsonl`); a Codex rollout is one
    /// of a set of per-session files the collector concatenates (`.logDir`). All
    /// three normalize through `concatenateNDJSON`, but the stamp is honest.
    static func uploadFormat(for harness: LogSyncHarness) -> AgentLogFormat {
        harness == .codex ? .logDir : .jsonl
    }

    /// The `agentKind` sidecar hint for a harness. Only the wired harnesses reach
    /// here; any other maps to Claude's kind as a harmless default (it never
    /// occurs — the scanner only emits `.claude`/`.codex`/`.grok`).
    static func agentKindRawValue(for harness: LogSyncHarness) -> String {
        switch harness {
        case .codex: return AgentKind.codex.rawValue
        case .grok: return AgentKind.grok.rawValue
        default: return AgentKind.claudeCode.rawValue
        }
    }

    /// Split a resolved `owner/repo` back into a `RepoRemote` for URL/validation.
    static func remote(ownerRepo: String, host: String) -> RepoRemote? {
        guard let slash = ownerRepo.lastIndex(of: "/") else { return nil }
        let owner = String(ownerRepo[..<slash])
        let repo = String(ownerRepo[ownerRepo.index(after: slash)...])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return RepoRemote(host: host, owner: owner, repo: repo)
    }

    static func outcome(
        uid: String, result: TranscriptUploadResult, harness: LogSyncHarness, linked: Bool,
        ownerRepo: String?, ticketNumber: Int?, ticketKind: BackfillTicketKind?
    ) -> BackfillUploadOutcome {
        let disposition: BackfillUploadOutcome.Result
        var reason: String?
        switch result {
        case .created: disposition = .uploaded
        case .alreadyExists: disposition = .alreadyUploaded
        case .tooLarge: disposition = .skipped; reason = "too_large"
        case .rejected(let s): disposition = .failed; reason = "rejected_\(s)"
        case .transient: disposition = .failed; reason = "transient"
        }
        return BackfillUploadOutcome(
            claudeSessionUID: uid, result: disposition, harness: harness, linked: linked,
            ownerRepo: ownerRepo, ticketNumber: ticketNumber, ticketKind: ticketKind, reason: reason)
    }
}
