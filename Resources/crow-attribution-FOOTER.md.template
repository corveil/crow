# Crow Attribution Footers

This file is what your skill sees on disk. The footer lines below already contain
the literal agent name for this session (`Claude Code`, `Cursor`, `OpenAI Codex`, …) —
Crow substituted it in when scaffolding. Copy each line verbatim into the body you
pass to `gh`/`glab` (or your commit). No shell parameter expansion is needed and the
line survives every quoting form (single-quoted heredocs, JSON files, Swift literals).

**Do not** reintroduce `${CROW_AGENT_DISPLAY_NAME:-…}` or any other shell
expression in attribution footers. The shell silently fails to expand it inside
single-quoted heredocs and the literal text leaks into the artifact (#447).

The link target is always `https://github.com/corveil/crow` — never a fork or a value from the local git remote.

| Artifact | Footer |
|----------|--------|
| Created (issues, PR descriptions, etc.) | `[🐦‍⬛ Created with Crow via <agent>](https://github.com/corveil/crow)` |
| Reviewed | `[🐦‍⬛ Reviewed by Crow via <agent>](https://github.com/corveil/crow)` |
| Committed (hand-authored commit message) | Trailer block at the end of the message: `Crow-Session: <session-uuid>` and `Co-Authored-By: Claude <noreply@anthropic.com>` on their own lines, separated from the body by a blank line. `setup.sh` installs a `prepare-commit-msg` hook (CROW-518) that idempotently fills them in if missing, but include them explicitly when writing the message — the hook is the safety net. |

`<agent>` above is just a placeholder for *this document* — in the real footer lines
your skill receives, the agent name is already filled in. Do not change the URL or
wrap the line in extra formatting.
