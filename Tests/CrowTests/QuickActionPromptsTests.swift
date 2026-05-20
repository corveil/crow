import Foundation
import Testing
import CrowCore
@testable import Crow

@Suite("QuickActionPrompts.mergePR")
struct QuickActionPromptsTests {

    @Test func githubMergeHintRunsFromTmpdirToAvoidWorktreeConflict() {
        let prompt = QuickActionPrompts.build(
            action: .mergePR,
            provider: .github,
            prURL: "https://github.com/radiusmethod/crow/pull/123",
            prNumber: 123
        )
        #expect(prompt.contains("cd \"$TMPDIR\" && gh pr merge https://github.com/radiusmethod/crow/pull/123 --squash --delete-branch"))
        #expect(prompt.contains("worktree"))
        #expect(prompt.hasSuffix("\n"))
    }

    @Test func gitlabMergeHintIsUnaffected() {
        let prompt = QuickActionPrompts.build(
            action: .mergePR,
            provider: .gitlab,
            prURL: "https://gitlab.example.com/org/repo/-/merge_requests/45",
            prNumber: 45
        )
        #expect(prompt.contains("glab mr merge https://gitlab.example.com/org/repo/-/merge_requests/45"))
        #expect(!prompt.contains("$TMPDIR"))
        #expect(prompt.hasSuffix("\n"))
    }
}
