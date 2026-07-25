import Foundation
import Testing
import CrowCore
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

    // MARK: - Handoff gate (the dimension both round-10 and round-11 blockers lived in)

    /// Only a `.review` handoff *to Cursor* strips: the exact gate that, when
    /// missing (round 10) or divergent (round 11), left Cursor running in an
    /// unstripped hostile clone.
    @Test func handoffGateFiresOnlyForCursorReview() {
        #expect(SessionService.shouldStripCursorReviewCloneOnHandoff(
            targetKind: .cursor, sessionKind: .review))
    }

    /// A `.work`/`.job` handoff to Cursor is a normal working clone, not an
    /// attacker-controlled review head — no strip.
    @Test func handoffGateSkipsNonReviewCursor() {
        #expect(!SessionService.shouldStripCursorReviewCloneOnHandoff(
            targetKind: .cursor, sessionKind: .work))
        #expect(!SessionService.shouldStripCursorReviewCloneOnHandoff(
            targetKind: .cursor, sessionKind: .job))
    }

    /// A `.review` handoff to any *other* agent must not strip `.cursor/` —
    /// stripping a surface the reviewing agent doesn't load would just hide the
    /// files a hostile PR ships (same reasoning as the `.codex/` gate).
    @Test func handoffGateSkipsReviewForNonCursorAgents() {
        for k: AgentKind in [.claudeCode, .codex, .openCode] {
            #expect(!SessionService.shouldStripCursorReviewCloneOnHandoff(
                targetKind: k, sessionKind: .review))
        }
    }
}
