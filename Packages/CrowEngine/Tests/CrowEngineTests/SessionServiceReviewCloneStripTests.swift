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
        for k: AgentKind in [.claudeCode, .codex, .openCode, .grok] {
            #expect(!SessionService.shouldStripCursorReviewCloneOnHandoff(
                targetKind: k, sessionKind: .review))
        }
    }

    // MARK: - Antigravity review support (#902 — was #862 refusal, now wired)

    /// Antigravity review dispatch landed in #902, so the refusal gate no longer
    /// fires: a `.review` handoff to Antigravity is allowed (the Antigravity
    /// handoff arm strips its `.agents/`, and `autoLaunchCommand(.review)` inlines
    /// the SKILL). Guards against the gate being reintroduced and re-blocking
    /// review-on-Antigravity.
    @Test func refuseGateDoesNotFireForAntigravityReview() {
        #expect(!SessionService.shouldRefuseReviewHandoff(
            targetKind: .antigravity, sessionKind: .review))
    }

    /// No registered agent is review-incapable today, so the refusal gate is
    /// uniformly `false` across every kind × session-kind combination.
    @Test func refuseGateNeverFires() {
        for k: AgentKind in [.claudeCode, .cursor, .codex, .openCode, .antigravity] {
            for sk: SessionKind in [.work, .job, .review, .manager] {
                #expect(!SessionService.shouldRefuseReviewHandoff(
                    targetKind: k, sessionKind: sk))
            }
        }
    }

    // MARK: - Antigravity `.agents/` strip (#902 — RCE vector on review clones)

    /// The executable surface — `.agents/hooks.json` (arbitrary command hooks,
    /// no approval gate) — is gone from the working tree after the strip, so a
    /// hostile PR head's hooks can't fire when `agy` loads the clone.
    @Test func removesCommittedAgentsConfigLayer() {
        let clone = Self.makeTempDir(name: "agy-hostile")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        try? FileManager.default.createDirectory(
            atPath: agentsDir, withIntermediateDirectories: true)
        let hooks = (agentsDir as NSString).appendingPathComponent("hooks.json")
        try? "{\"version\":1}".write(toFile: hooks, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: agentsDir))

        SessionService.stripAntigravityConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: agentsDir))
        #expect(!FileManager.default.fileExists(atPath: hooks))
    }

    /// Idempotent: a clone that ships no `.agents/` is left untouched and the
    /// call doesn't throw. Guards the handoff path, which fires unconditionally
    /// for a `.review` handoff to Antigravity.
    @Test func noOpsWhenNoAgentsDirectory() {
        let clone = Self.makeTempDir(name: "agy-clean")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let prompt = (clone as NSString).appendingPathComponent(".crow-review-prompt.md")
        try? "review this".write(toFile: prompt, atomically: true, encoding: .utf8)

        SessionService.stripAntigravityConfigFromReviewClone(clonePath: clone)

        #expect(FileManager.default.fileExists(atPath: clone))
        #expect(FileManager.default.fileExists(atPath: prompt))
    }

    /// The strip is scoped to `.agents/` — a sibling agent's config (`.cursor/`,
    /// the review prompt) survives, so stripping for an Antigravity review never
    /// collaterally hides another surface.
    @Test func antigravityStripLeavesSiblingConfigUntouched() {
        let clone = Self.makeTempDir(name: "agy-siblings")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        for d in [agentsDir, cursorDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{}".write(
                toFile: (d as NSString).appendingPathComponent("config"),
                atomically: true, encoding: .utf8)
        }

        SessionService.stripAntigravityConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: agentsDir))
        #expect(FileManager.default.fileExists(atPath: cursorDir))
    }

    /// Only a `.review` handoff *to Antigravity* strips: the exact gate that
    /// keeps a review session flipped to Antigravity after prep from launching
    /// `agy` in an unstripped hostile clone.
    @Test func antigravityHandoffGateFiresOnlyForReview() {
        #expect(SessionService.shouldStripAntigravityReviewCloneOnHandoff(
            targetKind: .antigravity, sessionKind: .review))
    }

    /// A `.work`/`.job` handoff to Antigravity is a normal working clone — no strip.
    @Test func antigravityHandoffGateSkipsNonReview() {
        #expect(!SessionService.shouldStripAntigravityReviewCloneOnHandoff(
            targetKind: .antigravity, sessionKind: .work))
        #expect(!SessionService.shouldStripAntigravityReviewCloneOnHandoff(
            targetKind: .antigravity, sessionKind: .job))
    }

    /// A `.review` handoff to any *other* agent must not strip `.agents/` — only
    /// Antigravity loads it, so stripping for another agent would just hide the
    /// files a hostile PR ships (same reasoning as the `.cursor/`/`.codex/` gates).
    @Test func antigravityHandoffGateSkipsReviewForOtherAgents() {
        for k: AgentKind in [.claudeCode, .cursor, .codex, .openCode] {
            #expect(!SessionService.shouldStripAntigravityReviewCloneOnHandoff(
                targetKind: k, sessionKind: .review))
        }
    }
}
