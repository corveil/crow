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

    /// The strip is scoped to `.grok/` — a sibling agent's config (`.codex/`,
    /// the review prompt) survives, so stripping for a Grok review never
    /// collaterally hides another surface.
    @Test func leavesSiblingConfigUntouched() {
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
