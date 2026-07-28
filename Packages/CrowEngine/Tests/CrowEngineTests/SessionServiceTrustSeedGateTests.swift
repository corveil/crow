import Testing
import CrowCore
@testable import CrowEngine

/// Pure-gate tests for `SessionService.shouldSeedFolderTrust` — the predicate the
/// four launch paths (launchAgent, handoffAgent, createManagerTerminal, and the
/// `pasteDeferredLaunch` new-terminal path) share so folder trust is seeded
/// consistently and NEVER on a `.review` clone (#861 review r11). Kept pure so the
/// gate is testable without touching the user's real global trust files.
@Suite("SessionService folder-trust seed gate")
struct SessionServiceTrustSeedGateTests {

    /// Claude seeds on every session kind (its trust file is the only launch gate),
    /// including `.review` — matching the pre-existing unconditional Claude arm.
    @Test func claudeSeedsEveryKind() {
        for k: SessionKind in [.work, .job, .review, .manager] {
            #expect(SessionService.shouldSeedFolderTrust(agentKind: .claudeCode, sessionKind: k))
        }
    }

    /// Codex and Grok seed `.work`/`.job`/`.manager` but NEVER a `.review` clone
    /// (attacker-controlled `gh repo clone` head — trusting it would arm a
    /// committed hook on launch).
    @Test func codexAndGrokSkipReviewOnly() {
        for kind: AgentKind in [.codex, .grok] {
            #expect(SessionService.shouldSeedFolderTrust(agentKind: kind, sessionKind: .work))
            #expect(SessionService.shouldSeedFolderTrust(agentKind: kind, sessionKind: .job))
            #expect(SessionService.shouldSeedFolderTrust(agentKind: kind, sessionKind: .manager))
            #expect(!SessionService.shouldSeedFolderTrust(agentKind: kind, sessionKind: .review))
        }
    }

    /// Agents with no folder-trust store never seed.
    @Test func trustlessAgentsNeverSeed() {
        for kind: AgentKind in [.cursor, .openCode, .antigravity] {
            for k: SessionKind in [.work, .job, .review, .manager] {
                #expect(!SessionService.shouldSeedFolderTrust(agentKind: kind, sessionKind: k))
            }
        }
    }

    // MARK: - Compat-settings gate (#861 review r18, Yellow 2)

    /// Only Grok and Codex compat-load Crow's `.claude/settings.local.json`, so
    /// only they get the gateway-env *clear* on a non-Claude launch. Claude takes
    /// the *write* arm, not the clear arm, so it is intentionally NOT a compat
    /// reader here.
    @Test func onlyGrokAndCodexReadClaudeCompatSettings() {
        #expect(SessionService.readsClaudeCompatSettings(.grok))
        #expect(SessionService.readsClaudeCompatSettings(.codex))
    }

    /// Cursor/OpenCode/Antigravity never read the file, so the clear must skip them
    /// — clearing it there would be a pure rewrite (churn + a data-loss risk on a
    /// user's hand-edited `permissions`). Claude is excluded too (it writes, not
    /// clears).
    @Test func nonCompatKindsDoNotReadClaudeSettings() {
        for kind: AgentKind in [.claudeCode, .cursor, .openCode, .antigravity] {
            #expect(!SessionService.readsClaudeCompatSettings(kind))
        }
    }
}
