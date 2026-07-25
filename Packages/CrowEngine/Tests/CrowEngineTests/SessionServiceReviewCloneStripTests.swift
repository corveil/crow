import Foundation
import Testing
@testable import CrowEngine

/// Coverage for `SessionService.stripCursorConfigFromReviewClone` — the shared
/// primitive that neutralizes a review clone's committed Cursor config layer
/// (#829 review rounds 9-10). Both the creation-time `prepareReviewClone` path
/// and the `handoffAgent` Cursor branch route through it, so testing the helper
/// directly covers the security-relevant behavior of both without shelling out
/// to `gh repo clone`.
@Suite("Review clone .cursor/ strip")
struct SessionServiceReviewCloneStripTests {

    private static func makeTempDir(name: String) -> String {
        let base = NSTemporaryDirectory() as NSString
        let dir = base.appendingPathComponent("crow-strip-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The executable surfaces — `.cursor/hooks.json` (arbitrary shell, no
    /// approval gate) and `.cursor/mcp.json` (an `--approve-mcps`-auto-trusted
    /// project MCP) — are both gone from the working tree after the strip.
    @Test func removesCommittedCursorConfigLayer() {
        let clone = Self.makeTempDir(name: "hostile")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(
            atPath: cursorDir, withIntermediateDirectories: true)
        let hooks = (cursorDir as NSString).appendingPathComponent("hooks.json")
        let mcp = (cursorDir as NSString).appendingPathComponent("mcp.json")
        try? "{\"version\":1}".write(toFile: hooks, atomically: true, encoding: .utf8)
        try? "{\"mcpServers\":{}}".write(toFile: mcp, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: cursorDir))

        SessionService.stripCursorConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: cursorDir))
        #expect(!FileManager.default.fileExists(atPath: hooks))
        #expect(!FileManager.default.fileExists(atPath: mcp))
    }

    /// Idempotent: a clone that ships no `.cursor/` is left untouched and the
    /// call doesn't throw. Guards the handoff path, which fires unconditionally
    /// for `.review` regardless of whether the head committed a `.cursor/`.
    @Test func noOpsWhenNoCursorDirectory() {
        let clone = Self.makeTempDir(name: "clean")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let prompt = (clone as NSString).appendingPathComponent(".crow-review-prompt.md")
        try? "review this".write(toFile: prompt, atomically: true, encoding: .utf8)

        SessionService.stripCursorConfigFromReviewClone(clonePath: clone)

        #expect(FileManager.default.fileExists(atPath: clone))
        #expect(FileManager.default.fileExists(atPath: prompt))
    }

    /// The strip is scoped to `.cursor/` — a sibling agent's config
    /// (`.codex/`, the review prompt) survives, so stripping for a Cursor
    /// review never collaterally hides another surface.
    @Test func leavesSiblingConfigUntouched() {
        let clone = Self.makeTempDir(name: "siblings")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        let codexDir = (clone as NSString).appendingPathComponent(".codex")
        for d in [cursorDir, codexDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{}".write(
                toFile: (d as NSString).appendingPathComponent("config"),
                atomically: true, encoding: .utf8)
        }

        SessionService.stripCursorConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: cursorDir))
        #expect(FileManager.default.fileExists(atPath: codexDir))
    }
}
