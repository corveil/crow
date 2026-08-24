import Foundation

/// Reconciles the coding-session transcripts already on disk against what has
/// been uploaded, reconstructing each one's workspace / repo / ticket so the
/// Settings "Backfill history" dialog can show a reviewable list (CROW-1075).
///
/// Three harnesses are wired: **Claude**, whose logs are partitioned by
/// working directory (`~/.claude/projects/<slug>/<uuid>.jsonl`); **Codex**,
/// whose rollouts pool globally under `~/.codex/sessions/<date>/…` but each record
/// their own `cwd` in a first-line `session_meta` event (CROW-1089); and **Grok**,
/// which partitions by working directory too, encoding the cwd into the directory
/// name (`~/.grok/sessions/<url-encoded-cwd>/<uuid>/chat_history.jsonl`, CROW-1098).
/// All three make historical reconstruction reliable because the real `cwd` is
/// recoverable — Claude/Codex record it in the transcript, Grok encodes it in the
/// path — the authoritative signal, not a lossy directory name. The
/// scan is disk- and git-only — it never touches the provider or the network, so
/// it stays fast over hundreds of sessions; ticket *validation* is deferred to
/// upload, where a link is actually asserted.
///
/// Everything effectful is injected (the projects directory, the Codex sessions
/// directory, the git-remote reader, the clock), so the reconciliation logic is
/// unit-testable against a temporary tree.
public struct BackfillScanner: Sendable {
    let devRoot: String
    /// `~/.claude/projects` by default — where Claude writes per-project slug
    /// directories of `<session-uuid>.jsonl` transcripts.
    let projectsDir: URL
    /// `~/.codex/sessions` by default — where Codex writes date-partitioned
    /// `rollout-<ts>-<uuid>.jsonl` files (CROW-1089). Distinct from
    /// `~/.codex/archived_sessions`, which is deliberately not scanned. The daemon
    /// injects the `$CODEX_HOME`-resolved tree (via `CodexHome`, which CrowCore
    /// can't import); this literal default is the fallback for a direct caller.
    let codexSessionsDir: URL
    /// `~/.grok/sessions` by default — where Grok Build writes its per-worktree
    /// `<url-encoded-cwd>/<session-uuid>/chat_history.jsonl` transcripts (CROW-1098).
    /// The daemon injects the `$GROK_HOME`-resolved tree (via `GrokHome`, which
    /// CrowCore can't import); this literal default is the fallback for a direct
    /// caller.
    let grokSessionsDir: URL
    /// Resolve a directory's `origin` remote URL (default: `git -C <dir> remote
    /// get-url origin`). Injected so tests need no real repos.
    let gitRemote: @Sendable (String) async -> String?
    let now: @Sendable () -> Date

