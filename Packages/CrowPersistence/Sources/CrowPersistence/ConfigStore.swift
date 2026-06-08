import Foundation
import CrowCore

/// Manages the devRoot pointer and workspace config.
///
/// Storage is split across two locations:
/// - **App Support** (`~/Library/Application Support/crow/devroot`): a plain-text file
///   containing the path to the user's development root directory.
/// - **Dev Root** (`{devRoot}/.claude/config.json`): the full application config (workspaces,
///   defaults, notification preferences, sidebar settings).
///
/// All files are written with restrictive permissions (0o600 for files, 0o700 for directories)
/// because the config may contain host names and workspace layout details.
public final class ConfigStore: Sendable {
    private static let devRootPointerPath: URL = AppSupportDirectory.url.appendingPathComponent("devroot")

    // MARK: - devRoot Pointer

    /// Read the devRoot path from ~/Library/Application Support/crow/devroot
    public static func loadDevRoot() -> String? {
        guard let data = try? Data(contentsOf: devRootPointerPath),
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: path) {
            NSLog("[ConfigStore] devRoot path does not exist on disk: %@", path)
        }
        return path
    }

    /// Write the devRoot path.
    public static func saveDevRoot(_ path: String) throws {
        let appSupportDir = AppSupportDirectory.url
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        // Restrict app support directory to owner-only access
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: appSupportDir.path)
        try path.write(to: devRootPointerPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: devRootPointerPath.path)
    }

    // MARK: - App Config

    /// Load config from `{devRoot}/.claude/config.json`.
    ///
    /// Returns `nil` if the file doesn't exist or can't be decoded. Decode errors
    /// are logged so malformed configs are diagnosable.
    public static func loadConfig(devRoot: String) -> AppConfig? {
        let configURL = URL(fileURLWithPath: devRoot)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("config.json")
        return loadConfig(from: configURL)
    }

    /// Load config from an explicit URL (internal, exposed for testing via @testable).
    static func loadConfig(from configURL: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            NSLog("[ConfigStore] Failed to decode config at %@: %@", configURL.path, error.localizedDescription)
            return nil
        }
    }

    /// Save config to `{devRoot}/.claude/config.json`.
    ///
    /// Creates the `.claude/` directory if needed. Both the directory (0o700) and the
    /// config file (0o600) are restricted to owner-only access.
    public static func saveConfig(_ config: AppConfig, devRoot: String) throws {
        let claudeDir = URL(fileURLWithPath: devRoot).appendingPathComponent(".claude", isDirectory: true)
        try saveConfig(config, to: claudeDir)
    }

    /// Save config to an explicit directory (internal, exposed for testing via @testable).
    static func saveConfig(_ config: AppConfig, to claudeDir: URL) throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: claudeDir.path)

        let configURL = claudeDir.appendingPathComponent("config.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    // MARK: - Import from CMUX workspace-repos.json

    /// Import config from `~/.claude/workspace-repos.json` (legacy CMUX format).
    ///
    /// CMUX was the predecessor tool. This imports workspace names, providers, CLI tools,
    /// hosts, and always-include repos. Fields that don't exist in Crow's config model
    /// (`worktreePattern`, `keywordSources`) are silently dropped.
    public static func importFromCMUX() -> (devRoot: String, config: AppConfig)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cmuxPath = home.appendingPathComponent(".claude/workspace-repos.json")
        guard let data = try? Data(contentsOf: cmuxPath),
              let cmux = try? JSONDecoder().decode(WorkspaceConfig.self, from: data) else {
            return nil
        }

        let workspaces = cmux.workspaces.map { (name, entry) in
            WorkspaceInfo(
                name: name,
                provider: entry.provider,
                cli: entry.cli,
                host: entry.host,
                alwaysInclude: entry.alwaysInclude ?? [],
                taskProvider: entry.taskProvider,
                jiraProjectKey: entry.jiraProjectKey,
                jiraJQL: entry.jiraJQL,
                jiraSite: entry.jiraSite
            )
        }

        let config = AppConfig(
            workspaces: workspaces,
            defaults: ConfigDefaults(
                provider: cmux.defaults.provider,
                cli: cmux.defaults.cli,
                branchPrefix: cmux.defaults.branchPrefix,
                excludeDirs: cmux.defaults.excludeDirs
            )
        )

        return (devRoot: cmux.devRoot, config: config)
    }
}
