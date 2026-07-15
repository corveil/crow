import Foundation
import SwiftUI
import Testing
@testable import CrowCore
@testable import CrowUI

// MARK: - SettingsView.runCorveilVersion (CROW-482)

@Suite("SettingsView.runCorveilVersion")
struct RunCorveilVersionTests {

    @Test func nonExecutablePathReturnsError() {
        let result = SettingsView.runCorveilVersion(at: "/this/path/definitely/does/not/exist")
        #expect(result.hasPrefix("✗ Not executable:"))
    }

    @Test func emptyPathReturnsError() {
        // isExecutableFile returns false for "", so the gate still trips.
        let result = SettingsView.runCorveilVersion(at: "")
        #expect(result.hasPrefix("✗ Not executable:"))
    }

    @Test func zeroExitWithNoOutputFormatsAsVerified() {
        // /usr/bin/true ignores arguments and exits 0 with no stdout/stderr.
        let result = SettingsView.runCorveilVersion(at: "/usr/bin/true")
        #expect(result == "✓ Verified")
    }

    @Test func nonZeroExitWithNoOutputSurfacesExitCode() {
        // /usr/bin/false ignores arguments and exits 1 with no stdout/stderr.
        let result = SettingsView.runCorveilVersion(at: "/usr/bin/false")
        #expect(result == "✗ exit code 1")
    }

    @Test func zeroExitWithStdoutShowsSnippet() {
        // /bin/echo --version → exits 0, prints "--version\n" to stdout.
        let result = SettingsView.runCorveilVersion(at: "/bin/echo")
        #expect(result == "✓ --version")
    }
}

// MARK: - SessionStatus Display Names

@Test func sessionStatusDisplayNames() {
    #expect(SessionStatus.active.displayName == "Active")
    #expect(SessionStatus.paused.displayName == "Paused")
    #expect(SessionStatus.inReview.displayName == "In Review")
    #expect(SessionStatus.completed.displayName == "Completed")
    #expect(SessionStatus.archived.displayName == "Archived")
}

// MARK: - TicketStatus Colors

@Test func ticketStatusColorsAreDefined() {
    for status in TicketStatus.allCases {
        _ = status.color
    }
}

@Test func ticketStatusIcons() {
    #expect(TicketStatus.backlog.icon == "tray")
    #expect(TicketStatus.ready.icon == "flag.fill")
    #expect(TicketStatus.inProgress.icon == "bolt.fill")
    #expect(TicketStatus.inReview.icon == "eye.fill")
    #expect(TicketStatus.done.icon == "checkmark.circle.fill")
    #expect(TicketStatus.unknown.icon == "questionmark.circle")
}

// MARK: - PR Check/Review Status Extensions

@Test func checkStatusIcons() {
    #expect(PRStatus.CheckStatus.passing.icon == "checkmark.circle.fill")
    #expect(PRStatus.CheckStatus.failing.icon == "xmark.circle.fill")
    #expect(PRStatus.CheckStatus.pending.icon == "clock.fill")
    #expect(PRStatus.CheckStatus.unknown.icon == "questionmark.circle")
}

@Test func checkStatusLabels() {
    #expect(PRStatus.CheckStatus.passing.label == "Checks pass")
    #expect(PRStatus.CheckStatus.failing.label == "Checks failing")
    #expect(PRStatus.CheckStatus.pending.label == "Checks running")
    #expect(PRStatus.CheckStatus.unknown.label == "No checks")
}

@Test func reviewStatusIcons() {
    #expect(PRStatus.ReviewStatus.approved.icon == "person.crop.circle.badge.checkmark")
    #expect(PRStatus.ReviewStatus.changesRequested.icon == "person.crop.circle.badge.exclamationmark")
    #expect(PRStatus.ReviewStatus.reviewRequired.icon == "person.crop.circle.badge.clock")
    #expect(PRStatus.ReviewStatus.unknown.icon == "person.crop.circle")
}

@Test func reviewStatusLabels() {
    #expect(PRStatus.ReviewStatus.approved.label == "Approved")
    #expect(PRStatus.ReviewStatus.changesRequested.label == "Changes requested")
    #expect(PRStatus.ReviewStatus.reviewRequired.label == "Needs review")
    #expect(PRStatus.ReviewStatus.unknown.label == "No reviews")
}

