import Foundation

/// Writes Cursor-specific files into `{devRoot}` so the agent has the
/// context it expects. Cursor's docs recommend `AGENTS.md` as the simple
/// alternative to `.cursor/rules/*.mdc` — this is the same file Codex
/// uses, and we reuse the shared `Resources/AGENTS.md.template`.
///
/// Co-existence with `CodexScaffolder` is safe: both write byte-identical
/// content using the same template, both preserve user edits below the
/// `## Known Issues / Corrections` marker, and both are idempotent. The
/// `.cursorrules` legacy file is intentionally not written — it's silent
/// in current Cursor docs, and `AGENTS.md` covers the same role.
public enum CursorScaffolder {
    /// Idempotent. Re-running preserves any user-authored "Known Issues /
    /// Corrections" section the same way `Scaffolder` does for `CLAUDE.md`
    /// and `CodexScaffolder` does for `AGENTS.md`.
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

    /// Load `AGENTS.md.template` with the same repo-walk → bundle →
    /// fallback strategy `Scaffolder` and `CodexScaffolder` use. Reuses
    /// the shared template at the repo root — Cursor and Codex see the
    /// same workspace-context preamble.
    static func bundledAgentsMD() -> String {
        if let content = loadFromRepo("Resources/AGENTS.md.template") {
            return content
        }
        if let url = Bundle.main.url(forResource: "AGENTS.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        # Crow — Cursor Workspace Context

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
