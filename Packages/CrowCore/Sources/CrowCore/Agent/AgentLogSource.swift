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
    /// A SQLite database (Cursor stores chat rows inside a per-workspace
    /// `state.vscdb`). Requires row extraction before it becomes NDJSON — not
    /// yet wired (see `CursorAgent.logSources`).
    case sqlite
    /// A directory (or set) of per-session log files the collector concatenates
    /// into one NDJSON artifact (Codex rollout files, OpenCode storage).
    case logDir
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
    /// When `selector == .directory`, whether to descend into subdirectories.
    /// Defaults to `false` (Claude's slug directory is flat).
    public let recursive: Bool

    public init(
        path: String,
        selector: Selector,
        format: AgentLogFormat,
        fileExtension: String? = nil,
        recursive: Bool = false
    ) {
        self.path = path
        self.selector = selector
        self.format = format
        self.fileExtension = fileExtension
        self.recursive = recursive
    }

    /// A single-file source.
    public static func file(_ path: String, format: AgentLogFormat) -> AgentLogSource {
        AgentLogSource(path: path, selector: .file, format: format)
    }

    /// A directory source, optionally filtered by file extension.
    public static func directory(
        _ path: String,
        format: AgentLogFormat,
        fileExtension: String? = nil,
        recursive: Bool = false
    ) -> AgentLogSource {
        AgentLogSource(
            path: path, selector: .directory, format: format,
            fileExtension: fileExtension, recursive: recursive)
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