// MARK: - Branch Shortening

@Test func shortenBranchStripsFeaturePrefix() {
    #expect(shortenBranch("feature/crow-73-quality-pass") == "crow-73-quality-pass")
}

@Test func shortenBranchStripsRefsHeads() {
    #expect(shortenBranch("refs/heads/main") == "main")
}

@Test func shortenBranchStripsBothPrefixes() {
    #expect(shortenBranch("refs/heads/feature/my-branch") == "my-branch")
}

@Test func shortenBranchLeavesPlainBranch() {
    #expect(shortenBranch("main") == "main")
}

// MARK: - Helper to create test worktrees

private func makeWorktree(
    repoPath: String = "/repo",
    repoName: String = "repo",
    worktreePath: String = "/worktree",
    branch: String = "feature/test"
) -> SessionWorktree {
    SessionWorktree(
        sessionID: UUID(),
        repoName: repoName,
        repoPath: repoPath,
        worktreePath: worktreePath,
        branch: branch
    )
}

// MARK: - Worktree Classification (uses SessionWorktree.isMainRepoCheckout from CrowCore)

@Test func isMainCheckoutDetectsMatchingPaths() {
    let wt = makeWorktree(
        repoPath: "/Users/test/Dev/Org/repo",
        worktreePath: "/Users/test/Dev/Org/repo",
        branch: "feature/something"
    )
    #expect(wt.isMainRepoCheckout == true)
}

@Test func isMainCheckoutDetectsProtectedBranches() {
    let protectedBranches = ["main", "master", "develop", "dev", "trunk", "release"]
    for branch in protectedBranches {
        let wt = makeWorktree(branch: branch)
        #expect(wt.isMainRepoCheckout == true, "Expected \(branch) to be a main checkout")
    }
}

@Test func isMainCheckoutDetectsProtectedBranchesWithPrefix() {
    let wt = makeWorktree(branch: "refs/heads/main")
    #expect(wt.isMainRepoCheckout == true)
}

@Test func isMainCheckoutReturnsFalseForFeatureBranch() {
    let wt = makeWorktree(branch: "feature/crow-73-quality-pass")
    #expect(wt.isMainRepoCheckout == false)
}

// MARK: - Delete Session Message Logic

@Test func deleteMessageForSessionWithoutWorktrees() {
    let text = DeleteSessionMessageBuilder.buildMessage(
        sessionName: "test-session",
        realWorktrees: [],
        mainCheckouts: []
    )
    #expect(text == "This will remove the session \"test-session\".")
}

@Test func deleteMessageForSessionWithOnlyMainCheckout() {
    let wt = makeWorktree(
        repoPath: "/repo",
        worktreePath: "/repo",
        branch: "main"
    )
    let text = DeleteSessionMessageBuilder.buildMessage(
        sessionName: "test",
        realWorktrees: [],
        mainCheckouts: [wt]
    )
    #expect(text.contains("will not be affected"))
}

@Test func deleteButtonLabelReflectsWorktrees() {
    #expect(DeleteSessionMessageBuilder.buttonLabel(hasRealWorktrees: true) == "Delete Everything")
    #expect(DeleteSessionMessageBuilder.buttonLabel(hasRealWorktrees: false) == "Remove Session")
}

// MARK: - Bulk Delete Message Logic

@Test func bulkMessageForSessionsWithoutWorktrees() {
    let sessions = [
        Session(name: "alpha"),
        Session(name: "bravo"),
        Session(name: "charlie")
    ]
    let text = DeleteSessionMessageBuilder.buildBulkMessage(
        sessions: sessions,
        worktreesBySession: [:]
    )
    #expect(text == "This will remove 3 sessions.")
}

@Test func bulkMessageForSingleSessionUsesSingularNoun() {
    let session = Session(name: "solo")
    let text = DeleteSessionMessageBuilder.buildBulkMessage(
        sessions: [session],
        worktreesBySession: [:]
    )
    #expect(text == "This will remove 1 session.")
}

@Test func bulkMessageWithRealWorktreesMentionsCounts() {
    let session = Session(name: "feat")
    let wt = SessionWorktree(
        sessionID: session.id,
        repoName: "repo",
        repoPath: "/repo",
        worktreePath: "/worktrees/feat",
        branch: "feature/test"
    )
    let text = DeleteSessionMessageBuilder.buildBulkMessage(
        sessions: [session],
        worktreesBySession: [session.id: [wt]]
    )
    #expect(text.contains("This will delete 1 session."))
    #expect(text.contains("1 worktree"))
    #expect(text.contains("removed from disk"))
}

