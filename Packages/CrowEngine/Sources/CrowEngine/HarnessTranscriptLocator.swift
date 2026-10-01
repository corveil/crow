import Foundation
import CrowAntigravity
import CrowCodex
import CrowCore
import CrowCursor
import CrowGrok
import CrowMuse

/// Resolves a prior agent's `harnessConversationID` to one on-disk transcript
/// file, using the same path formulas LogSync and `BackfillScanner` already
/// use (CROW-1314).
///
/// This is a pointer, not a transcript copy (ADR 0011). OpenCode is omitted:
/// its log is one shared `opencode.db`, not this conversation's file. A miss
/// returns nil so the handoff brief can fall back to the pane's scrollback.
enum HarnessTranscriptLocator {
    struct Roots: Sendable {
        var claudeProjectsDir: String
        var grokSessionsDir: String
        var codexSessionsDir: String
        var cursorChatsDir: String
        var antigravityBrainDir: String
        var museSessionsDir: String

        static var live: Roots {
            Roots(
                claudeProjectsDir: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/projects", isDirectory: true).path,
                grokSessionsDir: GrokHome.sessionsDir(),
                codexSessionsDir: CodexHome.sessionsDir(),
                cursorChatsDir: CursorHome.chatsDir(),
                antigravityBrainDir: AntigravityHome.brainDir(),
                museSessionsDir: MuseHome.sessionsDir()
            )
        }
    }

    static func path(
        kind: AgentKind,
        conversationID: String?,
        cwd: String,
        roots: Roots = .live
    ) -> String? {
        guard let id = safeComponent(conversationID) else { return nil }
        if kind == .claudeCode {
            return claudeFile(id: id, cwd: cwd, projectsDir: roots.claudeProjectsDir)
        }
        if kind == .grok {
            return grokFile(id: id, cwd: cwd, sessionsDir: roots.grokSessionsDir)
        }
        if kind == .antigravity {
            return regularFile(AntigravityHome.transcriptPath(
                conversationID: id, brainDir: roots.antigravityBrainDir))
        }
        if kind == .cursor {
            return cursorStore(id: id, chatsDir: roots.cursorChatsDir)
        }
        if kind == .codex {
            return codexRollout(id: id, sessionsDir: roots.codexSessionsDir)
        }
        if kind == .muse {
            return museJournal(id: id, sessionsDir: roots.museSessionsDir)
        }
        // OpenCode's database is shared across every session. Pointing at it
        // would not show where *this* agent left off.
        return nil
    }

    /// A single path component: no separators, no `..`, no control characters.
    /// Rejects values that would escape the harness's log root.
    private static func safeComponent(_ raw: String?) -> String? {
        guard let id = HarnessConversationID.sanitize(raw) else { return nil }
        if id.count > 200 { return nil }
        if id == "." || id == ".." { return nil }
        if id.contains("/") || id.contains("\\") || id.contains("..") { return nil }
        return id
    }

    private static func claudeFile(id: String, cwd: String, projectsDir: String) -> String? {
        let slug = AgentLogSource.posixPathSlug(cwd)
        guard !slug.isEmpty else { return nil }
        let dir = (projectsDir as NSString).appendingPathComponent(slug)
        let file = (dir as NSString).appendingPathComponent("\(id).jsonl")
        return regularFile(file)
    }

    /// `<sessions>/<url-encoded-cwd>/<uuid>/chat_history.jsonl`.
    private static func grokFile(id: String, cwd: String, sessionsDir: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = GrokSessionDir.encode(trimmed)
        var dir = (sessionsDir as NSString).appendingPathComponent(encoded)
        dir = (dir as NSString).appendingPathComponent(id)
        let file = (dir as NSString).appendingPathComponent("chat_history.jsonl")
        return regularFile(file)
    }

    /// `<chats>/<chatId>/<subId>/store.db`. The hook id is the chat id
    /// (`cursor-agent --resume`), so the search stays inside that one directory.
    private static func cursorStore(id: String, chatsDir: String) -> String? {
        let chat = (chatsDir as NSString).appendingPathComponent(id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: chat, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let root = URL(fileURLWithPath: chat, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return nil }
        var best: (path: String, date: Date)?
        for child in children {
            let store = child.appendingPathComponent("store.db")
            guard let path = regularFile(store.path) else { continue }
            let date = (try? store.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || date > best!.date {
                best = (path, date)
            }
        }
        return best?.path
    }

    /// `sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl`. Days are walked
    /// newest-first so a live handoff stops at the recent file.
    private static func codexRollout(id: String, sessionsDir: String) -> String? {
        let wanted = id.lowercased()
        return walkDateTree(sessionsDir) { day in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return nil }
            let matches = files.filter { url in
                // Same UUID-from-filename rule as `BackfillScanner.codexUID`:
                // the last five hyphen groups of `rollout-<ts>-<uuid>`.
                let stem = url.deletingPathExtension().lastPathComponent
                guard stem.lowercased().hasPrefix("rollout-") else { return false }
                let groups = stem.split(separator: "-")
                guard groups.count >= 5 else { return false }
                return groups.suffix(5).joined(separator: "-").lowercased() == wanted
            }
            guard let file = matches.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
                return nil
            }
            return regularFile(file.path)
        }
    }

    /// `sessions/<YYYY>/<MM>/<DD>/<id>/session.jsonl`.
    private static func museJournal(id: String, sessionsDir: String) -> String? {
        walkDateTree(sessionsDir) { day in
            let file = day.appendingPathComponent(id).appendingPathComponent("session.jsonl")
            return regularFile(file.path)
        }
    }

    /// Visit `<root>/<YYYY>/<MM>/<DD>` newest-first (ISO date names sort
    /// lexicographically). Returns the first day `visit` resolves.
    private static func walkDateTree(_ root: String, visit: (URL) -> String?) -> String? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let years = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        for year in directories(years, descending: true) {
            guard let months = try? fm.contentsOfDirectory(
                at: year, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for month in directories(months, descending: true) {
                guard let days = try? fm.contentsOfDirectory(
                    at: month, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for day in directories(days, descending: true) {
                    if let hit = visit(day) { return hit }
                }
            }
        }
        return nil
    }

    private static func directories(_ urls: [URL], descending: Bool) -> [URL] {
        let dirs = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return dirs.sorted {
            descending
                ? $0.lastPathComponent > $1.lastPathComponent
                : $0.lastPathComponent < $1.lastPathComponent
        }
    }

    private static func regularFile(_ path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return path
    }
}
