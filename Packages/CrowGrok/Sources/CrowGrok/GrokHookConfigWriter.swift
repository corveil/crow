import Foundation
import CrowCore

/// Writes Grok Build's hook configuration into a worktree's
/// `.grok/hooks/crow.json`. Conforms to `HookConfigWriter` so the engine can
/// treat the configuration step generically; the concrete event list and file
/// format stay local to CrowGrok.
///
/// **Why a per-worktree, per-session file (the good tier).** Grok discovers
/// project hooks from `<project>/.grok/hooks/*.json` (a *directory* of JSON
/// files, all merged), verified against `xai-org/grok-build@main`
/// (`crates/codegen/xai-grok-hooks/src/discovery.rs`, 2026-07-25). Each file's
/// `hooks` map is Claude/Cursor-compatible:
///
/// ```json
/// { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
///   "command": "<crow> hook-event --session <UUID> --event Stop",
///   "timeout": 5 } ] } ] } }
/// ```
///
/// So Crow bakes the session UUID into the command and the server resolves the
/// session **by UUID** — exact, no `cwd` matching (the same good tier as
/// Claude/Cursor; better than Codex/OpenCode's `cwd`-match fallback). Because
/// `crow.json` is a dedicated Crow-owned file (a user's own hooks live in other
/// `*.json` files in the same dir, which Grok merges alongside), it is
/// overwritten wholesale — there is nothing to merge-preserve.
///
/// ⚠️ **Trust caveat.** Project-scoped Grok hooks *require folder trust*
/// (`~/.grok/trusted_folders.toml`) on a release build; a fresh worktree/clone
/// would otherwise have its hooks silently skipped. `GrokTrustSeeder` seeds
/// trust for Crow-created `.work`/`.job` worktrees (never `.review` clones —
/// see that type). On a local/dev build folder-trust is inert (everything
/// trusted), which is why `prepareReviewClone` *also* strips a committed
/// `.grok/` from an attacker-controlled review head as defense-in-depth.
///
/// **Version-pinned re-check target (#859):** the project handed-off-worktree
/// double-fire — a prior agent's `.claude/settings.local.json` / `.cursor/hooks.json`
/// that Grok compat-loads alongside `.grok/hooks/crow.json` — is now **closed**:
/// `SessionService.stripPriorCompatHooksForGrokHandoff` strips it on handoff, and
/// the warm-adopt path writes the session's *own* agent config instead of
/// hardcoding Claude's (#861 review r9-r10). What remains deferred is only the
/// **global** `~/.claude/settings.json` / `~/.cursor/hooks.json` Grok also
/// discovers — genuinely user-controlled, no Crow session UUID, cf. Codex §3b —
/// plus the Grok-**Manager** devRoot case (documented at
/// `SessionService.writeManagerHookConfig`). **Also re-probe (#861 review r19):**
/// does Grok's Claude-compat loader resolve `.claude/settings.local.json` by
/// walking *ancestor* directories the way Claude Code itself does? Crow's
/// per-worktree gateway-env clear (`SessionService.readsClaudeCompatSettings`)
/// assumes project scope; if Grok walks up the tree, a Grok worker at
/// `{devRoot}/{workspace}/…` could still inherit a Claude Manager's bearer from
/// `{devRoot}/.claude/settings.local.json` regardless of the worktree-level clear
/// (would apply equally to Codex — not Crow-specific). Unverifiable without
/// `grok-build` source; confirm on the next mirror sync. Re-probe all of the
/// above on each upstream mirror sync.
public struct GrokHookConfigWriter: HookConfigWriter {

