import Testing
@testable import CrowCursor

@Suite("CursorLaunchArgs")
struct CursorLaunchArgsTests {
    @Test func autoPermissionOffIsEmpty() {
        #expect(CursorLaunchArgs.autoPermissionSuffix(false) == "")
    }

    @Test func autoPermissionOnIsClaudeAutoParity() {
        let s = CursorLaunchArgs.autoPermissionSuffix(true)
        // Approval off (--force) + auto-approve MCP; genuine parity with
        // Claude's `--permission-mode auto` (no sandbox) — #829 review.
        #expect(s == " --force --approve-mcps")
        // No sandbox (blocks network on job/review/Manager), no --yolo, no
        // unstable classifier, no headless-only --trust.
        #expect(s.contains("--sandbox") == false)
        #expect(s.contains("--yolo") == false)
        #expect(s.contains("--auto-review") == false)
        #expect(s.contains("--trust") == false)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CursorLaunchArgs.shellQuote("a'b") == "'a'\\''b'")
    }
}
