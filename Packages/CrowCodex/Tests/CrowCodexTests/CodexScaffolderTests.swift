import Foundation
import Testing
@testable import CrowCodex

@Suite("CodexScaffolder")
struct CodexScaffolderTests {
    private func makeTempDevRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scaffold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func scaffoldWritesAgentsMD() throws {
        let devRoot = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(at: devRoot) }

        try CodexScaffolder.scaffold(devRoot: devRoot.path)

        let agents = try String(
            contentsOf: devRoot.appendingPathComponent("AGENTS.md"),
            encoding: .utf8
        )
        // The fallback bundled template (or the resource) must contain
        // some Crow-specific marker.
        #expect(agents.contains("Crow"))
        #expect(agents.contains("Known Issues / Corrections"))
    }

    @Test func scaffoldPreservesUserCorrections() throws {
        let devRoot = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(at: devRoot) }

        // First pass: write the template.
        try CodexScaffolder.scaffold(devRoot: devRoot.path)

        // Append a user-authored Known Issues entry.
        let agentsPath = devRoot.appendingPathComponent("AGENTS.md").path
        let template = try String(contentsOfFile: agentsPath, encoding: .utf8)
        let edited = template.replacingOccurrences(
            of: "## Known Issues / Corrections",
            with: "## Known Issues / Corrections\n\n- Use `crow new-session --agent codex` for Codex sessions."
        )
        try edited.write(toFile: agentsPath, atomically: true, encoding: .utf8)

        // Second pass: should preserve the edits.
        try CodexScaffolder.scaffold(devRoot: devRoot.path)

        let after = try String(contentsOfFile: agentsPath, encoding: .utf8)
        #expect(after.contains("Use `crow new-session --agent codex`"))
    }
}
