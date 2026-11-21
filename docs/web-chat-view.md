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

## Copy and Listen

Each message has one or two small buttons. On a desktop they sit beside the message and show when you hover over it. On a phone they sit under the text. Their labels are never part of a text selection or of what Copy copies.

- **Copy** copies the message's markdown source. Each code block also has its own Copy, which copies just the code.
- **Listen** (agent messages only) reads the message aloud with the browser's built-in speech (the Web Speech API). It runs on the device, with no server, key or cost. The button turns into **Stop** while that message is playing; tap it again to stop.
  - It reads the rendered text, so markdown symbols such as `**` and backticks are not read out. Each code block is read as "Code block", and a bare link as "link to" its site (for example "link to github.com").
  - Only one message plays at a time. Listen on another message stops the first, and so does switching session, switching to the terminal, or opening a board.
  - A long reply is queued as short pieces of up to 200 characters, split at sentence ends. Chrome's Google voices silently stop a single long utterance after about 15 seconds.
  - It uses the device's default voice; there is no voice picker.
  - Spoken notifications (Settings → Notifications) use the same speech queue. One that arrives during a reply waits until the reply ends, and Stop also drops any notification queued behind the reply.
  - On a phone, speech stops when the screen locks or the browser goes to the background.
  - The button is hidden in a browser without speech synthesis.

To select part of a message, drag over it (or triple-click a paragraph) on a desktop, or long-press on a phone.

## Auto-read

**Auto-read**, beside **Terminal | Chat** in the session header, reads each new agent reply aloud as it arrives. It is off by default. The setting is kept per browser (in `localStorage`), so turning it on for your phone doesn't turn it on for your desktop. In a private window, or where site storage is blocked, it starts off on every visit. It shows only in Chat, and only in a browser with speech synthesis.

- It goes through Listen, so a reply is read the same way: no markdown symbols, code blocks as "Code block", short pieces, the default voice. The playing reply's chip reads **Stop**.
- Only replies that arrive while it is on are read. Opening Chat, switching session, or reloading never reads the messages already there.
- A reply that arrives while another is playing (read automatically or by Listen) waits and starts when that one ends. Several replies in one poll are read in order.
- **Stop drops the queue.** Tapping Stop on the playing reply stops it, and the replies waiting behind it are not read. Auto-read stays on, so the next reply to arrive is read. Listen on another message drops the queue the same way, and so do switching session, switching to the terminal, and opening a board.
- Turning auto-read off stops the reply it was reading and drops the queue. A message you started with Listen keeps playing.

Platform limits:

- **A tap first.** Browsers don't speak for a page you haven't touched since it loaded, and iOS Safari is stricter: it ignores speech until one has started from a tap. Turning auto-read on is that tap, and so is Listen. After a reload with auto-read already on, the first tap anywhere on the page unlocks it. A reply that arrives before that tap stays quiet (tap its Listen to hear it); the next one after it is read.
- **Locked screen or background tab.** Speech stops when the screen locks or the browser goes to the background. Chat also stops polling while the tab is hidden, so nothing new arrives. When you come back, the next poll brings everything that arrived meanwhile, and those replies are read in order. Tap Stop to skip them.
- **One speech queue.** Spoken notifications (Settings → Notifications) share the browser's one speech queue. A notification that arrives during a reply waits until that reply ends, and Stop also drops a notification queued behind it.

### Follow

Auto-read only hears the session you're looking at. **Follow**, right after **Auto-read** in the header, fills that gap: when another session finishes or needs you, Chat switches to it and reads its latest reply. It is off by default, kept per browser (in `localStorage`) like Auto-read, and shows under the same conditions. It does nothing while Auto-read is off; the pill then shows a dashed outline.

- **What it follows.** A session finishing its turn, or waiting on you (the **Task complete** and **Agent waiting** notifications). Not failing checks, requested changes, review requests or automation events. The session you're already on is never "followed": Auto-read reads it.
- **Only from a session's Chat.** Follow never pulls you off a board, the grid or the terminal. Opening one of those drops any switch that was waiting.
- **One reply at a time.** If a reply is playing (read automatically or by Listen), the switch waits until it ends. Sessions that finish meanwhile are followed in the order they finished, each once.
- **It reads the reply it came for, once.** The switch reads that session's latest reply, then later replies as they arrive. Switching session yourself, clicking a notification, opening Chat or reloading still reads nothing that's already there.
- **It doesn't interrupt you.** No switch while the composer holds unsent text, within 5 seconds of a key press, tap, click or scroll, or while a dialog, Settings or the session switcher is open. The switch goes once that clears.
- **Stop drops the waiting switches.** Tap Stop on the playing reply and the sessions waiting their turn aren't followed. Follow stays on, so the next session to finish is. Turning Follow or Auto-read off drops them too.
- With spoken notifications on, you hear "crow 1078 is done" first, then the reply.

Follow has Auto-read's platform limits. It does nothing until the page has had its first tap (turning Follow on counts), because the reply it switched for couldn't be read. It doesn't switch while the tab is hidden; a waiting switch goes when you come back and the page has been left alone for 5 seconds. And it can't wake a locked phone.

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