@Test func bulkMessageWithMixedWorktreesMentionsBoth() {
    let s1 = Session(name: "feat-a")
    let s2 = Session(name: "feat-b")
    let realWt = SessionWorktree(
        sessionID: s1.id,
        repoName: "repo",
        repoPath: "/repo",
        worktreePath: "/worktrees/feat-a",
        branch: "feature/a"
    )
    let mainWt = SessionWorktree(
        sessionID: s2.id,
        repoName: "repo",
        repoPath: "/repo",
        worktreePath: "/repo",
        branch: "main"
    )
    let text = DeleteSessionMessageBuilder.buildBulkMessage(
        sessions: [s1, s2],
        worktreesBySession: [s1.id: [realWt], s2.id: [mainWt]]
    )
    #expect(text.contains("This will delete 2 sessions."))
    #expect(text.contains("1 worktree"))
    #expect(text.contains("1 main repo checkout will not be affected"))
}

@Test func bulkMessageWithOnlyMainCheckoutsSkipsRealWorktreeLine() {
    let session = Session(name: "main-only")
    let mainWt = SessionWorktree(
        sessionID: session.id,
        repoName: "repo",
        repoPath: "/repo",
        worktreePath: "/repo",
        branch: "main"
    )
    let text = DeleteSessionMessageBuilder.buildBulkMessage(
        sessions: [session],
        worktreesBySession: [session.id: [mainWt]]
    )
    #expect(text.contains("This will delete 1 session."))
    #expect(text.contains("will not be affected"))
    #expect(!text.contains("removed from disk"))
}

// MARK: - Label Pill Accent Color (WCAG AA)
//
// Verifies that `CorveilTheme.accentRGB(for:in:)` — the math behind the dark-
// mode label pill fix — produces text/border colors that clear the WCAG AA
// contrast thresholds against the chip fill and page background in both color
// schemes. The "blue" sample is the documented edge case (low blue-channel
// weighting in relative luminance); if it fails, raise the dark-mode lightness
// clamp.

private typealias RGB = (r: Double, g: Double, b: Double)
private let darkPillFill: RGB  = (33.0 / 255, 38.0 / 255, 45.0 / 255)   // #21262D
private let lightPillFill: RGB = (234.0 / 255, 238.0 / 255, 242.0 / 255) // #EAEEF2
private let darkPageBg: RGB    = (26.0 / 255, 29.0 / 255, 32.0 / 255)   // #1A1D20 = bgSurface

