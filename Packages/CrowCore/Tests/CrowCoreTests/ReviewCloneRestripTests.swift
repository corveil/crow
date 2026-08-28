import Foundation
import Testing
@testable import CrowCore

/// CROW-960: after `gh pr checkout`, the review skill must re-strip the union
/// of every harness's hostile config from the working tree. The command string
/// is shared with `AutoRespondCoordinator.reReviewPrompt` so the two checkout
/// paths cannot drift.
@Suite("Review clone re-strip (CROW-960)")
struct ReviewCloneRestripTests {

    @Test func bundledSkillEmitsTheSharedWorkingTreeRmCommand() throws {
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
        #expect(skill.contains(ReviewCloneRestrip.workingTreeRmCommand),
                "SKILL.md lost the CROW-960 working-tree re-strip")
        // Working-tree only: a `git rm` would stage the deletion and hide the
        // files from `git show HEAD:<path>`, which is how the agent is told to
        // review a stripped path that appears in the PR.
        #expect(skill.contains("Do **not** `git rm`"))
        #expect(skill.contains("CROW-960"))
        // Do not wipe `.claude/` — the copied skill lives under `.claude/skills/`.
        #expect(!skill.contains("rm -rf -- .claude "),
                "must not delete .claude/ wholesale")
        #expect(!skill.contains("rm -rf -- .claude\n"),
                "must not delete .claude/ wholesale")
    }
}
