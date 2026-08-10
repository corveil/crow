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
    /// fires: a `.review` handoff to Antigravity is allowed (the shared launch gate
    /// — `prepareWorktreeForAgentLaunch`, which every launch path including handoff
    /// routes through — strips its `.agents/`, and `autoLaunchCommand(.review)`
    /// inlines the SKILL). Guards against the gate being reintroduced and
    /// re-blocking review-on-Antigravity.
    @Test func refuseGateDoesNotFireForAntigravityReview() {
        #expect(!SessionService.shouldRefuseReviewHandoff(
            targetKind: .antigravity, sessionKind: .review))
    }

    /// No registered agent is review-incapable today, so the refusal gate is
    /// uniformly `false` across every kind × session-kind combination.
    @Test func refuseGateNeverFires() {
        for k: AgentKind in [.claudeCode, .cursor, .codex, .openCode, .grok, .antigravity] {
            for sk: SessionKind in [.work, .job, .review, .manager] {
                #expect(!SessionService.shouldRefuseReviewHandoff(
                    targetKind: k, sessionKind: sk))
            }
        }
    }

    // MARK: - Antigravity strip (#902 — RCE vector on review clones)

    /// Both executable surfaces `agy` may discover — `.agents/hooks.json`
    /// (arbitrary command hooks, no approval gate) and a Gemini-derived
    /// `.gemini/settings.json` (`mcpServers` `{command}` / approval mode) — are
    /// gone from the working tree after the strip, so a hostile PR head can't fire
    /// either when `agy` loads the clone.
    @Test func removesCommittedAntigravityConfigLayers() {
        let clone = Self.makeTempDir(name: "agy-hostile")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        let geminiDir = (clone as NSString).appendingPathComponent(".gemini")
        for d in [agentsDir, geminiDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{\"mcpServers\":{}}".write(
                toFile: (d as NSString).appendingPathComponent("settings.json"),
                atomically: true, encoding: .utf8)
        }
        #expect(FileManager.default.fileExists(atPath: agentsDir))
        #expect(FileManager.default.fileExists(atPath: geminiDir))

        SessionService.stripAntigravityConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: agentsDir))
        #expect(!FileManager.default.fileExists(atPath: geminiDir))
    }

    /// Idempotent: a clone that ships neither `.agents/` nor `.gemini/` is left
    /// untouched and the call doesn't throw. Guards the launch-gate path, which
    /// fires unconditionally for a `.review` on Antigravity.
    @Test func noOpsWhenNoAntigravityConfig() {
        let clone = Self.makeTempDir(name: "agy-clean")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let prompt = (clone as NSString).appendingPathComponent(".crow-review-prompt.md")
        try? "review this".write(toFile: prompt, atomically: true, encoding: .utf8)

        SessionService.stripAntigravityConfigFromReviewClone(clonePath: clone)

        #expect(FileManager.default.fileExists(atPath: clone))
        #expect(FileManager.default.fileExists(atPath: prompt))
    }

    /// The strip is scoped to the layers `agy` discovers (`.agents/`, `.gemini/`)
    /// — a sibling agent's config (`.cursor/`, the review prompt) survives, so
    /// stripping for an Antigravity review never collaterally hides a surface
    /// `agy` doesn't read.
    @Test func antigravityStripLeavesSiblingConfigUntouched() {
        let clone = Self.makeTempDir(name: "agy-siblings")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        let geminiDir = (clone as NSString).appendingPathComponent(".gemini")
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        for d in [agentsDir, geminiDir, cursorDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{}".write(
                toFile: (d as NSString).appendingPathComponent("config"),
                atomically: true, encoding: .utf8)
        }

        SessionService.stripAntigravityConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: agentsDir))
        #expect(!FileManager.default.fileExists(atPath: geminiDir))
        #expect(FileManager.default.fileExists(atPath: cursorDir))
    }

    /// Only a `.review` clone *on Antigravity* strips: the gate that keeps every
    /// launch path (`prepareWorktreeForAgentLaunch`) — warm restart, `crow send`,
    /// handoff — from launching `agy` in an unstripped hostile clone after the
    /// review skill's `gh pr checkout` restores committed `.agents/` hooks.
    @Test func antigravityStripGateFiresOnlyForReview() {
        #expect(SessionService.shouldStripAntigravityReviewClone(
            agentKind: .antigravity, sessionKind: .review))
    }

    /// A `.work`/`.job` Antigravity session is a normal working clone — no strip.
    @Test func antigravityStripGateSkipsNonReview() {
        #expect(!SessionService.shouldStripAntigravityReviewClone(
            agentKind: .antigravity, sessionKind: .work))
        #expect(!SessionService.shouldStripAntigravityReviewClone(
            agentKind: .antigravity, sessionKind: .job))
    }

    /// A `.review` on any *other* agent must not strip `.agents/` — only
    /// Antigravity loads it, so stripping for another agent would just hide the
    /// files a hostile PR ships (same reasoning as the `.cursor/`/`.codex/` gates).
    @Test func antigravityStripGateSkipsReviewForOtherAgents() {
        for k: AgentKind in [.claudeCode, .cursor, .codex, .openCode, .grok] {
            #expect(!SessionService.shouldStripAntigravityReviewClone(
                agentKind: k, sessionKind: .review))
        }
    }

    // MARK: - The launch-gate wiring itself (the round-2 RCE fix)

    /// `prepareWorktreeForAgentLaunch` is the ONE gate every launch path routes
    /// through (`launchAgent` on warm restart, `pasteDeferredLaunch`,
    /// `createManagerTerminal`, the `send` RPC, handoff), so this covers the wiring
    /// the predicate/helper tests above can't: delete the
    /// `shouldStripAntigravityReviewClone` arm of `prepareWorktreeForAgentLaunch`
    /// and only this test fails. `.antigravity` seeds no folder trust on any kind,
    /// so the call touches zero global trust state — no `.review`-only framing
    /// needed (unlike the Grok equivalent).
    @Test func prepareStripsAgentsWhenGateFires() {
        let clone = Self.makeTempDir(name: "prep-agy-review")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        try? FileManager.default.createDirectory(
            atPath: agentsDir, withIntermediateDirectories: true)
        try? "{\"hooks\":\"EVIL\"}".write(
            toFile: (agentsDir as NSString).appendingPathComponent("hooks.json"),
            atomically: true, encoding: .utf8)

        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .antigravity, sessionKind: .review, worktreePath: clone, ownership: .empty)

        #expect(!FileManager.default.fileExists(atPath: agentsDir))
    }

    /// The gate is scoped: a `.work` Antigravity session is a normal working
    /// clone, so `prepareWorktreeForAgentLaunch` leaves its `.agents/` in place.
    @Test func prepareLeavesAgentsForNonReview() {
        let clone = Self.makeTempDir(name: "prep-agy-work")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        try? FileManager.default.createDirectory(
            atPath: agentsDir, withIntermediateDirectories: true)

        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .antigravity, sessionKind: .work, worktreePath: clone, ownership: .empty)

        #expect(FileManager.default.fileExists(atPath: agentsDir))
    }

    // MARK: - Cursor launch-path strip (CROW-954 — the dialog is gone, so this is the gate)

    /// Only a `.review` clone *on Cursor* strips on the launch path. Before
    /// CROW-954 the creation-time strip was backstopped by Cursor's folder-trust
    /// dialog; now that review launches carry `--trust`, this gate is the only
    /// thing between a committed `.cursor/hooks.json` restored by the review
    /// skill's `gh pr checkout` and unsandboxed execution.
    @Test func cursorStripGateFiresOnlyForReview() {
        #expect(SessionService.shouldStripCursorReviewClone(
            agentKind: .cursor, sessionKind: .review))
    }

    /// A `.work`/`.job` Cursor session branches off a trusted base — no strip.
    @Test func cursorStripGateSkipsNonReview() {
        #expect(!SessionService.shouldStripCursorReviewClone(
            agentKind: .cursor, sessionKind: .work))
        #expect(!SessionService.shouldStripCursorReviewClone(
            agentKind: .cursor, sessionKind: .job))
    }

    /// A `.review` on any *other* agent must not strip `.cursor/` — stripping a
    /// surface the reviewing agent doesn't load would just hide the files a hostile
    /// PR ships (same reasoning as the `.codex/`/`.agents/` gates). Grok is the
    /// deliberate exception and strips `.cursor/` through its own broader helper.
    @Test func cursorStripGateSkipsReviewForOtherAgents() {
        for k: AgentKind in [.claudeCode, .codex, .openCode, .antigravity] {
            #expect(!SessionService.shouldStripCursorReviewClone(
                agentKind: k, sessionKind: .review))
        }
    }

    /// The launch-gate wiring, not just the predicate: delete the
    /// `shouldStripCursorReviewClone` arm of `prepareWorktreeForAgentLaunch` and
    /// only this test fails. `.cursor` seeds no folder trust through
    /// `seedTrustIfNeeded` (it trusts per-launch via the `--trust` flag instead),
    /// so this call touches zero global trust state.
    @Test func prepareStripsCursorConfigWhenGateFires() {
        let clone = Self.makeTempDir(name: "prep-cursor-review")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(
            atPath: cursorDir, withIntermediateDirectories: true)
        try? "{\"hooks\":\"EVIL\"}".write(
            toFile: (cursorDir as NSString).appendingPathComponent("hooks.json"),
            atomically: true, encoding: .utf8)

        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .cursor, sessionKind: .review, worktreePath: clone, ownership: .empty)

        #expect(!FileManager.default.fileExists(atPath: cursorDir))
    }

    /// The gate is scoped: a `.work` Cursor session is a normal working clone, so
    /// `prepareWorktreeForAgentLaunch` leaves the user's own `.cursor/` alone.
    @Test func prepareLeavesCursorConfigForNonReview() {
        let clone = Self.makeTempDir(name: "prep-cursor-work")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(
            atPath: cursorDir, withIntermediateDirectories: true)

        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .cursor, sessionKind: .work, worktreePath: clone, ownership: .empty)

        #expect(FileManager.default.fileExists(atPath: cursorDir))
    }
}