    /// All hook event names we register. Every name is verified present in
    /// `xai-grok-hooks/src/event.rs` (2026-07-25). `GrokSignalSource` handles
    /// exactly this set.
    static let allEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Notification", "Stop", "StopFailure",
    ]

    /// Grok's hook runtime async-delivery support is unverified, so — like
    /// Codex — we register everything synchronously. Sync `PreToolUse` keeps
    /// *arrival* ordering (it is accepted before a following permission event).
    /// Note (#903): since `crow hook-event` is fire-and-forget, arrival order no
    /// longer implies apply order — see the "Hook async delivery" apply-order
    /// caveat in docs/agent-harness-matrix.md. Kept as a seam so a future
    /// upstream confirmation can opt specific post-tool events into async
    /// without reshaping the writer.
    private static let asyncEvents: Set<String> = []

    public init() {}

    // MARK: - Generate Hook Configuration

    /// Build the Grok hooks document (`{ "hooks": { … } }`) for a session.
    /// Each event invokes `<crow> hook-event --session <UUID> --event <Name>`;
    /// the crow server resolves the session by UUID and dispatches through
    /// `GrokSignalSource`.
    static func generateDocument(sessionID: UUID, crowPath: String) -> [String: Any] {
        let sid = sessionID.uuidString
        var hooks: [String: Any] = [:]

        for event in allEvents {
            let command = "\(ShellLaunchArgs.shellQuote(crowPath)) hook-event --session \(sid) --event \(event)"
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            if asyncEvents.contains(event) {
                hookEntry["async"] = true
            }
            // Omit `matcher` to match all tools (Grok, like Claude, treats an
            // absent matcher as "match everything"; avoids an invalid regex).
            hooks[event] = [
                ["hooks": [hookEntry]] as [String: Any]
            ]
        }

        return ["hooks": hooks]
    }

    // MARK: - HookConfigWriter Conformance

    /// Write `<worktreePath>/.grok/hooks/crow.json` with the session UUID baked
    /// in. Idempotent — we own this single-purpose file and overwrite it
    /// wholesale, so there's nothing to merge. Called on every Grok launch.
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let hooksDir = Self.hooksDir(worktreePath)
        try FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)

        let filePath = (hooksDir as NSString).appendingPathComponent(Self.fileName)
        let document = Self.generateDocument(sessionID: sessionID, crowPath: crowPath)
        let data = try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: filePath))
        // `crow.json` embeds the absolute `crow` path and the session UUID and
        // lives inside the user's git worktree, where an agent's `git add -A`
        // (an unattended `.job` runs with `--always-approve`) could stage
        // it — and a committed hook pointing at a dead per-machine UUID breaks
        // every teammate who then opens the repo in Grok. A self-scoped
        // `.gitignore` (ignoring `crow.json` + itself, NOT `*.json`, so a user's
        // own hook files in this dir stay visible to git) keeps our generated file
        // out of the index. Inert to Grok, which merges only `*.json`. Same guard
        // OpenCode's per-worktree writer ships (#861 review r11).
        Self.writeGitignore(inDir: hooksDir)
    }

    /// Remove our `crow.json` from a worktree's `.grok/hooks/`, leaving any
    /// user-authored `*.json` hook files untouched. Best effort: prunes the
    /// `hooks`/`.grok` dirs when they're left empty (i.e. Crow created them), so
    /// tearing a session down leaves no trace — but never touches a file or
    /// directory that isn't ours.
    public func removeHookConfig(worktreePath: String) {
        let hooksDir = Self.hooksDir(worktreePath)
        let filePath = (hooksDir as NSString).appendingPathComponent(Self.fileName)
        try? FileManager.default.removeItem(atPath: filePath)
        // Drop our `.gitignore` only when it still holds exactly our content — a
        // user may have replaced it with their own rules (same provenance
        // discipline as `writeGitignore`). Not early-returned on a missing
        // `crow.json`, so a user who deleted it by hand isn't left with an
        // orphaned self-ignoring `.gitignore` (mirrors OpenCode).
        let gitignorePath = (hooksDir as NSString).appendingPathComponent(".gitignore")
        if (try? String(contentsOfFile: gitignorePath, encoding: .utf8)) == Self.gitignoreBody {
            try? FileManager.default.removeItem(atPath: gitignorePath)
        }
        Self.removeIfEmpty(hooksDir)
        Self.removeIfEmpty((worktreePath as NSString).appendingPathComponent(".grok"))
    }

    /// The exact body Crow writes to `.grok/hooks/.gitignore`. Single source of
    /// truth so `writeGitignore` and `removeHookConfig` agree on what "ours"
    /// means. Ignores our `crow.json` and the `.gitignore` itself — deliberately
    /// NOT `*.json`, so a user's own `.grok/hooks/*.json` files stay tracked.
    static let gitignoreBody = """
    # Crow-generated — safe to delete.
    \(fileName)
    .gitignore
    """

    /// Write a self-scoped `.gitignore` into `dir` so an agent's `git add -A`
    /// never stages our generated `crow.json`. `.grok/hooks/` is the *user's*
    /// directory (their own hook files can live here), so this never clobbers a
    /// pre-existing `.gitignore` — it writes only into an empty slot or over our
    /// own previous body. Idempotent; best effort.
    private static func writeGitignore(inDir dir: String) {
        let path = (dir as NSString).appendingPathComponent(".gitignore")
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           existing != gitignoreBody {
            // A `.gitignore` we didn't write (user's own rules) — leave it.
            return
        }
        try? gitignoreBody.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    // MARK: - Paths

    static let fileName = "crow.json"

    /// `<worktree>/.grok/hooks` — the directory Grok discovers project hook
    /// files (`*.json`) under.
    private static func hooksDir(_ worktree: String) -> String {
        let grokDir = (worktree as NSString).appendingPathComponent(".grok")
        return (grokDir as NSString).appendingPathComponent("hooks")
    }

    private static func removeIfEmpty(_ dir: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir), contents.isEmpty else { return }
        try? fm.removeItem(atPath: dir)
    }
}
