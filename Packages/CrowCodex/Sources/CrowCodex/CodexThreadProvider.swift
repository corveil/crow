import Foundation
import CrowCore

/// Which Codex `model_provider` a stored thread was recorded under, and which
/// one a launch will use, so a Manager never resumes by id across providers
/// (CROW-1409, ADR 0030 correction).
///
/// Codex 0.166's TUI refuses a by-id resume when the provider differs:
///
/// ```
/// Error: Failed to resume session from …/rollout-…-<id>.jsonl: thread/resume
/// failed: This chat uses corveil, but your current provider is crow-corveil.
/// … {"type":"modelProviderMismatch",…}
/// ```
///
/// and the pane drops to a shell. Since CROW-1407 the provider depends on the
/// gateway's `codexUpstream` (routed launches use `crow-corveil`), so the same
/// stored id can stop resuming when routing is toggled, or when the operator
/// started the thread by hand with their own config.
///
/// The recorded provider is read from the rollout on disk
/// (`session_meta.payload.model_provider`, first line of
/// `<codexHome>/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`) rather than
/// stored next to `harnessConversationID`. The rollout is what Codex itself
/// checks, it covers every id Crow captured before this field existed, and it
/// can't drift from a copy in `store.json`. When the rollout is missing or
/// unreadable the provider is **unknown**, which is treated as a mismatch: a
/// by-id resume of a thread Codex can't find (or can't match) errors the same
/// way, and a fresh TUI is the recoverable outcome.
///
/// Codex 0.167.0 (openai/codex#58202) no longer errors here. It opens the
/// thread as read-only history with a `🔒` notice ("Continue in a new chat",
/// or "Model provider unavailable" when the recorded provider isn't configured
/// at all) that waits for `c` / `n` / `Esc`. The gate still applies on 0.167:
/// a fresh TUI is a cleaner launch than a recovery screen. If the gate's guess
/// is wrong, `CodexStartupPromptWatcher` answers the notice with `n` (start
/// fresh), so the outcome is the same either way.
///
/// `resume --last` (`.work` / `.job` / `.review`) is not gated here. Through
/// 0.166 it was provider-filtered: it skipped another provider's thread and
/// opened a fresh TUI (verified in a pty against a scratch `CODEX_HOME`,
/// 2026-11-05). From 0.167.0 it finds the cwd's newest thread whatever its
/// provider, and a mismatch opens the same read-only notice (reproduced on
/// 0.167.1, 2026-11-11, CROW-1425). Crow doesn't predict which thread `--last`
/// will pick. The pane watch answers the notice with `n`, which gives the
/// 0.166 outcome, a fresh TUI (`CodexStartupNotices`, screen 3). One
/// difference remains: 0.166 could fall back to an older same-provider thread
/// in that cwd, and 0.167 starts fresh instead.
public enum CodexThreadProvider {
    /// Codex's built-in provider id, used when `config.toml` names none.
    /// Rollouts recorded without a `model_provider` override carry `"openai"`.
    public static let defaultProviderID = "openai"

    /// The provider a launch uses: Crow's per-run `crow-corveil` when the launch
    /// is routed (`-c model_provider=crow-corveil`), else whatever the user's
    /// config selects.
    public static func launchProvider(
        route: CodexGatewayArgs.Route?, configured: () -> String
    ) -> String {
        route == nil ? configured() : CodexGatewayArgs.providerID
    }

    // MARK: Recorded provider (rollout)

    /// The `model_provider` the thread `conversationID` was recorded under, or
    /// nil when its rollout isn't on disk or its first line carries none.
    public static func recordedProvider(
        conversationID: String, sessionsDir: String = CodexHome.sessionsDir()
    ) -> String? {
        guard let path = CodexRollout.path(conversationID: conversationID, sessionsDir: sessionsDir),
              let line = CodexRollout.firstLine(atPath: path)
        else { return nil }
        return provider(fromSessionMetaLine: line)
    }

