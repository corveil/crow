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
        // With seedTrust on: the `--trust` seed leads, auto-permission gates on
        // its own toggle and follows.
        #expect(CursorLaunchArgs.launchSuffix(seedTrust: true, autoPermissionMode: false) == " --trust")
        #expect(CursorLaunchArgs.launchSuffix(seedTrust: true, autoPermissionMode: true) == " --trust --force --approve-mcps")
        // Still bounded to workspace trust — never the full-bypass --yolo.
        #expect(CursorLaunchArgs.launchSuffix(seedTrust: true, autoPermissionMode: true).contains("--yolo") == false)
    }

    @Test func launchSuffixWithholdsTrustForReviewClones() {
        // seedTrust=false (the `.review` case) drops `--trust` entirely while
        // still honoring auto-permission — mirrors the Codex `!= .review` guard
        // so an attacker-controlled review clone is never auto-trusted (CROW-890
        // review, Red 1).
        #expect(CursorLaunchArgs.launchSuffix(seedTrust: false, autoPermissionMode: false) == "")
        #expect(CursorLaunchArgs.launchSuffix(seedTrust: false, autoPermissionMode: true) == " --force --approve-mcps")
        #expect(CursorLaunchArgs.launchSuffix(seedTrust: false, autoPermissionMode: true).contains("--trust") == false)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CursorLaunchArgs.shellQuote("a'b") == "'a'\\''b'")
    }
}
