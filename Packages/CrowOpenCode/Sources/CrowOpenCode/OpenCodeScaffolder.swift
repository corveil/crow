import Foundation

/// Writes OpenCode-specific files into `{devRoot}` so the agent has the
/// context it expects. OpenCode reads `AGENTS.md` for repo instructions —
/// the same file Codex and Cursor use — so this reuses the shared
/// `Resources/AGENTS.md.template`.
///
/// Co-existence with `CodexScaffolder` / `CursorScaffolder` is safe: when the
/// bundled template is present (the normal path) all three writers produce
/// byte-identical content; the fallback strings differ only in the header,
/// and every writer preserves the user-edited `## Known Issues / Corrections`
/// section. `AppDelegate` runs the scaffolders in a fixed order, so the last
/// one registered wins the header on a fresh write — inconsequential since
/// the user section is always preserved.
public enum OpenCodeScaffolder {
    /// Idempotent. Re-running preserves any user-authored "Known Issues /
    /// Corrections" section the same way `Scaffolder`, `CodexScaffolder`, and
    /// `CursorScaffolder` do.
    public static func scaffold(devRoot: String) throws {
        let agentsPath = (devRoot as NSString).appendingPathComponent("AGENTS.md")
        let template = bundledAgentsMD()

        let fm = FileManager.default
        let userCorrectionsMarker = "## Known Issues / Corrections"

        if fm.fileExists(atPath: agentsPath),
           let existing = try? String(contentsOfFile: agentsPath, encoding: .utf8),
           let markerRange = existing.range(of: userCorrectionsMarker) {
            // Preserve the user-edited section below the marker.
            let userCorrections = String(existing[markerRange.lowerBound...])
            let templateBase: String
            if let templateMarker = template.range(of: userCorrectionsMarker) {
                templateBase = String(template[..<templateMarker.lowerBound])
            } else {
                templateBase = template + "\n"
            }
            try (templateBase + userCorrections).write(
                toFile: agentsPath, atomically: true, encoding: .utf8)
        } else {
            try template.write(toFile: agentsPath, atomically: true, encoding: .utf8)
        }
    }

    /// Load `AGENTS.md.template` with the same repo-walk → bundle → fallback
    /// strategy the other scaffolders use. Reuses the shared template at the
    /// repo root so OpenCode, Cursor, and Codex see the same workspace-context
    /// preamble.
    static func bundledAgentsMD() -> String {
        if let content = loadFromRepo("Resources/AGENTS.md.template") {
            return content
        }
        if let url = Bundle.main.url(forResource: "AGENTS.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        # Crow — OpenCode Workspace Context

        You are operating inside a Crow-managed development root. Sessions
        live in worktrees under workspace folders here. Use the `crow` CLI
        for session, worktree, and metadata operations.

        See `crow --help` for the CLI reference.

        ## Known Issues / Corrections
        """
    }

    private static func loadFromRepo(_ relativePath: String) -> String? {
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let filePath = dir.appendingPathComponent(relativePath)
                if let content = try? String(contentsOf: filePath) {
                    return content
                }
                return nil
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
