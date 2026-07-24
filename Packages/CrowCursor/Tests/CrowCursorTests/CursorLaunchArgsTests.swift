import Testing
@testable import CrowCursor

@Suite("CursorLaunchArgs")
struct CursorLaunchArgsTests {
    @Test func autoPermissionOffIsEmpty() {
        #expect(CursorLaunchArgs.autoPermissionSuffix(false) == "")
    }

    @Test func autoPermissionOnIsBounded() {
        let s = CursorLaunchArgs.autoPermissionSuffix(true)
        // Bounded default: approval off (--force) but sandbox ON (#829).
        #expect(s == " --force --sandbox enabled --approve-mcps --trust")
        // Not the unbounded posture, not the unstable classifier.
        #expect(s.contains("--yolo") == false)
        #expect(s.contains("--sandbox disabled") == false)
        #expect(s.contains("--auto-review") == false)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CursorLaunchArgs.shellQuote("a'b") == "'a'\\''b'")
    }
}
