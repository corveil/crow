import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowCursor
import CrowGrok
@testable import CrowEngine

/// Coverage for `SessionService.stripPriorCompatHooksForGrokHandoff` — the
/// worker-path helper that removes a PRIOR agent's Crow-managed hook config from
/// the Claude/Cursor compat sources Grok also loads, so a `.work`/`.job` handoff
/// to Grok doesn't double-fire every hook event (#861 review r8).
///
/// Uses the real writers to plant managed configs (a round-trip, so the test
/// doesn't couple to the writers' internal JSON), then asserts the helper
/// neutralizes those layers while leaving Grok's own `.grok/hooks/crow.json`
/// (the incoming config) and a user's own settings intact.
@Suite("Grok handoff compat-hook strip")
struct SessionServiceGrokHandoffHookStripTests {

    private static func makeTempDir() -> String {
        let base = NSTemporaryDirectory() as NSString
        let dir = base.appendingPathComponent("crow-grok-handoff-hooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True when `.claude/settings.local.json` still carries a non-empty `hooks`
    /// block — the double-fire source we expect the strip to clear.
    private static func hasCrowHooks(inClaudeSettingsAt path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return !hooks.isEmpty
    }

    /// A Claude→Grok handoff worktree: the prior Claude session's managed
    /// `.claude/settings.local.json` hooks are stripped, while Grok's own
    /// `.grok/hooks/crow.json` (the incoming config, a separate file) survives.
    @Test func stripsPriorClaudeHooksKeepsGrokConfig() throws {
        let wt = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: wt) }
        let sid = UUID()
        try ClaudeHookConfigWriter().writeHookConfig(
            worktreePath: wt, sessionID: sid, crowPath: "/usr/local/bin/crow")
        try GrokHookConfigWriter().writeHookConfig(
            worktreePath: wt, sessionID: sid, crowPath: "/usr/local/bin/crow")
        let claudeSettings = (wt as NSString)
            .appendingPathComponent(".claude/settings.local.json")
        let grokHook = (wt as NSString).appendingPathComponent(".grok/hooks/crow.json")
        #expect(Self.hasCrowHooks(inClaudeSettingsAt: claudeSettings))
        #expect(FileManager.default.fileExists(atPath: grokHook))

        SessionService.stripPriorCompatHooksForGrokHandoff(worktreePath: wt)

        // Claude's managed hooks gone (no double-fire source left); Grok's own
        // hook config untouched.
        #expect(!Self.hasCrowHooks(inClaudeSettingsAt: claudeSettings))
        #expect(FileManager.default.fileExists(atPath: grokHook))
    }

    /// A Cursor→Grok handoff worktree: the prior `.cursor/hooks.json` (only Crow
    /// groups present) is neutralized — Cursor's remover deletes the file once
    /// nothing but its scaffold remains.
    @Test func stripsPriorCursorHooks() throws {
        let wt = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: wt) }
        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: wt, sessionID: UUID(), crowPath: "/usr/local/bin/crow")
        let cursorHooks = (wt as NSString).appendingPathComponent(".cursor/hooks.json")
        #expect(FileManager.default.fileExists(atPath: cursorHooks))

        SessionService.stripPriorCompatHooksForGrokHandoff(worktreePath: wt)

        #expect(!FileManager.default.fileExists(atPath: cursorHooks))
    }

    /// Idempotent: a worktree that never ran Claude/Cursor (prior Codex/OpenCode,
    /// or a fresh clone) has nothing to strip, so the handoff arm can call the
    /// helper unconditionally — it's a harmless no-op that leaves the tree alone.
    @Test func noOpsWhenNoPriorCompatHooks() {
        let wt = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: wt) }
        let marker = (wt as NSString).appendingPathComponent("README.md")
        try? "hi".write(toFile: marker, atomically: true, encoding: .utf8)

        SessionService.stripPriorCompatHooksForGrokHandoff(worktreePath: wt)

        #expect(FileManager.default.fileExists(atPath: wt))
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    /// A user's own non-managed key in `.claude/settings.local.json` survives —
    /// the strip is marker-scoped (only Crow's managed event entries), not the
    /// wholesale wipe the review-clone path performs. Guards against neutering a
    /// real work worktree's user config on handoff.
    @Test func preservesUserSettingsInClaudeFile() throws {
        let wt = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: wt) }
        try ClaudeHookConfigWriter().writeHookConfig(
            worktreePath: wt, sessionID: UUID(), crowPath: "/usr/local/bin/crow")
        let claudeSettings = (wt as NSString)
            .appendingPathComponent(".claude/settings.local.json")
        // Splice a user-owned top-level key alongside Crow's managed hooks.
        var json = ((try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: claudeSettings))))
            as? [String: Any]) ?? [:]
        json["userKey"] = "keepme"
        try JSONSerialization.data(withJSONObject: json)
            .write(to: URL(fileURLWithPath: claudeSettings))

        SessionService.stripPriorCompatHooksForGrokHandoff(worktreePath: wt)

        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: claudeSettings)))) as? [String: Any]
        #expect(after?["userKey"] as? String == "keepme")
        #expect(!Self.hasCrowHooks(inClaudeSettingsAt: claudeSettings))
    }
}