    /// `payload.model_provider` from a rollout's `session_meta` line.
    static func provider(fromSessionMetaLine line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let provider = (payload["model_provider"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty
        else { return nil }
        return provider
    }

    // MARK: Configured provider (config.toml)

    /// The provider an unrouted launch uses: `config.toml`'s top-level
    /// `model_provider`, overridden by the active `profile`'s, else
    /// ``defaultProviderID``. Crow passes no `--profile` and no
    /// `-c model_provider` on an unrouted launch, so this is what Codex picks.
    public static func configuredProvider(codexHome: String = CodexHome.path()) -> String {
        let path = (codexHome as NSString).appendingPathComponent("config.toml")
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return defaultProviderID }
        return configuredProvider(configTOML: text)
    }

    /// A deliberately small reader for the three keys that decide the provider:
    /// top-level `model_provider` and `profile`, and `[profiles.<name>]
    /// model_provider`. Anything it can't read falls back to the top level, then
    /// ``defaultProviderID``. A wrong answer here costs at most one fresh TUI
    /// (or the pre-CROW-1409 error), never a wrong thread.
    static func configuredProvider(configTOML text: String) -> String {
        var table: String? = nil   // nil = root table
        var topProvider: String?
        var profile: String?
        var profileProviders: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                table = tableName(line)
                continue
            }
            guard let (key, value) = keyValue(line) else { continue }
            if table == nil {
                if key == "model_provider" { topProvider = value }
                if key == "profile" { profile = value }
            } else if let table, key == "model_provider",
                      let name = profileName(table) {
                profileProviders[name] = value
            }
        }
        if let profile, let fromProfile = profileProviders[profile] { return fromProfile }
        return topProvider ?? defaultProviderID
    }

    /// `[a.b]` → `a.b`; `[[array]]` → a name that never matches a profile.
    private static func tableName(_ line: String) -> String {
        var s = Substring(line)
        while s.hasPrefix("[") { s = s.dropFirst() }
        if let close = s.firstIndex(of: "]") { s = s[..<close] }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `profiles.<name>` / `profiles."<name>"` → `<name>`.
    private static func profileName(_ table: String) -> String? {
        guard table.hasPrefix("profiles.") else { return nil }
        let rest = table.dropFirst("profiles.".count).trimmingCharacters(in: .whitespaces)
        return unquote(rest)
    }

    /// `key = "value"` / `key = 'value'` / `key = value`, with a trailing
    /// comment after an unquoted value dropped.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            value = String(body[..<end])
        } else if let hash = value.firstIndex(of: "#") {
            value = value[..<hash].trimmingCharacters(in: .whitespaces)
        }
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (unquote(key) ?? key, value)
    }

    private static func unquote(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// Lookups ``OpenAICodexAgent`` uses to decide a Manager's by-id resume.
/// Injectable so tests never read the real `~/.codex`.
public struct CodexThreadProviders: Sendable {
    /// Conversation id → the provider its rollout was recorded under, or nil
    /// when unknown (no rollout on disk, or no `model_provider` in it).
    public var recorded: @Sendable (String) -> String?
    /// The provider an unrouted launch uses (`config.toml`, else `openai`).
    public var configured: @Sendable () -> String

    public init(
        recorded: @escaping @Sendable (String) -> String?,
        configured: @escaping @Sendable () -> String
    ) {
        self.recorded = recorded
        self.configured = configured
    }

    /// Reads `$CODEX_HOME` (else `~/.codex`) at call time.
    public static let live = CodexThreadProviders(
        recorded: { CodexThreadProvider.recordedProvider(conversationID: $0) },
        configured: { CodexThreadProvider.configuredProvider() })
}

/// Locating and reading Codex rollout files.
public enum CodexRollout {
    /// The newest `rollout-<ts>-<id>.jsonl` for `conversationID` under
    /// `sessionsDir/YYYY/MM/DD/`, walking days newest-first, or nil.
    public static func path(conversationID: String, sessionsDir: String) -> String? {
        guard let id = HarnessConversationID.sanitize(conversationID),
              !id.contains("/"), !id.contains("\\"), !id.contains("..")
        else { return nil }
        let wanted = id.lowercased()
        let fm = FileManager.default
        for year in subdirectories(of: sessionsDir) {
            for month in subdirectories(of: year) {
                for day in subdirectories(of: month) {
                    guard let files = try? fm.contentsOfDirectory(atPath: day) else { continue }
                    let matches = files.filter { name in
                        // `rollout-<ts>-<uuid>.jsonl`: the uuid is the last five
                        // hyphen groups of the stem (`BackfillScanner.codexUID`).
                        guard name.lowercased().hasPrefix("rollout-"),
                              name.hasSuffix(".jsonl") else { return false }
                        let stem = String(name.dropLast(".jsonl".count))
                        let groups = stem.split(separator: "-")
                        guard groups.count >= 5 else { return false }
                        return groups.suffix(5).joined(separator: "-").lowercased() == wanted
                    }
                    guard let name = matches.max() else { continue }
                    let file = (day as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: file, isDirectory: &isDir), !isDir.boolValue {
                        return file
                    }
                }
            }
        }
        return nil
    }

    /// The first line of `path`, read in chunks and capped at `limit` bytes.
    /// `session_meta` embeds Codex's base instructions, so it runs ~20 KB.
    public static func firstLine(atPath path: String, limit: Int = 1 << 20) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < limit {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return buffer
            }
            buffer.append(chunk)
        }
        return buffer.isEmpty || buffer.count >= limit ? nil : buffer
    }

    /// Subdirectories of `path`, sorted newest-first (ISO date names sort
    /// lexicographically).
    private static func subdirectories(of path: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.sorted(by: >).compactMap { name in
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue ? full : nil
        }
    }
}
