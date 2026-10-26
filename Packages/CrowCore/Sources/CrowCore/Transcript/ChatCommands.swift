import Foundation

/// One entry in the Chat view's `/` menu for a Claude Code session.
public struct ChatCommand: Sendable, Equatable {
    public enum Kind: String, Sendable { case skill, command, builtin }
    public enum Scope: String, Sendable { case project, user, plugin, builtin }

    public var name: String
    public var description: String
    public var kind: Kind
    public var scope: Scope

    public init(name: String, description: String, kind: Kind, scope: Scope) {
        self.name = name
        self.description = description
        self.kind = kind
        self.scope = scope
    }
}

/// Discovers what a Claude Code session can run as `/name`: skills
/// (`.claude/skills/<dir>/SKILL.md`), slash commands (`.claude/commands/*.md`),
/// enabled plugin skills, and the built-ins that make sense from chat.
///
/// Selecting an entry only inserts `/name ` into the composer; Claude Code
/// expands it on its side (verified on 2.1.309/310, both the TUI and
/// stream-json). Discovery is best-effort: an unreadable or malformed file is
/// skipped, never fatal.
public enum ChatCommandCatalog {
    public struct Roots: Sendable {
        /// The session's working directory (worktree, or the Manager's dir).
        public var projectDir: String?
        /// `~/.claude` (or `$CLAUDE_CONFIG_DIR`).
        public var userClaudeDir: String

        public init(projectDir: String?, userClaudeDir: String) {
            self.projectDir = projectDir
            self.userClaudeDir = userClaudeDir
        }

