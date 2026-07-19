import Foundation
import Testing
@testable import CrowEngine

/// Covers the disk-cleanup branch hit when a review session is deleted.
/// Regression guard for #305: review clones were being skipped because
/// `isMainCheckout` was checked before the `isReview` branch.
@Suite("SessionService.performDiskCleanup")
struct SessionServiceDiskCleanupTests {

    private static func makeTempDir(name: String = "crow-cleanup-test") -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func deletesReviewClone() {
        let clone = Self.makeTempDir(name: "review-clone")
        defer { try? FileManager.default.removeItem(at: clone) }

        // Matches how `deleteSession` builds the item for review sessions:
        // repoPath == worktreePath == clonePath, isMainCheckout: true (because
        // SessionWorktree.isMainRepoCheckout returns true when the paths match).
        let item = SessionService.WorktreeCleanupItem(
            repoPath: clone.path,
            worktreePath: clone.path,
            branch: "feature/some-pr",
            isMainCheckout: true
        )

        let error = SessionService.performDiskCleanup(items: [item], isReview: true)

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: clone.path))
    }

    @Test func reviewCleanupIsIdempotent() {
        let clone = Self.makeTempDir(name: "review-clone-gone")
        try? FileManager.default.removeItem(at: clone)
        #expect(!FileManager.default.fileExists(atPath: clone.path))

        let item = SessionService.WorktreeCleanupItem(
            repoPath: clone.path,
            worktreePath: clone.path,
            branch: "feature/some-pr",
            isMainCheckout: true
        )

        let error = SessionService.performDiskCleanup(items: [item], isReview: true)

        #expect(error == nil)
    }

    @Test func nonReviewMainCheckoutIsSkipped() {
        let checkout = Self.makeTempDir(name: "main-checkout")
        defer { try? FileManager.default.removeItem(at: checkout) }

        let item = SessionService.WorktreeCleanupItem(
            repoPath: checkout.path,
            worktreePath: checkout.path,
            branch: "main",
            isMainCheckout: true
        )

        let error = SessionService.performDiskCleanup(items: [item], isReview: false)

        #expect(error == nil)
        #expect(FileManager.default.fileExists(atPath: checkout.path))
    }

    @Test func reviewCleanupDoesNotRemoveParent() {
        let parent = Self.makeTempDir(name: "reviews-parent")
        defer { try? FileManager.default.removeItem(at: parent) }
        let clone = parent.appendingPathComponent("repo-pr-123")
        try? FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)

        let item = SessionService.WorktreeCleanupItem(
            repoPath: clone.path,
            worktreePath: clone.path,
            branch: "feature/some-pr",
            isMainCheckout: true
        )

        let error = SessionService.performDiskCleanup(items: [item], isReview: true)

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: clone.path))
        #expect(FileManager.default.fileExists(atPath: parent.path))
    }
}
