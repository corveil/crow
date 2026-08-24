import Foundation

/// Reconciles the coding-session transcripts already on disk against what has
/// been uploaded, reconstructing each one's workspace / repo / ticket so the
/// Settings "Backfill history" dialog can show a reviewable list (CROW-1075).
///
/// Six harnesses are wired: **Claude** (CROW-1075), whose logs are partitioned
/// by working directory (`~/.claude/projects/<slug>/<uuid>.jsonl`); **Codex**
/// (CROW-1089), whose rollouts pool globally under `~/.codex/sessions/<date>/…`
/// but each record their own `cwd` in a first-line `session_meta` event; **Grok**
/// (CROW-1098), which partitions by working directory too, encoding the cwd into
/// the directory name (`~/.grok/sessions/<url-encoded-cwd>/<uuid>/chat_history.jsonl`);
/// **Cursor** (CROW-1095), whose per-chat `~/.cursor/chats/<id>/<sub>/store.db`
/// records its `cwd` in the sibling `meta.json`; **OpenCode** (CROW-1096), whose
/// sessions live in the `~/.local/share/opencode/opencode.db` SQLite store, each row
/// recording the `directory` it ran in (`session.directory`); and **Antigravity**
/// (CROW-1107), whose transcript records **no** cwd — its cwd is instead recovered
/// from the runtime conversation→worktree map the live collector builds. The first
/// five make historical reconstruction reliable because the real `cwd` is
/// recoverable — Claude/Codex record it in the transcript, Grok encodes it in the
/// path, Cursor in a sibling file, OpenCode in a column — the authoritative signal,
/// not a lossy directory name; Antigravity relies on the map (a conversation with no
/// map entry → `low`/orphan, never guessed). The scan is disk- and git-only — it
/// never touches the provider or the network, so it stays fast over hundreds of
/// sessions (it never opens a Cursor `store.db`; the Cursor uid is the `<sub>`
/// directory name and the cwd a tiny sibling JSON read); ticket *validation* is
/// deferred to upload, where a link is actually asserted.
///
/// Everything effectful is injected (the projects directory, the Codex sessions
/// directory, the Grok sessions directory, the Cursor chats directory, the OpenCode
/// database path, the Antigravity brain directory + its conversation map, the
/// git-remote reader, the clock), so the reconciliation logic is unit-testable
/// against a temporary tree.
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
    /// `~/.cursor/chats` by default — where the `cursor-agent` CLI writes each
    /// chat's `<chatId>/<subId>/store.db` + sibling `meta.json` (CROW-1095). The
    /// daemon injects the `$CURSOR_CONFIG_DIR`-resolved tree (via `CursorHome`,
    /// which CrowCore can't import); this literal default is the fallback for a
    /// direct caller.
    let cursorChatsDir: URL
    /// `~/.local/share/opencode/opencode.db` by default — the OpenCode SQLite store
    /// (CROW-1096). The daemon injects the `$XDG_DATA_HOME`-resolved path (via
    /// `OpenCodeHome`, which CrowCore can't import); this literal default is the
    /// fallback for a direct caller.
    let openCodeDatabaseURL: URL
    /// The Antigravity brain dir (`AntigravityHome.brainDir()` by default) — where
    /// `agy` pools each conversation's `.../logs/transcript_full.jsonl` (CROW-1107).
    let antigravityBrainDir: URL
    /// The runtime conversation→worktree map (`.load()` by default) — the only
    /// attribution Antigravity has, since its transcript records no cwd (CROW-1107,
    /// CROW-1097). A historical transcript whose conversation id isn't in the map
    /// reconstructs to `cwd == nil` ⇒ `low`/orphan (never guessed).
    let antigravityMap: AntigravityConversationMap
    /// Resolve a directory's `origin` remote URL (default: `git -C <dir> remote
    /// get-url origin`). Injected so tests need no real repos.
    let gitRemote: @Sendable (String) async -> String?
    let now: @Sendable () -> Date

    public init(
        devRoot: String,
        projectsDir: URL? = nil,
        codexSessionsDir: URL? = nil,
        grokSessionsDir: URL? = nil,
        cursorChatsDir: URL? = nil,
        openCodeDatabaseURL: URL? = nil,
        antigravityBrainDir: URL? = nil,
        antigravityMap: AntigravityConversationMap? = nil,
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
        self.cursorChatsDir = cursorChatsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/chats", isDirectory: true)
        self.openCodeDatabaseURL = openCodeDatabaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        self.antigravityBrainDir = antigravityBrainDir
            ?? URL(fileURLWithPath: AntigravityHome.brainDir(), isDirectory: true)
        self.antigravityMap = antigravityMap ?? AntigravityConversationMap.load()
        self.gitRemote = { dir in
            (try? await runner.run(args: ["git", "-C", dir, "remote", "get-url", "origin"],
                                   env: [:], cwd: nil))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.now = now
    }

    /// Test seam: inject the git-remote reader directly. `codexSessionsDir` /
    /// `grokSessionsDir` / `cursorChatsDir` / `openCodeDatabaseURL` /
    /// `antigravityBrainDir` default to nonexistent paths so a test that only stages
    /// Claude transcripts stays hermetic (it never accidentally scans a dev machine's
    /// real `~/.codex/sessions`, `~/.grok/sessions`, `~/.cursor/chats`,
    /// `~/.local/share/opencode/opencode.db`, or `~/.gemini/antigravity-cli/brain`);
    /// a Codex/Grok/Cursor/OpenCode/Antigravity test passes an explicit temp path.
    /// `antigravityMap` defaults to empty for the same reason.
    init(
        devRoot: String,
        projectsDir: URL,
        codexSessionsDir: URL? = nil,
        grokSessionsDir: URL? = nil,
        cursorChatsDir: URL? = nil,
        openCodeDatabaseURL: URL? = nil,
        antigravityBrainDir: URL? = nil,
        antigravityMap: AntigravityConversationMap = AntigravityConversationMap(),
        gitRemote: @escaping @Sendable (String) async -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.devRoot = devRoot
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
            ?? projectsDir.appendingPathComponent("__no_codex_sessions__", isDirectory: true)
        self.grokSessionsDir = grokSessionsDir
            ?? projectsDir.appendingPathComponent("__no_grok_sessions__", isDirectory: true)
        self.cursorChatsDir = cursorChatsDir
            ?? projectsDir.appendingPathComponent("__no_cursor_chats__", isDirectory: true)
        self.openCodeDatabaseURL = openCodeDatabaseURL
            ?? projectsDir.appendingPathComponent("__no_opencode_db__/opencode.db")
        self.antigravityBrainDir = antigravityBrainDir
            ?? projectsDir.appendingPathComponent("__no_antigravity_brain__", isDirectory: true)
        self.antigravityMap = antigravityMap
        self.gitRemote = gitRemote
        self.now = now
    }

    /// Reconcile every on-disk transcript (Claude + Codex + Grok + Cursor +
    /// OpenCode + Antigravity) against the ledger and return the reconstructed rows,
    /// newest first.
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
        for file in cursorStoreFiles() {
            guard let s = reconstructCursor(
                file: file, remotesByRepo: remotes,
                knownRepoNames: knownRepoNames, ledger: ledger)
            else { continue }
            sessions.append(s)
        }
        for session in openCodeSessions() {
            guard let s = reconstructOpenCode(
                session: session, remotesByRepo: remotes,
                knownRepoNames: knownRepoNames, ledger: ledger)
            else { continue }
            sessions.append(s)
        }
        for file in antigravityTranscriptFiles() {
            guard let s = reconstructAntigravity(
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

    /// Reconstruct one Cursor chat from its `store.db`. The scan never opens the
    /// database: the uid is the `<subId>` directory name (== `meta['0'].agentId`,
    /// verified) and the cwd is read from the tiny sibling `meta.json`
    /// (`CursorStore.recordedCwd`) — keeping the scan disk-only and fast even over
    /// hundreds of chats. Cursor records no git branch, so `gitBranch` stays `nil`;
    /// the message extraction is deferred to upload. A chat with no recoverable cwd
    /// is dropped, never guessed (CROW-1095).
    func reconstructCursor(
        file: URL, remotesByRepo: [String: RepoRemote],
        knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        let subID = file.deletingLastPathComponent().lastPathComponent
        guard !subID.isEmpty else { return nil }
        return assemble(
            uid: subID, file: file, slug: subID, harness: .cursor,
            cwd: CursorStore.recordedCwd(forStoreDB: file), gitBranch: nil,
            remotesByRepo: remotesByRepo, knownRepoNames: knownRepoNames, ledger: ledger)
    }

    /// Reconstruct one OpenCode session from its `opencode.db` row (CROW-1096). The
    /// cwd is the session's recorded `directory` and the uid is the session id;
    /// OpenCode records no git branch, so `gitBranch` is `nil` and the ticket is
    /// parsed from the worktree name alone. Child/subagent sessions (`parentID`) are
    /// skipped by the enumerator, so every row reaching here is top-level. The shared
    /// `filePath` is the database itself, and the row's own `time_updated` /
    /// `time_created` supplies the modified date (the whole-DB mtime would be wrong
    /// per session).
    func reconstructOpenCode(
        session: OpenCodeStoreSession, remotesByRepo: [String: RepoRemote],
        knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        guard !session.id.isEmpty else { return nil }
        let mtime = ((session.updatedMs ?? session.createdMs) ?? 0) / 1000
        return assemble(
            uid: session.id, file: openCodeDatabaseURL,
            slug: session.title ?? session.id,
            harness: .opencode, cwd: session.cwd, gitBranch: nil,
            remotesByRepo: remotesByRepo, knownRepoNames: knownRepoNames, ledger: ledger,
            mtimeOverride: mtime, sizeOverride: 0)
    }

    /// Reconstruct one Antigravity transcript (CROW-1107). The transcript records
    /// no cwd, so — unlike every other harness — the `cwd` is recovered not from
    /// the file or its path but from the **runtime conversation→worktree map** the
    /// live collector builds (`antigravityMap`): the conversation id is the brain
    /// sub-directory the file lives under (`brain/<id>/…`), and its map entry names
    /// the worktree Crow launched `agy` in. A conversation with no map entry — a
    /// session that predates the map, or one Crow never launched — reconstructs to
    /// `cwd == nil` ⇒ `low`/orphan via `assemble`, never guessed. `uid` is the
    /// conversation id; Antigravity records no git branch.
    func reconstructAntigravity(
        file: URL, remotesByRepo: [String: RepoRemote],
        knownRepoNames: [String], ledger: LogSyncLedger
    ) -> BackfillSession? {
        guard let conversationID = AntigravityHome.conversationID(forTranscript: file) else { return nil }
        let cwd = antigravityMap.conversations[conversationID]?.worktreePath
        return assemble(
            uid: conversationID, file: file, slug: conversationID, harness: .antigravity,
            cwd: cwd, gitBranch: nil,
            remotesByRepo: remotesByRepo, knownRepoNames: knownRepoNames, ledger: ledger)
    }

    /// Shared reconstruction: given a harness's already-extracted
    /// `(uid, cwd, gitBranch)`, fill in the workspace/repo/ticket the same way for
    /// every harness (the derivation is pure `cwd`/branch math — see
    /// `BackfillReconstructor`).
    ///
    /// `mtimeOverride` / `sizeOverride` let a harness whose sessions share one file
    /// (OpenCode's `opencode.db`) supply per-session values instead of the file's own
    /// mtime/size, which would be identical across every session in the database.
    func assemble(
        uid: String, file: URL, slug: String, harness: LogSyncHarness,
        cwd: String?, gitBranch: String?,
        remotesByRepo: [String: RepoRemote], knownRepoNames: [String], ledger: LogSyncLedger,
        mtimeOverride: Double? = nil, sizeOverride: Int? = nil
    ) -> BackfillSession? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = mtimeOverride ?? values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = sizeOverride ?? values?.fileSize ?? 0

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

    /// Every `store.db` under `~/.cursor/chats` (recursively across the
    /// `<chatId>/<subId>/` tree). The sibling `store.db-wal` / `store.db-shm` /
    /// `meta.json` / `prompt_history.json` are excluded by the exact `store.db`
    /// filename, so only the one database per chat is enumerated.
    func cursorStoreFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: cursorChatsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.lastPathComponent == "store.db" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }

    /// The OpenCode session rows in `opencode.db`, minus child/subagent sessions —
    /// the same set the live collector reassembles, so scan and collector agree
    /// (CROW-1096). Empty when the database is absent (e.g. no OpenCode installed, or
    /// on Linux where `OpenCodeStore` has no SQLite backing).
    func openCodeSessions() -> [OpenCodeStoreSession] {
        OpenCodeStore.sessions(databasePath: openCodeDatabaseURL.path).filter { !$0.isChild }
    }

    /// Every `transcript_full.jsonl` under `<antigravityBrainDir>` (recursively).
    /// Antigravity nests them as `<brain>/<conv-id>/.system_generated/logs/transcript_full.jsonl`,
    /// so the enumerator descends; the exact-name filter leaves out the truncated
    /// sibling `transcript.jsonl`, keeping this in lockstep with the live collector
    /// (which returns `transcript_full.jsonl` per map entry — CROW-1107).
    func antigravityTranscriptFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: antigravityBrainDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.lastPathComponent == "transcript_full.jsonl" {
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
