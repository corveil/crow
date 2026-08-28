/// Working-tree re-strip after a live review session checks out the PR head
/// (CROW-960).
///
/// Launch-path `prepareWorktreeForAgentLaunch` strips at process start. The
/// review skill then runs `gh pr checkout` (and a head-advancing re-review
/// runs the same), which restores attacker-controlled harness config into an
/// already-running session. This command is the mid-session close: one union
/// list so Cursor, Grok, Antigravity, Claude, Muse, and Codex all lose the
/// restored layer without a per-adapter change.
///
/// The `crow-review-pr` skill and `AutoRespondCoordinator.reReviewPrompt`
/// must emit this **exact** command. `ReviewCloneRestripTests` pins the skill
/// file to this string; do not reword one side without the other.
///
/// Working-tree only — never `git rm`. The git index entry survives, matching
/// `SessionService.strip*ConfigFromReviewClone`. Do not delete `.claude/`
/// wholesale: Crow's copied review skill lives under `.claude/skills/`.
public enum ReviewCloneRestrip {
    public static let workingTreeRmCommand =
        "rm -rf -- .cursor .grok .agents .gemini .muse .codex .mcp.json .claude/settings.json .claude/settings.local.json"
}
