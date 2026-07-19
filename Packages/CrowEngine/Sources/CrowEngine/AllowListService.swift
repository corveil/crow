import Foundation
import CrowCore

/// Scans worktree and global settings files to aggregate allow-list entries.
@MainActor
public final class AllowListService {
    private let appState: AppState
    private let devRoot: String

    public init(appState: AppState, devRoot: String) {
        self.appState = appState
        self.devRoot = devRoot
    }

    // MARK: - Scan

    /// Aggregate allow-list entries from global, workspace, and worktree settings.
    public func scan() {
        appState.isLoadingAllowList = true
        var aggregated: [String: Set<AllowSource>] = [:]

        // 1. Global: ~/.claude/settings.json
        let globalPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
        for pattern in readAllowList(at: globalPath) {
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
    public func promoteToGlobal(patterns: Set<String>) {
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let globalPath = claudeDir.appendingPathComponent("settings.json")

        // Ensure ~/.claude/ exists
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Read existing global settings
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: globalPath.path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        // Get existing permissions.allow
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        // Merge new patterns (no duplicates)
        let existingSet = Set(allow)
        for pattern in patterns.sorted() where !existingSet.contains(pattern) {
            allow.append(pattern)
        }

        permissions["allow"] = allow
        settings["permissions"] = permissions

        // Write back
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: globalPath)
        } catch {
            NSLog("[AllowListService] Failed to write promoted patterns to %@: %@",
                  globalPath.path, error.localizedDescription)
        }

        // Re-scan to refresh UI
        scan()
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
