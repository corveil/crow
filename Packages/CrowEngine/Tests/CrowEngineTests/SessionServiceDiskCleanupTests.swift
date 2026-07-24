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

    /// A worker-run scratch dir has the same standalone shape as a review clone
    /// (repoPath == worktreePath, isMainCheckout true) and holds the scoped
    /// CORVEIL_API_KEY, so `isWorkerRun` must remove it wholesale rather than
    /// skip it as a "main checkout" (corveil/crow#801 review — the Red finding).
    /// A scratch dir under `.crow-worker-runs` is removed wholesale despite the
    /// main-checkout shape (repoPath == worktreePath, isMainCheckout true).
    @Test func deletesWorkerRunScratchDirDespiteMainCheckoutShape() {
        let root = Self.makeTempDir(name: "wr-dev").appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-abc")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Seed the secret file the finding is about.
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("settings.local.json").path,
            contents: Data(#"{"env":{"CORVEIL_API_KEY":"sk-secret"}}"#.utf8))

        let item = SessionService.WorktreeCleanupItem(
            repoPath: scratch.path,
            worktreePath: scratch.path,
            branch: "",
            isMainCheckout: true  // synthetic worktree trips this; must be overridden
        )

        let error = SessionService.performDiskCleanup(items: [item], isReview: false, isWorkerRun: true)

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    /// The same parent-name guard as `wipeWorkerRunScratch` applies here: a
    /// worker-run item whose path is NOT under `.crow-worker-runs` is refused, so
    /// a corrupted `worktreePath` can't trigger an arbitrary recursive delete
    /// (review — consistent threat model across both teardown paths).
    @Test func refusesWorkerRunRemovalOutsideCrowWorkerRuns() {
        let victim = Self.makeTempDir(name: "not-a-scratch")
        defer { try? FileManager.default.removeItem(at: victim) }
        let item = SessionService.WorktreeCleanupItem(
            repoPath: victim.path, worktreePath: victim.path, branch: "", isMainCheckout: true
        )

        let error = SessionService.performDiskCleanup(items: [item], isReview: false, isWorkerRun: true)

        #expect(error == nil)  // refusal is not a fatal cleanup error
        #expect(FileManager.default.fileExists(atPath: victim.path))  // NOT removed
    }

    @Test func workerRunCleanupIsIdempotentWhenAlreadyGone() {
        let scratch = Self.makeTempDir(name: "wr-dev-gone")
            .appendingPathComponent(".crow-worker-runs").appendingPathComponent("run-gone")
        // Never created — parent-name is valid but the dir doesn't exist.
        let item = SessionService.WorktreeCleanupItem(
            repoPath: scratch.path, worktreePath: scratch.path, branch: "", isMainCheckout: true
        )
        let error = SessionService.performDiskCleanup(items: [item], isReview: false, isWorkerRun: true)
        #expect(error == nil)
    }
}