        public static func live(projectDir: String?) -> Roots {
            let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespaces)
            let dir = (env?.isEmpty == false) ? env! : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true).path
            return Roots(projectDir: projectDir, userClaudeDir: dir)
        }
    }

    /// Built-ins Claude Code accepts in both the TUI and `-p` stream-json mode.
    public static let builtins: [ChatCommand] = [
        ChatCommand(name: "compact", description: "Summarize the conversation to free up context", kind: .builtin, scope: .builtin),
        ChatCommand(name: "context", description: "Show what is using the context window", kind: .builtin, scope: .builtin),
        ChatCommand(name: "clear", description: "Start a new conversation", kind: .builtin, scope: .builtin),
    ]

    /// Project entries win over user entries, which win over plugin skills and
    /// built-ins; skills and commands share one namespace. Sorted by name.
    public static func discover(_ roots: Roots) -> [ChatCommand] {
        var byName: [String: ChatCommand] = [:]
        func add(_ cmds: [ChatCommand]) {
            for c in cmds where byName[c.name] == nil { byName[c.name] = c }
        }
        if let project = roots.projectDir {
            let claude = (project as NSString).appendingPathComponent(".claude")
            add(skills(in: (claude as NSString).appendingPathComponent("skills"), scope: .project))
            add(commands(in: (claude as NSString).appendingPathComponent("commands"), scope: .project))
        }
        add(skills(in: (roots.userClaudeDir as NSString).appendingPathComponent("skills"), scope: .user))
        add(commands(in: (roots.userClaudeDir as NSString).appendingPathComponent("commands"), scope: .user))
        add(pluginSkills(userClaudeDir: roots.userClaudeDir, projectDir: roots.projectDir))
        add(builtins)
        return byName.values.sorted { $0.name < $1.name }
    }

    // MARK: - Skills and commands

    /// `<dir>/<name>/SKILL.md`. The folder name is the invocation name, as in
    /// Claude Code; `user-invocable: false` hides the skill from the menu.
    static func skills(in dir: String, scope: ChatCommand.Scope, prefix: String? = nil) -> [ChatCommand] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [ChatCommand] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let file = ((dir as NSString).appendingPathComponent(entry) as NSString)
                .appendingPathComponent("SKILL.md")
            guard let text = readSmall(file) else { continue }
            let fields = frontmatter(text)
            if let v = fields["user-invocable"], parseBool(v) == false { continue }
            guard let name = commandName(entry, prefix: prefix) else { continue }
            out.append(ChatCommand(
                name: name, description: fields["description"] ?? "", kind: .skill, scope: scope))
        }
        return out
    }

    /// `<dir>/<name>.md` (top level only).
    static func commands(in dir: String, scope: ChatCommand.Scope) -> [ChatCommand] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [ChatCommand] = []
        for entry in entries.sorted() where entry.hasSuffix(".md") && !entry.hasPrefix(".") {
            let file = (dir as NSString).appendingPathComponent(entry)
            guard let text = readSmall(file) else { continue }
            let fields = frontmatter(text)
            if let v = fields["user-invocable"], parseBool(v) == false { continue }
            guard let name = commandName(String(entry.dropLast(3)), prefix: nil) else { continue }
            var description = fields["description"] ?? ""
            if description.isEmpty {
                // Commands without frontmatter: Claude shows the first line.
                description = body(text).split(separator: "\n").first.map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
                } ?? ""
            }
            out.append(ChatCommand(
                name: name, description: String(description.prefix(200)), kind: .command, scope: scope))
        }
        return out
    }

    // MARK: - Plugins

    /// Skills of plugins that are installed and enabled (`enabledPlugins: true`
    /// in user or project settings), named `<plugin>:<skill>`. Covers the
    /// default `skills/` folder only; manifest-declared skill roots are skipped.
    static func pluginSkills(userClaudeDir: String, projectDir: String?) -> [ChatCommand] {
        let pluginsDir = (userClaudeDir as NSString).appendingPathComponent("plugins")
        guard let data = FileManager.default.contents(
                atPath: (pluginsDir as NSString).appendingPathComponent("installed_plugins.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = obj["plugins"] as? [String: Any] else { return [] }

        var enabled: [String: Bool] = [:]
        var settingsFiles = [(userClaudeDir as NSString).appendingPathComponent("settings.json")]
        if let projectDir {
            let claude = (projectDir as NSString).appendingPathComponent(".claude")
            settingsFiles.append((claude as NSString).appendingPathComponent("settings.json"))
            settingsFiles.append((claude as NSString).appendingPathComponent("settings.local.json"))
        }
        for file in settingsFiles {
            guard let d = FileManager.default.contents(atPath: file),
                  let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let map = s["enabledPlugins"] as? [String: Any] else { continue }
            for (key, value) in map {
                if let b = value as? Bool { enabled[key] = b } else { enabled[key] = nil }
            }
        }

        var out: [ChatCommand] = []
        for key in plugins.keys.sorted() where enabled[key] == true {
            guard let installs = plugins[key] as? [[String: Any]] else { continue }
            let applicable = installs.filter { rec in
                let scope = rec["scope"] as? String
                if scope == "user" || scope == "managed" { return true }
                guard let projectDir, let path = rec["projectPath"] as? String else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL
                    == URL(fileURLWithPath: projectDir).standardizedFileURL
            }
            guard let install = applicable.first(where: {
                ($0["installPath"] as? String).map { FileManager.default.fileExists(atPath: $0) } ?? false
            }), let installPath = install["installPath"] as? String else { continue }

            var prefix = String(key.split(separator: "@").first ?? Substring(key))
            let manifest = ((installPath as NSString).appendingPathComponent(".claude-plugin") as NSString)
                .appendingPathComponent("plugin.json")
            if let d = FileManager.default.contents(atPath: manifest),
               let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let name = m["name"] as? String, !name.isEmpty {
                prefix = name
            }
            out += skills(
                in: (installPath as NSString).appendingPathComponent("skills"),
                scope: .plugin, prefix: prefix)
        }
        return out
    }

    // MARK: - Parsing helpers

    /// A name Claude can invoke and the composer can insert as one token.
    static func commandName(_ raw: String, prefix: String?) -> String? {
        let base = raw.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard base.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        if let prefix { return "\(prefix):\(base)" }
        return base
    }

    /// Top-level `key: value` pairs of a `---` frontmatter block. Handles plain
    /// and quoted scalars plus `>` / `|` block scalars; nested YAML is ignored.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            i += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                var parts: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t")
                        || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    if lines[i].trimmingCharacters(in: .whitespaces) == "---" { break }
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = parts.filter { !$0.isEmpty }.joined(separator: " ")
            } else if value.count >= 2,
                      let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }

    /// YAML 1.1 spellings Claude Code accepts.
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "y", "1": return true
        case "false", "no", "off", "n", "0": return false
        default: return nil
        }
    }

    private static func body(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let rest = text.dropFirst(3)
        guard let end = rest.range(of: "\n---") else { return text }
        return String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Skill files are tiny; cap the read so a hostile repo can't hand us a
    /// gigabyte "SKILL.md".
    private static func readSmall(_ path: String, limit: Int = 64 * 1024) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: limit) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
