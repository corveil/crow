import Foundation

/// Reads Claude Code's `~/.claude.json` MCP server map so harness writers
/// (Cursor, OpenCode, Grok, Antigravity, Muse, Codex) share one parse of the
/// source config (CROW-1214).
///
/// Destination translation, atomic 0600 writes, merge-preserve, and
/// managed-marker/sidecar rules stay in each harness package. This type only
/// answers: what did Claude declare, and can we trust the read?
///
/// **Lookup.** User-scope `mcpServers` wins. When `includeProjectScope` is
/// true (the default — Claude's `mcp add` writes local scope under
/// `projects[<path>].mcpServers`), the first project-scoped hit in **sorted**
/// path order is returned so which server wins is deterministic. Codex passes
/// `false` to keep its documented root-only narrowing in one place rather
/// than an implicit fork of the walk.
///
/// **Outcomes.** Missing/unreadable, unparseable, and parsed-but-absent are
/// distinct so callers keep today's fail-open vs fail-closed behavior (a
/// torn read of the live 2 MB file must not look like "the user removed jira"
/// and reap a valid bridged copy).
public enum ClaudeMCPSource {

    /// The server key every Jira bridge looks up — matches the `jira_*` tools
    /// the launch prompts reference.
    public static let jiraKey = "jira"

    /// Default source path: `~/.claude.json`. Tests inject a fixture path
    /// instead; never read the live file from a unit suite (ADR 0012).
    public static func defaultPath(fileManager: FileManager = .default) -> String {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json").path
    }

    /// Where a server definition was found.
    public enum Origin: Equatable, Sendable {
        /// Root `mcpServers` (Claude's `-s user` / user scope).
        case user
        /// `projects[<path>].mcpServers` (Claude's default local scope).
        case project(path: String)
    }

    /// Parsed `mcpServers` from both scopes. Values that aren't JSON objects
    /// are dropped so callers always receive a dictionary they can translate.
    public struct Snapshot {
        /// Root `mcpServers`, keyed by server name. Empty when the key is absent.
        public let userServers: [String: [String: Any]]
        /// `projects[<path>].mcpServers` in sorted-path order. A project whose
        /// value isn't an object, or that has no `mcpServers` object, is omitted.
        public let projectServers: [(path: String, servers: [String: [String: Any]])]

        /// User-scope `name` first; else the first project-scoped hit in sorted
        /// path order. `includeProjectScope: false` is Codex's root-only gate.
        public func server(
            named name: String,
            includeProjectScope: Bool = true
        ) -> (entry: [String: Any], origin: Origin)? {
            if let entry = userServers[name] {
                return (entry, .user)
            }
            guard includeProjectScope else { return nil }
            for (path, servers) in projectServers {
                if let entry = servers[name] {
                    return (entry, .project(path: path))
                }
            }
            return nil
        }

        /// Every named server the caller should consider, user-scope first
        /// (sorted names). When `includeProjectScope` is true, each project in
        /// sorted-path order contributes names not already taken — user wins,
        /// then earlier projects.
        public func servers(includeProjectScope: Bool = true) -> [(name: String, entry: [String: Any], origin: Origin)] {
            var seen = Set<String>()
            var out: [(name: String, entry: [String: Any], origin: Origin)] = []
            for name in userServers.keys.sorted() {
                guard let entry = userServers[name] else { continue }
                seen.insert(name)
                out.append((name, entry, .user))
            }
            guard includeProjectScope else { return out }
            for (path, servers) in projectServers {
                for name in servers.keys.sorted() {
                    guard !seen.contains(name), let entry = servers[name] else { continue }
                    seen.insert(name)
                    out.append((name, entry, .project(path: path)))
                }
            }
            return out
        }
    }

    /// Result of reading the Claude config file.
    public enum LoadResult {
        /// File parsed as a JSON object.
        case parsed(Snapshot)
        /// Path does not exist, or exists but could not be read.
        case sourceUnavailable
        /// File was read but is not a JSON object (truncated, JSONC, array).
        case unparseable
    }

    /// Result of looking up one named server (typically `jira`).
    public enum Lookup {
        /// Found a definition at `origin`.
        case found([String: Any], origin: Origin)
        /// File parsed cleanly but declares no such server in the requested scopes.
        case absent
        /// Missing or unreadable — do not treat as "user removed it".
        case sourceUnavailable
        /// Exists but isn't a JSON object.
        case unparseable
    }

    /// Read `path` (default `~/.claude.json`) into a snapshot.
    public static func load(
        from path: String? = nil,
        fileManager: FileManager = .default
    ) -> LoadResult {
        let resolved = path ?? defaultPath(fileManager: fileManager)
        guard let data = fileManager.contents(atPath: resolved) else {
            return .sourceUnavailable
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        return .parsed(Snapshot(
            userServers: objectMap(root["mcpServers"]),
            projectServers: projectServers(from: root)))
    }

    /// Look up one named server. User scope wins; else the first project-scoped
    /// hit in sorted-path order when `includeProjectScope` is true.
    public static func lookup(
        server name: String = jiraKey,
        includeProjectScope: Bool = true,
        from path: String? = nil,
        fileManager: FileManager = .default
    ) -> Lookup {
        switch load(from: path, fileManager: fileManager) {
        case .sourceUnavailable:
            return .sourceUnavailable
        case .unparseable:
            return .unparseable
        case .parsed(let snapshot):
            if let hit = snapshot.server(named: name, includeProjectScope: includeProjectScope) {
                return .found(hit.entry, origin: hit.origin)
            }
            return .absent
        }
    }

    /// Convenience for the Jira bridges — `lookup(server: "jira", …)`.
    public static func lookupJira(
        includeProjectScope: Bool = true,
        from path: String? = nil,
        fileManager: FileManager = .default
    ) -> Lookup {
        lookup(
            server: jiraKey,
            includeProjectScope: includeProjectScope,
            from: path,
            fileManager: fileManager)
    }

    // MARK: - Parse

    private static func objectMap(_ value: Any?) -> [String: [String: Any]] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (key, val) in dict {
            if let obj = val as? [String: Any] {
                out[key] = obj
            }
        }
        return out
    }

    private static func projectServers(
        from root: [String: Any]
    ) -> [(path: String, servers: [String: [String: Any]])] {
        guard let projects = root["projects"] as? [String: Any] else { return [] }
        return projects.keys.sorted().compactMap { path in
            guard let project = projects[path] as? [String: Any] else { return nil }
            let servers = objectMap(project["mcpServers"])
            guard !servers.isEmpty else { return nil }
            return (path, servers)
        }
    }
}
