# Web Chat view

Every agent runs as a terminal app inside tmux. The web UI shows that terminal by default. **Chat** is a second view of the same session: the agent's own transcript, rendered as messages with native scrolling. It is built for phones, where a terminal is hard to scroll and type into.

It is **off by default**. Turn it on with `crow ui set --chat-view true` (or Settings → General → Chat view); `crow ui set --chat-view false` turns it off again. The change reaches open browsers within a couple of seconds, with no restart, and turning it off sends anyone in Chat back to the terminal.

Once it's on, switch with the **Terminal | Chat** toggle in the session header. Chat has its own address, `#/sessions/<id>/chat`, and the choice sticks across sessions in that browser.

## How it works

- **Reading.** `crowd` finds the session's transcript file (the same lookup `HarnessTranscriptLocator` uses for handoffs) and reduces it to a short list of events: user and assistant messages, tool calls with their results, turn ends, and notices. The browser polls `get-session-transcript` every 2 seconds with a byte cursor, so each poll returns only what is new. A large transcript opens at its last 2 MB.
- **Sending.** The composer sends through the same `send` RPC as `crow send`: the text is pasted into the agent's terminal as one bracketed paste, then Enter is pressed. A long multi-line message arrives whole, and the text is sent exactly as typed (`raw: true`, so a literal `\n` in pasted code is not turned into a newline). If the text can't be delivered, the composer keeps it and shows "Send failed". Whatever you type in Chat appears in the terminal too. On a desktop, switching sessions (or opening Chat) puts the caret in the composer so you can type at once; phones don't auto-focus, so the keyboard doesn't cover the conversation. ↑ in an empty composer recalls your earlier messages in that session (↓ steps forward); unsent text is kept per session, so switching sessions never carries a draft to another agent.
- **Rendering.** Messages are rendered as markdown with [markdown-it](https://github.com/markdown-it/markdown-it) 14.1.1 (vendored, loaded only when Chat opens). Raw HTML stays text. Links open in a new tab, and only `http(s)` and `mailto` links are allowed. Tool calls are collapsed to one line; tap to expand.
- **Terminal mode is unaffected.** Nothing in the Chat view runs, polls, or downloads until a session is switched to Chat.

| Harness | Chat view |
|---|---|
| Claude Code | Supported, with the `/` menu and context meter |
| Codex | Supported (messages and tools; context meter from the rollout) |
| Others | "Not supported yet"; use the terminal |

Transcripts never contain permission prompts. When the agent is waiting for approval, answer it in the terminal.

## Copy, Listen and Select

Each message has a few small buttons. On a desktop they sit beside the message and show when you hover over it. On a phone they sit under the text. Their labels are never part of a text selection or of what Copy copies.

- **Copy** copies the message's markdown source. Each code block also has its own Copy, which copies just the code.
- **Listen** (agent messages only) reads the message aloud with the browser's built-in speech (the Web Speech API). It runs on the device, with no server, key or cost. The button turns into **Stop** while that message is playing; tap it again to stop.
  - It reads the rendered text, so markdown symbols such as `**` and backticks are not read out. Each code block is read as "Code block", and a bare link as "link to" its site (for example "link to github.com").
  - Only one message plays at a time. Listen on another message stops the first, and so does switching session, switching to the terminal, or opening a board.
  - A long reply is queued as short pieces of up to 200 characters, split at sentence ends. Chrome's Google voices silently stop a single long utterance after about 15 seconds.
  - It uses the device's default voice; there is no voice picker.
  - Spoken notifications (Settings → Notifications) use the same speech queue. One that arrives during a reply waits until the reply ends, and Stop also drops any notification queued behind the reply.
  - On a phone, speech stops when the screen locks or the browser goes to the background.
  - The button is hidden in a browser without speech synthesis.
- **Select** (mouse or trackpad only) selects the message's text, ready for ⌘C or for macOS's Speak Selection shortcut (⌥Esc, once Spoken Content → Speak selection is on in System Settings → Accessibility). It is hidden on touch screens, because iOS often doesn't show its Copy / Speak menu for a selection made by a script. On a phone, use Listen, or long-press to select.

## `/` menu (Claude Code)

Type `/` at the start of the composer to pick a skill or command. Use ↑/↓ to move, Enter or Tab to pick, and Esc to close; on a phone, tap an entry. Picking inserts `/name ` and nothing else. Claude Code expands it when the message arrives in the terminal, exactly as if you had typed it there. Claude expands one skill per message.

`list-chat-commands` builds the list in `crowd` from:

- skills: `.claude/skills/<name>/SKILL.md` in the session's folder and each parent folder up to the git repository root, then `~/.claude/skills/` (`description` from the frontmatter; `user-invocable: false` hides a skill);
- commands: `.claude/commands/*.md` from the same folders, then `~/.claude/commands/`;
- skills of plugins enabled in `enabledPlugins`, as `<plugin>:<skill>`;
- the built-ins `/compact`, `/context`, and `/clear`.

This is the same walk Claude Code does, so the menu lists what will expand. Crow's bundled `/crow-*` skills live in `{devRoot}/.claude/`, so they appear in Manager sessions (which run at or under the dev root) but not in work sessions, whose git worktree stops the walk; Claude doesn't load them there either. When two entries share a name, the nearest project one is listed. Review sessions list only your own (user and plugin) entries and the built-ins, never the reviewed worktree's, because a review checkout's `.claude/` is the PR author's.

## Context meter

In Chat view, the session header's **Agent** row shows the model and how full its context window is. The ring turns red above 90%. Hover, or tap on a phone, for used / max tokens.

- **Used tokens** come from the latest main-conversation model call: `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
- **The window** comes from Codex's own `model_context_window`, or from a small model table (`ChatContextWindow`). Every current Claude 5.x model reports 1,000,000 (checked against Claude Code's own `result.modelUsage[*].contextWindow`); Claude 3 and 4 models default to 200,000.
- For a model the table doesn't know, the row shows "N tokens" with no percentage rather than guess.