    public init(
        devRoot: String,
        projectsDir: URL? = nil,
        codexSessionsDir: URL? = nil,
        grokSessionsDir: URL? = nil,
        runner: any ShellRunner = ProcessShellRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.devRoot = devRoot
        self.projectsDir = projectsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexSessionsDir = codexSessionsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.grokSessionsDir = grokSessionsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions", isDirectory: true)
        self.gitRemote = { dir in
            (try? await runner.run(args: ["git", "-C", dir, "remote", "get-url", "origin"],
                                   env: [:], cwd: nil))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.now = now
    }

    /// Test seam: inject the git-remote reader directly. `codexSessionsDir` /
    /// `grokSessionsDir` default to nonexistent paths so a test that only stages
    /// Claude transcripts stays hermetic (it never accidentally scans a dev
    /// machine's real `~/.codex/sessions` or `~/.grok/sessions`); a Codex or Grok
    /// test passes an explicit temp dir.
    init(
        devRoot: String,
        projectsDir: URL,
        codexSessionsDir: URL? = nil,
        grokSessionsDir: URL? = nil,
        gitRemote: @escaping @Sendable (String) async -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.devRoot = devRoot
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
            ?? projectsDir.appendingPathComponent("__no_codex_sessions__", isDirectory: true)
        self.grokSessionsDir = grokSessionsDir
            ?? projectsDir.appendingPathComponent("__no_grok_sessions__", isDirectory: true)
        self.gitRemote = gitRemote
        self.now = now
    }

    /// Reconcile every on-disk transcript (Claude + Codex + Grok) against the
    /// ledger and return the reconstructed rows, newest first.
    public func scan(ledger: LogSyncLedger) async -> [BackfillSession] {
        let remotes = await resolveRemotes()
        let knownRepoNames = Array(Set(remotes.values.map { $0.repo }))

        var sessions: [BackfillSession] = []
        for file in transcriptFiles() {
            guard let s = reconstructClaude(
                file: file, remotesByRepo: remotes,
                knownRepoNames: knownRepoNames, ledger: ledger)
            else { continue }
            sessions.append(s)
        }
        for file in codexRolloutFiles() {
            guard let s = reconstructCodex(
                file: file, remotesByRepo: remotes,
                knownRepoNames: knownRepoNames, ledger: ledger)
            else { continue }
            sessions.append(s)
        }
        for file in grokChatHistoryFiles() {
            guard let s = reconstructGrok(
                file: file, remotesByRepo: remotes,
                knownRepoNames: knownRepoNames, ledger: ledger)
            else { continue }
            sessions.append(s)
        }
        sessions.sort { $0.modifiedAt > $1.modifiedAt }
        return sessions
    }

    // MARK: - Reconstruction of one file

    /// Reconstruct one Claude transcript: uid is the `.jsonl` stem, slug is the
    /// project-slug parent directory, and the head is read with the flat top-level
    /// keys Claude fills within its first handful of events.
    func reconstructClaude(
        file: URL, remotesByRepo: [String: RepoRemote],
        knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        let uid = file.deletingPathExtension().lastPathComponent
        guard !uid.isEmpty else { return nil }
        let slug = file.deletingLastPathComponent().lastPathComponent
        let head = TranscriptHeadReader.read(file)
        return assemble(
            uid: uid, file: file, slug: slug, harness: .claude,
            cwd: head.cwd, gitBranch: head.gitBranch,
            remotesByRepo: remotesByRepo, knownRepoNames: knownRepoNames, ledger: ledger)
    }

    /// Reconstruct one Codex rollout: cwd/uid come from the first `session_meta`
    /// line (nested under `payload`), so the head is read with a tiny line budget
    /// — Codex never fills `gitBranch`, so the general reader would otherwise scan
    /// to its cap. The uid is the rollout's own `payload.id`, falling back to the
    /// UUID embedded in the `rollout-<ts>-<uuid>` filename.
    func reconstructCodex(
        file: URL, remotesByRepo: [String: RepoRemote],
        knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        let head = TranscriptHeadReader.read(file, maxLines: 4)
        let uid = head.sessionID ?? Self.codexUID(fromFilename: file)
        guard let uid, !uid.isEmpty else { return nil }
        return assemble(
            uid: uid, file: file, slug: file.deletingPathExtension().lastPathComponent,
            harness: .codex, cwd: head.cwd, gitBranch: head.gitBranch,
            remotesByRepo: remotesByRepo, knownRepoNames: knownRepoNames, ledger: ledger)
    }

    /// Reconstruct one Grok Build transcript (CROW-1098). Unlike Codex, nothing is
    /// read from the file: the session UUID is the transcript's parent directory,
    /// and the `cwd` is its **grandparent** directory name URL-decoded — Grok stores
    /// each session at `<sessions>/<url-encoded-cwd>/<session-uuid>/chat_history.jsonl`,
    /// so the directory name is the authoritative cwd (`GrokSessionDir.decode`).
    /// Grok records no git branch, so `gitBranch` stays `nil`; the ticket comes from
    /// the worktree name the cwd resolves to, exactly like Claude.
    func reconstructGrok(
        file: URL, remotesByRepo: [String: RepoRemote],
        knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        let sessionDir = file.deletingLastPathComponent()
        let uid = sessionDir.lastPathComponent
        guard !uid.isEmpty else { return nil }
        let encodedCwd = sessionDir.deletingLastPathComponent().lastPathComponent
        let cwd = GrokSessionDir.decode(encodedCwd)
        return assemble(
            uid: uid, file: file, slug: encodedCwd, harness: .grok,
            cwd: cwd, gitBranch: nil,
            remotesByRepo: remotesByRepo, knownRepoNames: knownRepoNames, ledger: ledger)
    }

    /// Shared reconstruction: given a harness's already-extracted
    /// `(uid, cwd, gitBranch)`, fill in the workspace/repo/ticket the same way for
    /// every harness (the derivation is pure `cwd`/branch math — see
    /// `BackfillReconstructor`).
    func assemble(
        uid: String, file: URL, slug: String, harness: LogSyncHarness,
        cwd: String?, gitBranch: String?,
        remotesByRepo: [String: RepoRemote], knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0

        var session = BackfillSession(
            claudeSessionUID: uid, filePath: file.path, slug: slug, harness: harness,
            cwd: cwd, gitBranch: gitBranch, modifiedAt: mtime, sizeBytes: size)

        if let cwd {
            session.workspace = BackfillReconstructor.workspace(cwd: cwd, devRoot: devRoot)
            session.worktreeName = BackfillReconstructor.worktreeName(cwd: cwd, devRoot: devRoot)
            session.worktreeExists = FileManager.default.fileExists(atPath: cwd)
        }

        if let worktree = session.worktreeName {
            let (repo, ticket) = BackfillReconstructor.parseWorktree(worktree, knownRepoNames: knownRepoNames)
            session.repoName = repo
            // Prefer the worktree-parsed ticket; fall back to the branch.
            session.ticketNumber = ticket
                ?? session.gitBranch.flatMap { BackfillReconstructor.ticketNumber(fromBranch: $0) }
            if let repo, let remote = remotesByRepo[repo] {
                session.ownerRepo = remote.slug
                session.host = remote.host
            }
        } else if session.repoName == nil, let branch = session.gitBranch {
            // No worktree component (cwd is a bare clone) — the branch may still
            // carry a ticket number, but without a repo it stays medium/low.
            session.ticketNumber = BackfillReconstructor.ticketNumber(fromBranch: branch)
        }

        session.confidence = BackfillReconstructor.confidence(
            workspace: session.workspace, repoName: session.repoName, ticket: session.ticketNumber)
        session.uploadStatus = Self.status(
            for: uid, harness: harness, ledger: ledger, now: now().timeIntervalSince1970)
        return session
    }

    /// The UUID embedded in a Codex `rollout-<ISO-timestamp>-<uuid>.jsonl`
    /// filename — the last five hyphen-separated groups (a v7 UUID). Used only
    /// when the head could not be read; the `payload.id` is preferred.
    static func codexUID(fromFilename file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("rollout-") else { return nil }
        let groups = stem.split(separator: "-")
        guard groups.count >= 5 else { return nil }
        let uuid = groups.suffix(5).joined(separator: "-")
        return uuid.isEmpty ? nil : uuid
    }

    /// Map a ledger entry (keyed on the session UID + its harness) to the row's
    /// display status.
    static func status(
        for uid: String, harness: LogSyncHarness, ledger: LogSyncLedger, now: Double
    ) -> BackfillUploadStatus {
        let key = LogSyncLedger.key(sessionUID: uid, harness: harness, kind: .sessionTranscript)
        guard let entry = ledger.entries[key] else { return .new }
        switch entry.status {
        case .uploaded: return .uploaded
        case .skippedPermanent: return .skipped
        case .failedTransient: return .failed
        }
    }

    // MARK: - Enumeration & git

    /// Top-level `<slug>/<uuid>.jsonl` transcripts only — the same non-recursive
    /// shape the live collector's Claude `logSources` uses, so nested
    /// `subagents/agent-*.jsonl` are excluded (they belong to a parent session,
    /// not their own).
    func transcriptFiles() -> [URL] {
        let fm = FileManager.default
        guard let slugDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [URL] = []
        for dir in slugDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    out.append(f)
                }
            }
        }
        return out
    }

    /// Every `rollout-*.jsonl` under `~/.codex/sessions` (recursively, across the
    /// `<YYYY>/<MM>/<DD>` date tree). `~/.codex/archived_sessions` and `.../log`
    /// are siblings of this directory, so they are naturally excluded.
    func codexRolloutFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: codexSessionsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl"
            && url.lastPathComponent.hasPrefix("rollout-") {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }

    /// Every `chat_history.jsonl` under `<grokSessionsDir>` (recursively). Grok
    /// nests them two levels deep — `<url-encoded-cwd>/<session-uuid>/chat_history.jsonl`
    /// — so the enumerator descends into both; the `chat_history` prefix filter
    /// leaves out the cwd-level `prompt_history.jsonl` and the per-session
    /// `events.jsonl` / `hunk_records.jsonl`, keeping this in lockstep with the live
    /// collector's `logSources` selector (CROW-1098).
    func grokChatHistoryFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: grokSessionsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl"
            && url.lastPathComponent.hasPrefix("chat_history") {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }

    /// Build a `repoName → RepoRemote` map from the live clones under the dev
    /// root (`{devRoot}/{workspace}/{repoOrWorktree}`), reading each one's
    /// `origin`. One resolvable clone (main checkout or a still-present worktree)
    /// is enough to give every reaped worktree of the same repo its `owner/repo`.
    /// Remotes are read concurrently and deduped by parsed repo name.
    func resolveRemotes() async -> [String: RepoRemote] {
        let fm = FileManager.default
        var candidates: [String] = []
        guard let workspaces = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: devRoot), includingPropertiesForKeys: [.isDirectoryKey]) else { return [:] }
        for ws in workspaces {
            guard (try? ws.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let repos = try? fm.contentsOfDirectory(
                at: ws, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for repo in repos where (try? repo.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let gitPath = repo.appendingPathComponent(".git")
                if fm.fileExists(atPath: gitPath.path) { candidates.append(repo.path) }
            }
        }

        let results = await withTaskGroup(of: RepoRemote?.self) { group -> [RepoRemote] in
            for path in candidates {
                group.addTask { await gitRemote(path).flatMap { RepoRemote.parse($0) } }
            }
            var acc: [RepoRemote] = []
            for await r in group { if let r { acc.append(r) } }
            return acc
        }

        var map: [String: RepoRemote] = [:]
        for remote in results where map[remote.repo] == nil { map[remote.repo] = remote }
        return map
    }
}

/// Aggregate counts for the Settings dialog's summary line (CROW-1075).
public struct BackfillSummary: Sendable, Equatable, Codable {
    public var total: Int
    public var uploaded: Int
    public var linkable: Int   // high confidence (repo + ticket)
    public var repoOnly: Int   // medium
    public var orphan: Int     // low

    public init(total: Int = 0, uploaded: Int = 0, linkable: Int = 0, repoOnly: Int = 0, orphan: Int = 0) {
        self.total = total
        self.uploaded = uploaded
        self.linkable = linkable
        self.repoOnly = repoOnly
        self.orphan = orphan
    }

    public init(sessions: [BackfillSession]) {
        self.init(
            total: sessions.count,
            uploaded: sessions.filter { $0.uploadStatus == .uploaded }.count,
            linkable: sessions.filter { $0.confidence == .high }.count,
            repoOnly: sessions.filter { $0.confidence == .medium }.count,
            orphan: sessions.filter { $0.confidence == .low }.count)
    }
}
