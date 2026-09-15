# 0027 — TUI form-factor recording

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** @dgershman, @dhilgaertner

## Context

The same Crow web UI is the TUI on desktop (Tauri), browser, iPad, and phone, but those surfaces disagree about cursor position, grid size, and whether the software keyboard occludes the prompt. Evidence for a fix has been a screenshot plus a guess about which of three coordinate systems drifted — tmux pane geometry, PTY `TIOCSWINSZ`, and xterm.js CSS/`visualViewport`. Attaching a second browser tab is not a diagnostic: each `/terminal` connection is a private grouped tmux view, `window-size latest` lets a "watch" tab steal size, and the phone's inset/DPR/helper-textarea CSS never appear on the PTY.

v1 needs capture + local playback + structured observations. Automatic "fix the TUI" is out of scope. Crowd remains the sole authority ([ADR 0009](./0009-crowd-sole-authority-clients-only.md)); tmux remains the only terminal backend ([ADR 0001](./0001-tmux-only-terminal-backend.md)); `/terminal` server→client stays binary ([ADR 0013](./0013-terminal-scroll-model.md)).

## Decision

Crow records a TUI **on the bound surface**. `crowd` owns the recording; clients only sample themselves.

1. **Bind protocol.** `/rpc tui-record-start` returns `recording_id`. The **same** client sends `/terminal` `{type:"tui-bind", recording_id}`. Start is idempotent for an in-flight `(session_id, terminal_id)`. Web start without a bind in 20 s is `abandoned`. iOS disconnect is a 20 s grace plus `sessionStorage` re-bind. CLI-without-client is `pty_source: "none"` until a surface binds.
2. **Tee at `outputTask` dequeue** so CROW-606 `select-window` replay is captured, not only `pty.onOutput`. Connection-local `if let tee { tee.yield }` — no process-wide map on the PTY hot path. In-memory tee: 8 MiB or 2 s, then seal `tee_backpressure`. Two `DispatchQueue`s (ingest vs sampler); a blocked `capturePane` must not occupy the cooperative pool ([ADR 0017](./0017-non-blocking-logging.md)).
3. **Watch ≠ second attach.** Playback is `#/tui-recordings/:id` over a streamed HTTP GET. Live watch is EventHub metadata (client-filtered) or CLI `tui-record-log --since`. HUD is `position:absolute; pointer-events:none` over `#terminal-wrap` so toggling it cannot SIGWINCH.
4. **Storage.** `AppSupportDirectory.url/tui-recordings/` (0700/0600). Cap-and-seal at 10 min or 64 MiB (not a ring). Retention 7 days (`0` = never). Session cleanup does not touch the dir. Opt-in, local-first, never uploaded. `export` is CLI-only local copy — no RPC, no ledger row (1 MB Unix-socket cap). `export --fixture` is geometry + detector inputs only.
5. **Observations.** Detectors fire only on facts the capture stores. Swift `TuiObservationTests` are the source of truth; jsdom locks sampler fields and the CROW-1045 classifier (Tauri is desktop even though `visualViewport` exists; phone/tablet is touch/coarse). Form factor comes from client signals, not "which binary."

## Consequences

A later fix can paste `report.json` `first_red` onto a GitHub issue and compile a fixture. Phone Start after CLI start binds the same id. Unrelated tabs ignore EventHub `tui-record-event`. The idle `/terminal` hot path is a nil-check.

What we live with: recordings contain keystrokes (no redaction); any web-auth peer can download any recording for `retentionDays` (explicit ACL, broader than live `/terminal`); there is no Unix-socket EventHub stream (`SocketClient.send` is one-shot, 1 MB).

## Alternatives considered

- **Second tmux attach / grouped "watch" tab.** Steals `window-size latest` and cannot see client CSS. Rejected.
- **Widen `/terminal` server→client with sample frames.** Violates ADR 0013's single-writer binary stream. Samples are inbound; lifecycle is `/rpc`.
- **Always-on RAM flight recorder / CrowTelemetry piggy-back.** Privacy and idle-cost; v1 is opt-in.
- **JS detector twins.** Would drift from Swift; jsdom only locks the sampler.
- **`$TMPDIR/artifacts` or `store.json`.** Recordings are multi-megabyte ndjson and must outlive session cleanup.

## References

- Ticket: https://github.com/corveil/crow/issues/1255
- Design: https://gist.github.com/dgershman/7fc6436e72b35b2b40fa886038810c5b
- Related ADRs: [0001](./0001-tmux-only-terminal-backend.md), [0009](./0009-crowd-sole-authority-clients-only.md), [0012](./0012-tests-never-touch-live-data.md), [0013](./0013-terminal-scroll-model.md), [0016](./0016-cli-control-plane-parity.md), [0017](./0017-non-blocking-logging.md)
- Code: `Packages/CrowDaemon/Sources/CrowDaemon/TuiRecorder.swift`, `TuiDetectors.swift`, `TerminalWebSocket.swift`, `Packages/CrowCLI/Sources/CrowCLILib/Commands/TuiCommands.swift`, `Packages/CrowTerminal/Sources/CrowTerminal/Resources/xterm/xterm-addon-crow-tui-trace.js`, `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/tui-record.js`
