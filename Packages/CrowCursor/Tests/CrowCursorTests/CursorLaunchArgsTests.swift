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
        // unstable classifier. `--trust` is intentionally absent *here* — the
        // trust seed is a separate, unconditional suffix (see trustSuffix /
        // launchSuffix), not an auto-permission flag.
        #expect(s.contains("--sandbox") == false)
        #expect(s.contains("--yolo") == false)
        #expect(s.contains("--auto-review") == false)
        #expect(s.contains("--trust") == false)
    }

    @Test func trustSuffixIsWorkspaceTrust() {
        // Unconditional per-launch workspace-trust seed — the analogue of
        // ClaudeTrustSeeder; interactive since Cursor CLI 2026.07.20, verified
        // against agent 2026.07.23 (CROW-890).
        #expect(CursorLaunchArgs.trustSuffix == " --trust")
    }

    @Test func launchSuffixSeedsTrustThenAutoPermission() {
        // Trust seed is unconditional; the auto-permission flags gate on the
        // caller's toggle and follow the seed.
        #expect(CursorLaunchArgs.launchSuffix(autoPermissionMode: false) == " --trust")
        #expect(CursorLaunchArgs.launchSuffix(autoPermissionMode: true) == " --trust --force --approve-mcps")
        // Still bounded to workspace trust — never the full-bypass --yolo.
        #expect(CursorLaunchArgs.launchSuffix(autoPermissionMode: true).contains("--yolo") == false)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CursorLaunchArgs.shellQuote("a'b") == "'a'\\''b'")
    }
}
