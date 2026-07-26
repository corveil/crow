import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Coverage for `SessionService.stripGrokConfigFromReviewClone` — the shared
/// primitive that neutralizes a review clone's committed Grok config layer
/// (#861 review, Red). Both the creation-time `prepareReviewClone` path and the
/// `handoffAgent` Grok branch route through it, so testing the helper + gate
/// directly covers the security-relevant behavior of both without shelling out
/// to `gh repo clone`. Mirrors `SessionServiceReviewCloneStripTests` (Cursor).
@Suite("Review clone .grok/ strip")
struct SessionServiceGrokReviewCloneStripTests {

    private static func makeTempDir(name: String) -> String {
        let base = NSTemporaryDirectory() as NSString
        let dir = base.appendingPathComponent("crow-grok-strip-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The executable surface — a committed `.grok/hooks/*.json` (arbitrary
    /// `command`-type hooks with no approval gate, which Grok merges and runs
    /// once the folder is trusted) — is gone from the working tree after the
    /// strip.
    @Test func removesCommittedGrokConfigLayer() {
        let clone = Self.makeTempDir(name: "hostile")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let hooksDir = (clone as NSString).appendingPathComponent(".grok/hooks")
        try? FileManager.default.createDirectory(
            atPath: hooksDir, withIntermediateDirectories: true)
        let hostileHook = (hooksDir as NSString).appendingPathComponent("evil.json")
        try? "{\"hooks\":{}}".write(toFile: hostileHook, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: hostileHook))

        SessionService.stripGrokConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(
            atPath: (clone as NSString).appendingPathComponent(".grok")))
        #expect(!FileManager.default.fileExists(atPath: hostileHook))
    }

    /// Grok also discovers project `.claude/settings*.json` and `.cursor/hooks.json`
    /// (+ `.cursor/mcp.json`) via compat scanning — all attacker-controlled RCE on
    /// a review-clone head. The strip must neutralize the **full** discovered set
    /// (#861 review round 2, Red): `.cursor/` gone, `.claude/settings.local.json`
    /// gone, while the Crow-overwritten `.claude/settings.json` and the review
    /// skill survive.
    @Test func neutralizesAllGrokDiscoveredSources() {
        let clone = Self.makeTempDir(name: "compat")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let ns = clone as NSString
        let fm = FileManager.default

        // Attacker-controlled surfaces Grok loads by default.
        let cursorDir = ns.appendingPathComponent(".cursor")
        try? fm.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        let cursorHooks = (cursorDir as NSString).appendingPathComponent("hooks.json")
        let cursorMCP = (cursorDir as NSString).appendingPathComponent("mcp.json")
        try? "{}".write(toFile: cursorHooks, atomically: true, encoding: .utf8)
        try? "{}".write(toFile: cursorMCP, atomically: true, encoding: .utf8)

        let claudeDir = ns.appendingPathComponent(".claude")
        let skillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-review-pr")
        try? fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
        let settingsLocal = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        let settings = (claudeDir as NSString).appendingPathComponent("settings.json")
        let skill = (skillsDir as NSString).appendingPathComponent("SKILL.md")
        try? "{\"hooks\":{}}".write(toFile: settingsLocal, atomically: true, encoding: .utf8)
        // Crow-owned, safe: settings.json is overwritten with bundled permissions
        // and the review skill is Crow-written — both must survive.
        try? "{\"permissions\":{}}".write(toFile: settings, atomically: true, encoding: .utf8)
        try? "# review".write(toFile: skill, atomically: true, encoding: .utf8)

        SessionService.stripGrokConfigFromReviewClone(clonePath: clone)

        // Attacker-controlled surfaces gone.
        #expect(!fm.fileExists(atPath: cursorDir))
        #expect(!fm.fileExists(atPath: cursorHooks))
        #expect(!fm.fileExists(atPath: cursorMCP))
        #expect(!fm.fileExists(atPath: settingsLocal))
        // Crow-safe surfaces preserved.
        #expect(fm.fileExists(atPath: settings))
        #expect(fm.fileExists(atPath: skill))
    }

    /// Idempotent: a clone that ships no `.grok/` is left untouched and the call
    /// doesn't throw. Guards the handoff path, which fires unconditionally for
    /// `.review` regardless of whether the head committed a `.grok/`.
    @Test func noOpsWhenNoGrokDirectory() {
        let clone = Self.makeTempDir(name: "clean")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let prompt = (clone as NSString).appendingPathComponent(".crow-review-prompt.md")
        try? "review this".write(toFile: prompt, atomically: true, encoding: .utf8)

        SessionService.stripGrokConfigFromReviewClone(clonePath: clone)

        #expect(FileManager.default.fileExists(atPath: clone))
        #expect(FileManager.default.fileExists(atPath: prompt))
    }

    /// The strip is scoped to what Grok loads — a sibling agent's config
    /// (`.codex/`, the review prompt) that Grok never reads survives, so the
    /// strip never collaterally hides another agent's surface.
    @Test func leavesUnreadSiblingConfigUntouched() {
        let clone = Self.makeTempDir(name: "siblings")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let grokDir = (clone as NSString).appendingPathComponent(".grok")
        let codexDir = (clone as NSString).appendingPathComponent(".codex")
        for d in [grokDir, codexDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{}".write(
                toFile: (d as NSString).appendingPathComponent("config"),
                atomically: true, encoding: .utf8)
        }

        SessionService.stripGrokConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: grokDir))
        // `.codex/` is not a Grok-discovered source — it survives.
        #expect(FileManager.default.fileExists(atPath: codexDir))
    }

    // MARK: - Handoff gate

    /// Only a `.review` handoff *to Grok* strips — the gate that, when missing
    /// (#861 review, Red), left Grok running in an unstripped hostile clone after
    /// a handoff from another agent.
    @Test func handoffGateFiresOnlyForGrokReview() {
        #expect(SessionService.shouldStripGrokReviewCloneOnHandoff(
            targetKind: .grok, sessionKind: .review))
    }

    /// A `.work`/`.job` handoff to Grok is a normal working clone branched off a
    /// trusted base, not an attacker-controlled review head — no strip.
    @Test func handoffGateSkipsNonReviewGrok() {
        #expect(!SessionService.shouldStripGrokReviewCloneOnHandoff(
            targetKind: .grok, sessionKind: .work))
        #expect(!SessionService.shouldStripGrokReviewCloneOnHandoff(
            targetKind: .grok, sessionKind: .job))
    }

    /// A `.review` handoff to any *other* agent must not strip `.grok/` —
    /// stripping a surface the reviewing agent doesn't load would just hide the
    /// files a hostile PR ships.
    @Test func handoffGateSkipsReviewForNonGrokAgents() {
        for k: AgentKind in [.claudeCode, .codex, .cursor, .openCode] {
            #expect(!SessionService.shouldStripGrokReviewCloneOnHandoff(
                targetKind: k, sessionKind: .review))
        }
    }
}
