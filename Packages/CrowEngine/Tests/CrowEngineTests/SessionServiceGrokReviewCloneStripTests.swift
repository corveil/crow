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

    /// Grok also discovers project `.claude/settings*.json`, `.cursor/hooks.json`
    /// + `.cursor/mcp.json`, and repo-root `.mcp.json` via compat / MCP scanning
    /// — all attacker-controlled RCE on a review-clone head. The strip must
    /// neutralize the **full** discovered set (#861 review rounds 2-3, r12):
    /// `.cursor/` gone, **both** `.claude/settings.local.json` and `settings.json`
    /// gone, repo-root `.mcp.json` gone. `.claude/skills/` (not a Grok-loaded
    /// source — the review inlines the skill into its prompt) is left in place.
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

        // Repo-root `.mcp.json` — a project MCP source distinct from .cursor/mcp.json.
        let rootMCP = ns.appendingPathComponent(".mcp.json")
        try? "{\"mcpServers\":{\"pwn\":{\"command\":\"/bin/echo\"}}}".write(
            toFile: rootMCP, atomically: true, encoding: .utf8)

        let claudeDir = ns.appendingPathComponent(".claude")
        let skillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-review-pr")
        try? fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
        let settingsLocal = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        let settings = (claudeDir as NSString).appendingPathComponent("settings.json")
        let skill = (skillsDir as NSString).appendingPathComponent("SKILL.md")
        try? "{\"hooks\":{}}".write(toFile: settingsLocal, atomically: true, encoding: .utf8)
        // A hostile `.claude/settings.json` — its `hooks`/`env` run subprocesses
        // under Grok's Claude compat. The strip removes it (#861 review r12): at
        // creation `prepareReviewClone` rewrites a bundled-safe one afterward, but
        // on the re-strip paths a restored hostile one must be removed, not kept.
        try? "{\"hooks\":{\"Stop\":[]}}".write(toFile: settings, atomically: true, encoding: .utf8)
        try? "# review".write(toFile: skill, atomically: true, encoding: .utf8)

        SessionService.stripGrokConfigFromReviewClone(clonePath: clone)

        // Every attacker-controlled compat surface Grok loads is gone.
        #expect(!fm.fileExists(atPath: cursorDir))
        #expect(!fm.fileExists(atPath: cursorHooks))
        #expect(!fm.fileExists(atPath: cursorMCP))
        #expect(!fm.fileExists(atPath: settingsLocal))
        #expect(!fm.fileExists(atPath: settings))
        #expect(!fm.fileExists(atPath: rootMCP))
        // `.claude/skills/` is NOT a Grok-loaded source (the review inlines the
        // skill into its prompt), so the strip leaves it — creation re-writes it
        // bundled-safe, and on Grok it's simply never read as a file.
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

    // MARK: - Strip gate (shared by launchAgent, handoff, creation-time)

    /// Only a `.review` session on Grok strips — the gate that, when missing on a
    /// launch path (#861 review, Red rounds 1 & 11), left Grok running in an
    /// unstripped hostile clone.
    @Test func stripGateFiresOnlyForGrokReview() {
        #expect(SessionService.shouldStripGrokReviewClone(
            agentKind: .grok, sessionKind: .review))
    }

    /// A `.work`/`.job` on Grok is a normal working clone branched off a trusted
    /// base, not an attacker-controlled review head — no strip.
    @Test func stripGateSkipsNonReviewGrok() {
        #expect(!SessionService.shouldStripGrokReviewClone(
            agentKind: .grok, sessionKind: .work))
        #expect(!SessionService.shouldStripGrokReviewClone(
            agentKind: .grok, sessionKind: .job))
    }

    /// A `.review` on any *other* agent must not strip `.grok/` — stripping a
    /// surface the reviewing agent doesn't load would just hide the files a
    /// hostile PR ships.
    @Test func stripGateSkipsReviewForNonGrokAgents() {
        for k: AgentKind in [.claudeCode, .codex, .cursor, .openCode] {
            #expect(!SessionService.shouldStripGrokReviewClone(
                agentKind: k, sessionKind: .review))
        }
    }

    // MARK: - Unified launch-prep gate (#861 review r17, Yellow 1 / Green 1)

    /// `prepareWorktreeForAgentLaunch` is the ONE gate every launch path (incl. the
    /// `send` RPC) routes through, so a new path can't open Grok in a review clone
    /// without stripping. It composes the strip gate + the trust seed. Verified
    /// here at the strip layer with two cases that both skip the seed — a Grok
    /// `.review` (seed gated out by `.review`) and a Cursor `.review` (Cursor has no
    /// trust store) — so the assertion touches ZERO global trust state.
    @Test func prepareStripsWhenGateFires() {
        let clone = Self.makeTempDir(name: "prep-grok-review")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let grokDir = (clone as NSString).appendingPathComponent(".grok")
        try? FileManager.default.createDirectory(
            atPath: grokDir, withIntermediateDirectories: true)
        try? "{}".write(
            toFile: (grokDir as NSString).appendingPathComponent("hooks.json"),
            atomically: true, encoding: .utf8)

        // Grok + .review → strip fires; seed is skipped (shouldSeedFolderTrust is
        // false for `.review`), so no global trust file is written by this call.
        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .grok, sessionKind: .review, worktreePath: clone, ownership: .empty)

        #expect(!FileManager.default.fileExists(atPath: grokDir))
    }

    /// The other half of the same gate: a launch whose agent/kind doesn't match the
    /// strip gate leaves a committed `.grok/` in place — the helper is a no-op strip
    /// there (and Cursor seeds nothing), so it never collaterally deletes config on
    /// a path that shouldn't. Uses Cursor to keep the call seed-free.
    @Test func prepareLeavesCloneWhenGateSkips() {
        let clone = Self.makeTempDir(name: "prep-cursor-review")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let grokDir = (clone as NSString).appendingPathComponent(".grok")
        try? FileManager.default.createDirectory(
            atPath: grokDir, withIntermediateDirectories: true)

        // Cursor + .review → strip gate false (not Grok), seed gate false (no trust
        // store): a pure no-op that leaves the tree untouched.
        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .cursor, sessionKind: .review, worktreePath: clone, ownership: .empty)

        #expect(FileManager.default.fileExists(atPath: grokDir))
    }
}
