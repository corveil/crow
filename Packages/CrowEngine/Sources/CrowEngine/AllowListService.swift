import Foundation
import CrowCore

/// What a `promoteToGlobal` write actually did, so a caller — the
/// `promote-allowlist` RPC, and through it `crow promote-allowlist` — can report
/// the outcome instead of an unconditional `ok: true` (#819).
public struct AllowlistPromotion: Sendable, Equatable {
    /// Patterns newly appended to the global allow list.
    public let added: [String]
    /// Patterns that were already global — a no-op, not a failure.
    public let alreadyGlobal: [String]
    /// The file that was written, echoed so a script can point at it.
    public let globalSettingsPath: String

    public init(added: [String], alreadyGlobal: [String], globalSettingsPath: String) {
        self.added = added
        self.alreadyGlobal = alreadyGlobal
        self.globalSettingsPath = globalSettingsPath
    }
}

/// Failures that stop a promote before it can damage the global settings file.
public enum AllowlistPromoteError: Error, LocalizedError {
    /// The existing `settings.json` isn't valid JSON. Merging into `[:]` and
    /// writing back would drop every unrelated key, so we refuse instead.
    case malformedGlobalSettings(String)

    public var errorDescription: String? {
        switch self {
        case .malformedGlobalSettings(let path):
            "\(path) is not valid JSON — refusing to overwrite it. Fix or move the file and retry."
        }
    }
}

/// Scans worktree and global settings files to aggregate allow-list entries.
@MainActor
public final class AllowListService {
    private let appState: AppState
    private let devRoot: String
    /// Injectable so the promote path is testable without touching the real
    /// `$HOME` (and so the path has one owner instead of being recomputed in
    /// both `scan()` and `promoteToGlobal`).
    private let globalSettingsURL: URL

    public init(
        appState: AppState,
        devRoot: String,
        globalSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) {
        self.appState = appState
        self.devRoot = devRoot
        self.globalSettingsURL = globalSettingsURL
    }

    // MARK: - Scan

    /// Aggregate allow-list entries from global, workspace, and worktree settings.
    public func scan() {
        appState.isLoadingAllowList = true
        var aggregated: [String: Set<AllowSource>] = [:]

        // 1. Global: ~/.claude/settings.json
        for pattern in readAllowList(at: globalSettingsURL.path) {
            aggregated[pattern, default: []].insert(.global)
        }

        // 2. Per-worktree: {worktreePath}/.claude/settings.local.json
        let sessionsByID = Dictionary(grouping: appState.sessions, by: \.id)
        for (sessionID, worktrees) in appState.worktrees {
            let sessionName = sessionsByID[sessionID]?.first?.name ?? sessionID.uuidString
            for wt in worktrees {
                let wtSettingsPath = (wt.worktreePath as NSString)
                    .appendingPathComponent(".claude/settings.local.json")
                for pattern in readAllowList(at: wtSettingsPath) {
                    aggregated[pattern, default: []].insert(
                        .worktree(sessionName: sessionName, path: wt.worktreePath)
                    )
                }
            }
        }

        // Build sorted entries
        appState.allowEntries = aggregated.map { pattern, sources in
            AllowEntry(pattern: pattern, sources: sources)
        }.sorted { $0.pattern.localizedCaseInsensitiveCompare($1.pattern) == .orderedAscending }

        appState.isLoadingAllowList = false
    }

    // MARK: - Promote

    /// Write selected patterns to `~/.claude/settings.json`, then re-scan.
    ///
    /// - Returns: which patterns were appended vs. already global.
    /// - Throws: the underlying error when the directory can't be created, the
    ///   existing file can't be parsed, or the write fails. These used to be
    ///   swallowed into an `NSLog`, so the `promote-allowlist` RPC answered
    ///   `{"ok":true}` for a write that never landed (#819).
    @discardableResult
    public func promoteToGlobal(patterns: Set<String>) throws -> AllowlistPromotion {
        let fm = FileManager.default

        // Ensure ~/.claude/ exists
        try fm.createDirectory(
            at: globalSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Merge into the file as it stands. A file that exists but doesn't parse
        // is an ERROR, not an empty dictionary — treating it as `[:]` and writing
        // back would drop the user's hooks / env / model / mcpServers along with
        // every other unrelated key (#819).
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: globalSettingsURL.path), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AllowlistPromoteError.malformedGlobalSettings(globalSettingsURL.path)
            }
            settings = parsed
        }

        // Get existing permissions.allow
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        // Merge new patterns (no duplicates)
        let existing = Set(allow)
        let sorted = patterns.sorted()
        let added = sorted.filter { !existing.contains($0) }
        let alreadyGlobal = sorted.filter { existing.contains($0) }
        allow.append(contentsOf: added)

        permissions["allow"] = allow
        settings["permissions"] = permissions

        // Write back. `.atomic` so a crash mid-write can't truncate the user's
        // global settings.
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: globalSettingsURL, options: .atomic)

        // Re-scan to refresh UI
        scan()

        return AllowlistPromotion(
            added: added,
            alreadyGlobal: alreadyGlobal,
            globalSettingsPath: globalSettingsURL.path
        )
    }

    // MARK: - Private

    /// Read `permissions.allow` array from a JSON settings file.
    private func readAllowList(at path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any],
              let allow = permissions["allow"] as? [String] else {
            return []
        }
        return allow
    }
}
