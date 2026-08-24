import Foundation

/// The on-the-wire shape of a harness's durable session log, stamped onto the
/// uploaded artifact so the server-side derivation normalizer (corveil#2427)
/// knows how to read it. Matches the `format` column on `crow_session_artifacts`
/// (free text there; this enum is Crow's closed set).
public enum AgentLogFormat: String, Sendable, Codable, Equatable, CaseIterable {
    /// Newline-delimited JSON — one event per line. Claude Code writes exactly
    /// this (`~/.claude/projects/<slug>/<uuid>.jsonl`), so it needs no
    /// transformation before upload.
    case jsonl
    /// A SQLite database. The Cursor CLI (`cursor-agent`) stores each chat's
    /// conversation as content-addressed blobs inside a per-chat `store.db`
    /// (`~/.cursor/chats/<id>/<sub>/store.db`, tables `blobs`/`meta`). **Wired**
    /// (CROW-1095): `CursorStore` follows the `meta['0'].latestRootBlobId` root
    /// blob's ordered message-blob refs and emits each message's JSON as one NDJSON
    /// line; `TranscriptNormalizer` concatenates the resulting lines. The cwd for
    /// attribution comes from the sibling `meta.json`, not the transcript, so the
    /// collector reads it via `CursorStore.recordedCwd` rather than
    /// `AgentLogCwdReader`. Note this is the *CLI's* store, not the Cursor IDE's
    /// `state.vscdb`.
    case sqlite
    /// A directory (or set) of per-session log files the collector concatenates
    /// into one NDJSON artifact. Codex rollout files (`~/.codex/sessions/**/
    /// rollout-*.jsonl`) use this: each rollout is already newline-delimited JSON,
    /// so the concatenation needs no per-line transformation — only cwd-matching
    /// to attribute a globally-stored rollout to a worktree (see the `cwdFilter`
    /// field and `OpenAICodexAgent.logSources`).
    case logDir
    /// OpenCode's `opencode.db` SQLite store (`<dataDir>/opencode.db`). Unlike
    /// `.logDir`, a session is a set of rows across relational `session` / `message`
    /// / `part` tables that must be reassembled — and one database holds every
    /// session across every worktree, so attribution is by the `session.directory`
    /// column, not a per-file path. `OpenCodeStore` reads the database, selects the
    /// cwd-matched top-level sessions, and rebuilds an ordered NDJSON transcript from
    /// their `message`/`part` rows (CROW-1096).
    ///
    /// This value is an *internal normalization discriminator* only: because the
    /// selector is a cwd (live collector) or a session id (backfill), an OpenCode
    /// source is normalized through `OpenCodeStore` directly rather than the shared
    /// `TranscriptNormalizer.normalize(files:…)`. The reassembled artifact is NDJSON,
    /// so it is uploaded stamped as `.logDir` — see `artifactStamp`, which every
    /// upload path applies. The server's `format` column never sees `openCodeStore`.
    case openCodeStore
}

public extension AgentLogFormat {
    /// The value stamped onto the uploaded artifact's `format` column. Every format
    /// is itself except `.openCodeStore`, whose reassembled output is NDJSON and so
    /// is stamped `.logDir` — the server enumerates a small closed set and has no
    /// `openCodeStore` reader; the SQLite store is a Crow-internal concern that never
    /// leaves the collector (CROW-1096).
    var artifactStamp: AgentLogFormat { self == .openCodeStore ? .logDir : self }
}

/// Where a single coding-agent harness writes a durable session log on disk, and
/// in what format. Adapters return these from `CodingAgent.logSources(...)`; the
/// daemon's `LogSyncCollector` resolves them to concrete files, normalizes the
/// contents to NDJSON, and uploads them as session-transcript artifacts
/// (CROW-1056).
///
/// The adapter is a stateless value struct, so the session context it needs to
/// locate its logs (the worktree path, and optionally the harness's own session
/// id) is passed as arguments rather than read off `self` — the same reason
/// `autoLaunchCommand` takes a `Session`.
public struct AgentLogSource: Sendable, Equatable {
    /// Whether `path` names a single file or a directory to enumerate.
    public enum Selector: Sendable, Equatable {
        /// One concrete file — used when the exact per-session log path is known
        /// (e.g. Claude's `<uuid>.jsonl` when the harness session id is known).
        case file
        /// A directory whose (optionally extension-filtered) files all belong to
        /// this session — used when a harness writes one file per run into a
        /// per-worktree directory (e.g. Claude's project-slug directory).
        case directory
    }

