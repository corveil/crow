# Web Chat view

Every agent runs as a terminal app inside tmux. The web UI shows that terminal by default. **Chat** is a second view of the same session: the agent's own transcript, rendered as messages with native scrolling. It is built for phones, where a terminal is hard to scroll and type into.

Switch with the **Terminal | Chat** toggle in the session header. Chat has its own address, `#/sessions/<id>/chat`, and the choice sticks across sessions in that browser.

## How it works

- **Reading.** `crowd` finds the session's transcript file (the same lookup `HarnessTranscriptLocator` uses for handoffs) and reduces it to a short list of events: user and assistant messages, tool calls with their results, turn ends, and notices. The browser polls `get-session-transcript` every 2 seconds with a byte cursor, so each poll returns only what is new. A large transcript opens at its last 2 MB.
- **Sending.** The composer sends through the same `send` RPC as `crow send`: the text is pasted into the agent's terminal and Enter is pressed. Whatever you type in Chat appears in the terminal too. On a desktop, switching sessions (or opening Chat) puts the caret in the composer so you can type at once; phones don't auto-focus, so the keyboard doesn't cover the conversation. ↑ in an empty composer recalls your earlier messages in that session (↓ steps forward); unsent text is kept per session, so switching sessions never carries a draft to another agent.
- **Rendering.** Messages are rendered as markdown with [markdown-it](https://github.com/markdown-it/markdown-it) 14.1.1 (vendored, loaded only when Chat opens). Raw HTML stays text. Links open in a new tab, and only `http(s)` and `mailto` links are allowed. Tool calls are collapsed to one line; tap to expand.
- **Terminal mode is unaffected.** Nothing in the Chat view runs, polls, or downloads until a session is switched to Chat.

| Harness | Chat view |
|---|---|
| Claude Code | Supported, with the `/` menu and context meter |
| Codex | Supported (messages and tools; context meter from the rollout) |
| Others | "Not supported yet"; use the terminal |

Transcripts never contain permission prompts. When the agent is waiting for approval, answer it in the terminal.

## `/` menu (Claude Code)

Type `/` at the start of the composer to pick a skill or command. Use ↑/↓ to move, Enter or Tab to pick, and Esc to close; on a phone, tap an entry. Picking inserts `/name ` and nothing else. Claude Code expands it when the message arrives, so the menu works the same whether the session runs in the terminal or the experimental headless driver. Claude expands one skill per message.

`list-chat-commands` builds the list in `crowd` from:

- skills: `.claude/skills/<name>/SKILL.md` in the session's folder and each parent folder up to the git repository root, then `~/.claude/skills/` (`description` from the frontmatter; `user-invocable: false` hides a skill);
- commands: `.claude/commands/*.md` from the same folders, then `~/.claude/commands/`;
- skills of plugins enabled in `enabledPlugins`, as `<plugin>:<skill>`;
- the built-ins `/compact`, `/context`, and `/clear`.

This is the same walk Claude Code does, so the menu lists what will expand. Crow's bundled `/crow-*` skills live in `{devRoot}/.claude/`, so they appear in Manager sessions (which run at or under the dev root) but not in work sessions, whose git worktree stops the walk; Claude doesn't load them there either. When two entries share a name, the nearest project one is listed. Review sessions list only your own (user and plugin) entries and the built-ins, never the reviewed worktree's, because a review checkout's `.claude/` is the PR author's.

## Context meter

In Chat view, the session header's **Agent** row shows the model and how full its context window is. The ring turns red above 90%. Hover, or tap on a phone, for used / max tokens.

- **Used tokens** come from the latest main-conversation model call: `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
- **The window** comes from the headless driver's `result.modelUsage[*].contextWindow` when the driver runs, from Codex's own `model_context_window`, or from a small model table (`ChatContextWindow`). Every current Claude 5.x model reports 1,000,000; Claude 3 and 4 models default to 200,000.
- For a model the table doesn't know, the row shows "N tokens" with no percentage rather than guess.

## Experimental: headless driver

Enabled with `CROW_CHAT_DRIVER=1` in `crowd`'s environment, and started through the `chat-driver-start` RPC; there is no button for it in the UI for now. It works on Claude Code work sessions and runs `claude -p` in stream-json mode as a child of `crowd`, in a **new** conversation (not the terminal's). It answers permission prompts with Allow/Deny cards in Chat, and shows cost in the context meter. It is off by default and refused for review sessions, because `claude -p` skips the workspace-trust check and a review checkout is the PR author's code.

Because the process is a child of `crowd`, restarting `crowd` stops it, unlike tmux-hosted agents. Deleting the session stops it too, before the worktree is removed. The conversation survives on disk. The driver will be superseded by an out-of-process agent host.
