import Foundation
import Testing

@testable import CrowCore

/// Coverage for `DevRootLayout` — the reserved dev-root directory names, and the
/// workspace-name validation that keeps a workspace from taking one.
///
/// A workspace named `crow-reviews` would collide with the review-clone root on
/// disk *and* capture every review session's gateway resolution through the path
/// fast path, shadowing the repo-slug fallback (PR #898 review of CROW-891).

@Test func reviewsDirNameIsReserved() {
    #expect(DevRootLayout.isReservedWorkspaceName(DevRootLayout.reviewsDirName))
}

/// Case-insensitive, because APFS is: `Crow-Reviews` is the same directory.
@Test func reservedWorkspaceNameCheckIsCaseInsensitive() {
    #expect(DevRootLayout.isReservedWorkspaceName("Crow-Reviews"))
    #expect(DevRootLayout.isReservedWorkspaceName("CROW-REVIEWS"))
}

@Test func ordinaryWorkspaceNamesAreNotReserved() {
    #expect(!DevRootLayout.isReservedWorkspaceName("Spotlight"))
    // Near-misses stay usable — the reservation is exact, not a prefix match.
    #expect(!DevRootLayout.isReservedWorkspaceName("crow-reviews-archive"))
    #expect(!DevRootLayout.isReservedWorkspaceName("crow"))
}

@Test func reviewsDirIsBuiltUnderDevRoot() {
    #expect(DevRootLayout.reviewsDir(devRoot: "/Users/dev/Dev") == "/Users/dev/Dev/crow-reviews")
}

@Test func validateNameRejectsReservedNames() {
    #expect(WorkspaceInfo.validateName("crow-reviews", existingNames: []) != nil)
    #expect(WorkspaceInfo.validateName("Crow-Reviews", existingNames: []) != nil)
}

@Test func validateNameStillAcceptsOrdinaryNames() {
    #expect(WorkspaceInfo.validateName("Spotlight", existingNames: []) == nil)
    #expect(WorkspaceInfo.validateName("crow-reviews-archive", existingNames: []) == nil)
}
