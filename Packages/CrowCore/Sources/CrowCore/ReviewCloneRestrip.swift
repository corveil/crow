/// Working-tree re-strip after a live review session checks out the PR head
/// (CROW-960, CROW-1492).
///
/// Launch-path `prepareWorktreeForAgentLaunch` strips at process start. The
/// review skill then runs `gh pr checkout` (and a head-advancing re-review
/// runs the same), which restores attacker-controlled harness config into an
/// already-running session. The re-strip is the mid-session close: one union
/// list so Cursor, Grok, Antigravity, Claude, Muse, and Codex all lose the
/// restored layer without a per-adapter change.
///
/// CROW-960 had the agent run `rm` itself. Under Claude Code's sandbox that
/// `rm` could never remove `.claude/settings.json` or
/// `.claude/settings.local.json` (the sandbox denies writes to both), so the
/// strip failed on every Claude review while `gh pr checkout`, which runs
/// unsandboxed, kept restoring them. CROW-1492 moves the removal into the
/// daemon: the agent calls ``cliCommand`` and `crowd` removes ``paths`` from
/// the session's review clone, outside any agent sandbox, then checks that
/// none of them is left.
///
/// The `crow-review-pr` skill and `AutoRespondCoordinator.reReviewPrompt`
/// must emit ``cliCommand`` **exactly**. `ReviewCloneRestripTests` pins the
/// skill file to this string; do not reword one side without the other.
///
/// Working-tree only, never `git rm`. The git index entry survives, matching
/// `SessionService.strip*ConfigFromReviewClone`. Never delete `.claude/`
/// wholesale: Crow's copied review skill lives under `.claude/skills/`.
public enum ReviewCloneRestrip {
    /// Every harness-config path a review clone loses after checkout, relative
    /// to the clone root. This is the union of the per-agent
    /// `strip*ConfigFromReviewClone` helpers (CrowEngine), and
    /// `ReviewRestripRPCSupportTests` fails if the two drift apart.
    public static let paths: [String] = [
        ".cursor",
        ".grok",
        ".agents",
        ".gemini",
        ".muse",
        ".codex",
        ".mcp.json",
        ".claude/settings.json",
        ".claude/settings.local.json",
    ]

    /// The `crow` verb the review skill and the re-review prompt run right
    /// after checkout, as its own Bash call with the sandbox disabled. The
    /// daemon resolves the clone from the session, so the agent passes no path.
    public static let cliCommand = #"crow review restrip --session "$CROW_SESSION_ID""#
}
