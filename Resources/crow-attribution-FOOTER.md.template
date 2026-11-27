# Crow Attribution Footers

Get the footer line from Crow when you post, and copy it verbatim as the last line of
the body you pass to `gh`/`glab`:

```bash
crow attribution --kind review     # PR reviews
crow attribution --kind created    # issues, PR descriptions, other artifacts you wrote
```

It prints one line naming this session's harness and, when Crow knows it, the model
the session is running: `[🐦‍⬛ Reviewed by Crow via <agent> · <model>](https://github.com/corveil/crow)`.
The model is read when you run the command, because it can change mid-session. Like
every `crow` command, run it with `dangerouslyDisableSandbox: true`.

The model is left out, and the command still prints the footer and exits 0, when the
operator turned it off (`crow automation set --attribution-model false`, or Settings →
Automation), when you pass `--no-model`, when the session is unknown, when the harness
reports no model (only Claude Code and Codex do), or when the model id isn't plain
letters, digits, `.`, `_` and `-`. Don't add, edit or guess a model yourself.

If the command fails, use the static line from the table below. Your skill shows it
with the agent name already filled in: Crow substituted it when scaffolding.

Copy the line into the body as text, and pass the body by file (`--body-file`) where
the CLI allows it. **Do not** put `$(crow attribution …)`, `${CROW_AGENT_DISPLAY_NAME:-…}`
or any other shell expression in a footer or body. The shell silently fails to expand
it inside single-quoted heredocs and the literal text leaks into the artifact (#447).

The link target is always `https://github.com/corveil/crow` — never a fork or a value from the local git remote.

| Artifact | Footer (static fallback) |
|----------|--------|
| Created (issues, PR descriptions, etc.) | `[🐦‍⬛ Created with Crow via <agent>](https://github.com/corveil/crow)` |
| Reviewed | `[🐦‍⬛ Reviewed by Crow via <agent>](https://github.com/corveil/crow)` |
| Committed (hand-authored commit message) | Trailer block at the end of the message: `Crow-Session: <session-uuid>` and `Co-Authored-By: Claude <noreply@anthropic.com>` on their own lines, separated from the body by a blank line. `setup.sh` installs a `prepare-commit-msg` hook (CROW-518) that idempotently fills them in if missing, but include them explicitly when writing the message — the hook is the safety net. |

`<agent>` and `<model>` above are placeholders for *this document*. Do not change the
URL or wrap the line in extra formatting. The footer is informational: nothing gates
on it.