    /// Absolute path to the file or directory. `~` is NOT expanded here — callers
    /// build absolute paths (adapters use `FileManager`/`NSHomeDirectory`).
    public let path: String
    /// Whether `path` is a file or a directory.
    public let selector: Selector
    /// The log's format, stamped onto the artifact.
    public let format: AgentLogFormat
    /// When `selector == .directory`, only files with this extension are
    /// collected (e.g. `"jsonl"`); `nil` collects every regular file. Ignored
    /// for `.file`.
    public let fileExtension: String?
    /// When `selector == .directory`, only files whose name begins with this
    /// prefix are collected (e.g. `"rollout-"` for Codex). `nil` accepts any
    /// name. Keeps the live collector and the backfill scanner in lockstep — both
    /// select a Codex rollout by the same `rollout-*.jsonl` shape, so a stray
    /// `.jsonl` that Codex might one day drop beside its rollouts can't slip into
    /// the live path even if it happened to carry a matching cwd (CROW-1089).
    public let fileNamePrefix: String?
    /// When `selector == .directory`, whether to descend into subdirectories.
    /// Defaults to `false` (Claude's slug directory is flat).
    public let recursive: Bool
    /// When set, keep only the resolved files whose *recorded* working directory
    /// equals this path — the attribution mechanism for a harness whose logs are
    /// **globally stored** rather than partitioned into a per-worktree directory.
    ///
    /// Claude needs no filter: its slug directory already contains exactly this
    /// worktree's transcripts, so `cwdFilter` is `nil`. Codex is the opposite —
    /// its rollouts pool under `~/.codex/sessions/<date>/…` regardless of cwd, so
    /// the collector must read each candidate's head, extract the `cwd` it
    /// recorded (`AgentLogCwdReader`), and keep only exact matches. A file with no
    /// readable cwd is dropped, never guessed: an unattributable transcript is
    /// worse than a missing one (CROW-1089).
    public let cwdFilter: String?

    public init(
        path: String,
        selector: Selector,
        format: AgentLogFormat,
        fileExtension: String? = nil,
        fileNamePrefix: String? = nil,
        recursive: Bool = false,
        cwdFilter: String? = nil
    ) {
        self.path = path
        self.selector = selector
        self.format = format
        self.fileExtension = fileExtension
        self.fileNamePrefix = fileNamePrefix
        self.recursive = recursive
        self.cwdFilter = cwdFilter
    }

    /// A single-file source.
    public static func file(_ path: String, format: AgentLogFormat) -> AgentLogSource {
        AgentLogSource(path: path, selector: .file, format: format)
    }

    /// A directory source, optionally filtered by file extension / name prefix
    /// and — for a globally-stored harness — by the working directory each file
    /// recorded (`cwdFilter`).
    public static func directory(
        _ path: String,
        format: AgentLogFormat,
        fileExtension: String? = nil,
        fileNamePrefix: String? = nil,
        recursive: Bool = false,
        cwdFilter: String? = nil
    ) -> AgentLogSource {
        AgentLogSource(
            path: path, selector: .directory, format: format,
            fileExtension: fileExtension, fileNamePrefix: fileNamePrefix,
            recursive: recursive, cwdFilter: cwdFilter)
    }

    /// Slugify a POSIX path the way Claude Code names its per-project log
    /// directory: every character that is not an ASCII letter or digit becomes
    /// `-`. So `/Users/j/Dev/acme-12` → `-Users-j-Dev-acme-12`.
    ///
    /// Verified against a live `~/.claude/projects` on macOS. Kept generic (not
    /// "Claude") because it is a pure path transform and is unit-tested here in
    /// CrowCore without importing the adapter.
    public static func posixPathSlug(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            let isDigit = scalar >= "0" && scalar <= "9"
            let isUpper = scalar >= "A" && scalar <= "Z"
            let isLower = scalar >= "a" && scalar <= "z"
            return (isDigit || isUpper || isLower) ? Character(scalar) : "-"
        })
    }
}
