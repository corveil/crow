import Foundation
import Testing
@testable import CrowCore

/// CROW-960: after `gh pr checkout`, the review skill must re-strip the union
/// of every harness's hostile config from the working tree. CROW-1492: it does
/// so through the daemon verb, not an agent-side `rm`. The command string is
/// shared with `AutoRespondCoordinator.reReviewPrompt` so the two checkout
/// paths cannot drift.
@Suite("Review clone re-strip (CROW-960, CROW-1492)")
struct ReviewCloneRestripTests {

    @Test func bundledSkillCallsTheDaemonRestrip() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var root: URL?
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("skills/crow-review-pr/SKILL.md").path) {
                root = dir
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let repoRoot = try #require(root, "could not locate the repo root from \(#filePath)")

        let skill = try String(
            contentsOf: repoRoot.appendingPathComponent("skills/crow-review-pr/SKILL.md"),
            encoding: .utf8)
        let template = try String(
            contentsOf: repoRoot.appendingPathComponent("Resources/crow-review-pr-SKILL.md.template"),
            encoding: .utf8)

        #expect(skill == template, "the two halves of crow-review-pr must stay byte-identical")
        #expect(skill.contains(ReviewCloneRestrip.cliCommand),
                "SKILL.md lost the CROW-1492 daemon re-strip")
        #expect(skill.contains("CROW-960"))
        #expect(skill.contains("CROW-1492"))
        // CROW-1492: the agent's own sandboxed `rm` can't remove
        // `.claude/settings*.json`, so the skill must not fall back to it.
        #expect(!skill.contains("rm -rf --"),
                "the agent-side rm is what failed under Claude Code's sandbox")
        #expect(skill.contains("Do **not** run your own `rm`, `git rm` or `git add`"))
        #expect(skill.contains("with the sandbox disabled"))
        // A failed or incomplete strip must stop the review, not fall through
        // to Step 2.
        #expect(skill.contains("**If the command fails or exits non-zero, for any reason, stop the review.**"))
        #expect(skill.contains("Review stopped: the CROW-1492 re-strip failed"))
        // The re-strip comes after checkout and before Step 2.
        let checkout = try #require(skill.range(of: #"gh pr checkout "$PR""#))
        let restrip = try #require(skill.range(of: ReviewCloneRestrip.cliCommand))
        let step2 = try #require(skill.range(of: "### Step 2:"))
        #expect(checkout.upperBound <= restrip.lowerBound)
        #expect(restrip.upperBound <= step2.lowerBound)
    }

    /// Every path the skill names as restored must be one the daemon removes.
    @Test func pathListCoversClaudeSettingsButNotClaudeDir() {
        let paths = ReviewCloneRestrip.paths
        #expect(paths.contains(".claude/settings.json"))
        #expect(paths.contains(".claude/settings.local.json"))
        // Do not wipe `.claude/`: the copied skill lives under `.claude/skills/`.
        #expect(!paths.contains(".claude"))
        #expect(!paths.contains(where: { $0.hasPrefix("/") || $0.contains("..") }),
                "paths are relative to the clone root and never climb out of it")
        #expect(Set(paths).count == paths.count)
    }
}
