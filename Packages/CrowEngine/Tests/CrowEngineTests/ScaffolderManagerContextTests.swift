import Foundation
import Testing
@testable import CrowEngine

/// CROW-1443: every Crow session loads `{devRoot}/.claude/CLAUDE.md` on every
/// turn, so the scaffolded Manager context stays small and the per-verb CLI
/// reference ships as the on-demand `crow-cli` skill.
@Suite("Scaffolder Manager context")
struct ScaffolderManagerContextTests {

    private static func makeTempDevRoot() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1443-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func read(_ devRoot: String, _ relative: String) throws -> String {
        try String(
            contentsOfFile: (devRoot as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    /// The bundled resource is what loads — not the minimal fallback, which
    /// would mean the resource never made it into CrowEngine's bundle.
    @Test func managerContextLoadsFromTheBundledResource() {
        let context = Scaffolder.bundledCLAUDEMD()
        #expect(context.contains("## crow CLI"))
        #expect(context.contains("crow-cli"))
        #expect(ManagerContext.cliReference().contains("## Notification Commands"))
        #expect(ManagerContext.cliSkill().hasPrefix("---\nname: crow-cli\n"))
    }

    @Test func managerContextStaysUnderTheCap() {
        let bytes = Scaffolder.bundledCLAUDEMD().utf8.count
        #expect(
            bytes <= ManagerContext.maxBytes,
            "The Manager context is \(bytes) bytes, over the \(ManagerContext.maxBytes)-byte cap. Every session loads it on every turn: move per-verb detail to the crow-cli reference instead (CROW-1443)."
        )
    }

    @Test func managerContextEndsWithTheCorrectionsHeading() {
        // Scaffolder keeps the operator's corrections by splitting on this
        // heading, so the template must carry it.
        #expect(Scaffolder.bundledCLAUDEMD().contains(ManagerContext.correctionsHeading))
    }

    @Test func scaffoldWritesTheSlimContextAndTheCLISkill() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = try Scaffolder(devRoot: devRoot).scaffold(workspaceNames: [])

        let claudeMD = try Self.read(devRoot, ".claude/CLAUDE.md")
        #expect(claudeMD == Scaffolder.bundledCLAUDEMD())
        #expect(!claudeMD.contains("crow corveil connect"), "the per-verb reference leaked back into CLAUDE.md")

        let skill = try Self.read(devRoot, ".claude/skills/crow-cli/SKILL.md")
        #expect(skill == ManagerContext.cliSkill())
        let reference = try Self.read(devRoot, ".claude/skills/crow-cli/reference.md")
        #expect(reference == ManagerContext.cliReference())
    }

    /// Upgrading from the old 64KB context keeps the operator's corrections
    /// and drops everything above them.
    @Test func upgradeReplacesTheOldContextButKeepsCorrections() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let old = """
        # Crow — Manager Context

        ## crow CLI Reference

        ### Corveil connection
        (52KB of reference)

        ## Known Issues / Corrections

        - 2026-09-22: retry add-worktree then setup.sh --session-id.
        """
        try old.write(
            toFile: (claudeDir as NSString).appendingPathComponent("CLAUDE.md"),
            atomically: true, encoding: .utf8)

        _ = try Scaffolder(devRoot: devRoot).scaffold(workspaceNames: [])

        let claudeMD = try Self.read(devRoot, ".claude/CLAUDE.md")
        #expect(!claudeMD.contains("### Corveil connection"))
        #expect(claudeMD.contains("- 2026-09-22: retry add-worktree then setup.sh --session-id."))
        let correctionsAt = try #require(claudeMD.range(of: ManagerContext.correctionsHeading))
        #expect(claudeMD[..<correctionsAt.lowerBound].utf8.count <= ManagerContext.maxBytes)
    }
}