private func relativeLuminance(_ c: RGB) -> Double {
    func lin(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

private func contrast(_ a: RGB, _ b: RGB) -> Double {
    let la = relativeLuminance(a) + 0.05
    let lb = relativeLuminance(b) + 0.05
    return la > lb ? la / lb : lb / la
}

/// Hex string + human label for diagnostic messages.
private let canonicalLabels: [(name: String, hex: String)] = [
    ("yellow",     "FBCA04"),
    ("dark green", "0E8A16"),
    ("orange",     "D93F0B"),
    ("blue",       "0366D6"),
    ("near-white", "F5F5F5"),
    ("near-black", "111111"),
]

@Test func accentColorClearsAATextOnDarkFill() throws {
    for label in canonicalLabels {
        let rgb = try #require(CorveilTheme.accentRGB(for: label.hex, in: .dark))
        let ratio = contrast(rgb, darkPillFill)
        #expect(ratio >= 4.5, "Dark accent for \(label.name) (#\(label.hex)) only \(ratio):1 vs #21262D")
    }
}

@Test func accentColorClearsAATextOnLightFill() throws {
    for label in canonicalLabels {
        let rgb = try #require(CorveilTheme.accentRGB(for: label.hex, in: .light))
        let ratio = contrast(rgb, lightPillFill)
        #expect(ratio >= 4.5, "Light accent for \(label.name) (#\(label.hex)) only \(ratio):1 vs #EAEEF2")
    }
}

@Test func accentColorBorderClears3to1OnDarkPageBackground() throws {
    for label in canonicalLabels {
        let rgb = try #require(CorveilTheme.accentRGB(for: label.hex, in: .dark))
        let ratio = contrast(rgb, darkPageBg)
        #expect(ratio >= 3.0, "Dark border for \(label.name) (#\(label.hex)) only \(ratio):1 vs #1A1D20")
    }
}

@Test func accentRGBReturnsNilForInvalidHex() {
    #expect(CorveilTheme.accentRGB(for: "xyz", in: .dark) == nil)
    #expect(CorveilTheme.accentRGB(for: "12345", in: .dark) == nil)
    #expect(CorveilTheme.accentRGB(for: "GGGGGG", in: .light) == nil)
    #expect(CorveilTheme.accentRGB(for: "", in: .light) == nil)
}

@Test func accentRGBStripsLeadingHash() throws {
    let withHash = try #require(CorveilTheme.accentRGB(for: "#0E8A16", in: .dark))
    let without  = try #require(CorveilTheme.accentRGB(for: "0E8A16",  in: .dark))
    #expect(abs(withHash.r - without.r) < 1e-9)
    #expect(abs(withHash.g - without.g) < 1e-9)
    #expect(abs(withHash.b - without.b) < 1e-9)
}

@Test func accentRGBLightensDarkHuesInDarkMode() throws {
    // Near-black input must be pulled up well above black so it reads on a dark fill.
    let rgb = try #require(CorveilTheme.accentRGB(for: "111111", in: .dark))
    #expect(relativeLuminance(rgb) > relativeLuminance(darkPillFill))
}

@Test func accentRGBDarkensPaleHuesInLightMode() throws {
    // Near-white input must be pulled down so it reads on a light fill.
    let rgb = try #require(CorveilTheme.accentRGB(for: "F5F5F5", in: .light))
    #expect(relativeLuminance(rgb) < relativeLuminance(lightPillFill))
}

@Test func hslRoundTripPreservesCanonicalLabelColors() {
    let cases: [RGB] = [
        (0.984, 0.792, 0.016), // FBCA04
        (0.055, 0.541, 0.086), // 0E8A16
        (0.852, 0.247, 0.043), // D93F0B
        (0.012, 0.400, 0.839), // 0366D6
    ]
    for orig in cases {
        let hsl = CorveilTheme.rgbToHSL(r: orig.r, g: orig.g, b: orig.b)
        let back = CorveilTheme.hslToRGB(h: hsl.h, s: hsl.s, l: hsl.l)
        #expect(abs(back.r - orig.r) < 0.01)
        #expect(abs(back.g - orig.g) < 0.01)
        #expect(abs(back.b - orig.b) < 0.01)
    }
}

@Test func hslAchromaticInputReturnsGrayWithZeroSaturation() {
    let hsl = CorveilTheme.rgbToHSL(r: 0.5, g: 0.5, b: 0.5)
    #expect(hsl.s == 0)
    #expect(abs(hsl.l - 0.5) < 1e-9)
}

// MARK: - TokenListEditor.adding (CROW-513)

@Suite("TokenListEditor.adding")
struct TokenListEditorAddingTests {
    @Test func trimsWhitespace() {
        #expect(TokenListEditor.adding("  foo  ", to: []) == ["foo"])
    }

    @Test func ignoresEmptyAndWhitespaceOnly() {
        #expect(TokenListEditor.adding("   ", to: []) == [])
        #expect(TokenListEditor.adding("", to: ["a"]) == ["a"])
        #expect(TokenListEditor.adding(", ,", to: []) == [])
    }

    @Test func splitsOnCommas() {
        #expect(TokenListEditor.adding("a, b, c", to: []) == ["a", "b", "c"])
    }

    @Test func dedupesAgainstExistingCaseSensitive() {
        #expect(TokenListEditor.adding("a", to: ["a"]) == ["a"])
        #expect(TokenListEditor.adding("A", to: ["a"]) == ["a", "A"])
    }

    @Test func dedupesWithinSameCommit() {
        #expect(TokenListEditor.adding("x, x, y", to: []) == ["x", "y"])
    }

    @Test func appendsPreservingOrder() {
        #expect(TokenListEditor.adding("b, c", to: ["a"]) == ["a", "b", "c"])
    }

    @Test func trailingCommaProducesOneToken() {
        #expect(TokenListEditor.adding("foo,", to: []) == ["foo"])
    }
}
