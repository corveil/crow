import Foundation

/// Seeds per-project trust into `~/.claude.json` so Claude Code skips the
/// "Do you trust the files in this folder?" dialog when Crow auto-launches
/// a session in a fresh worktree or review clone (CROW-600).
///
/// Claude Code records trust per absolute project path under
/// `projects["<path>"].hasTrustDialogAccepted` (plus
/// `hasCompletedProjectOnboarding`), and trust does NOT inherit from parent
/// directories — so every fresh worktree/clone would otherwise prompt and
/// block unattended review/job flows.
///
/// `~/.claude.json` is Claude Code's own mutable state (other projects,
/// mcpServers, oauthAccount, …), so this merges — it never overwrites
/// unrelated keys, refuses to touch a file it can't parse, and skips the
/// write entirely when the path is already trusted. A concurrently running
/// `claude` may rewrite the file; the atomic write plus skip-when-trusted
/// keeps that race window small, and losing our write only re-shows the
/// dialog (benign).
public enum ClaudeTrustSeeder {

    public enum Outcome: Equatable {
        /// Trust keys were written/updated for the project path.
        case seeded
        /// The project path already had both trust keys true; nothing written.
        case alreadyTrusted
        /// The file exists but isn't a JSON object; refused to touch it.
        case skippedUnparseable
        /// Read or write failed.
        case failed(String)
    }

    /// The keys Claude Code checks before showing the trust dialog.
    private static let trustKeys = ["hasTrustDialogAccepted", "hasCompletedProjectOnboarding"]

    /// Ensure `~/.claude.json` marks `projectPath` as trusted before Claude
    /// Code launches there. Pass `claudeJSONPath` to target a different file
    /// (tests); `nil` uses the real `~/.claude.json`.
    @discardableResult
    public static func seedTrust(
        projectPath: String,
        claudeJSONPath: String? = nil
    ) -> Outcome {
        let jsonPath = claudeJSONPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json").path

        // Claude Code keys `projects` by its resolved cwd, which may differ
        // from the path Crow launches with (symlinks). Trust both spellings.
        var projectPaths = [projectPath]
        let resolved = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
        if resolved != projectPath {
            projectPaths.append(resolved)
        }

        let fm = FileManager.default
        var root: [String: Any] = [:]
        let fileExists = fm.fileExists(atPath: jsonPath)
        if fileExists {
            guard let data = fm.contents(atPath: jsonPath),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                NSLog("[ClaudeTrustSeeder] %@ exists but is not a JSON object; refusing to modify it", jsonPath)
                return .skippedUnparseable
            }
            root = parsed
        }

        var projects = root["projects"] as? [String: Any] ?? [:]
        var changed = false
        for path in projectPaths {
            var entry = projects[path] as? [String: Any] ?? [:]
            for key in trustKeys where (entry[key] as? Bool) != true {
                entry[key] = true
                changed = true
            }
            projects[path] = entry
        }
        if !changed {
            return .alreadyTrusted
        }
        root["projects"] = projects

        // Preserve the file's existing permissions on rewrite; a freshly
        // created file gets owner-only since ~/.claude.json can carry
        // credentials (matching ConfigStore's 0600 on config.json).
        let existingPerms = fileExists
            ? (try? fm.attributesOfItem(atPath: jsonPath))?[.posixPermissions] as? NSNumber
            : nil
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
            let perms = existingPerms ?? NSNumber(value: 0o600)
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: jsonPath)
        } catch {
            NSLog("[ClaudeTrustSeeder] Failed to write %@: %@", jsonPath, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
        return .seeded
    }
}
