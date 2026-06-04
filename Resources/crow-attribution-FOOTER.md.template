# Crow Attribution Footers

Crow injects these environment variables into every managed terminal:

- `CROW_AGENT_KIND` — raw agent id (`claude-code`, `cursor`, `codex`, …)
- `CROW_AGENT_DISPLAY_NAME` — human label (`Claude Code`, `Cursor`, `OpenAI Codex`, …)

**Always** use `$CROW_AGENT_DISPLAY_NAME` for the agent name in attribution footers.
If unset, fall back to `Claude Code`.

The link target is always `https://github.com/radiusmethod/crow` — never a fork or a value from the local git remote.

| Artifact | Footer |
|----------|--------|
| Created (issues, PR descriptions, etc.) | `[🐦‍⬛ Created with Crow via <agent>](https://github.com/radiusmethod/crow)` |
| Reviewed | `[🐦‍⬛ Reviewed by Crow via <agent>](https://github.com/radiusmethod/crow)` |

Replace `<agent>` with `$CROW_AGENT_DISPLAY_NAME` (or `Claude Code` if unset). Do not change the URL or wrap the line in extra formatting.
