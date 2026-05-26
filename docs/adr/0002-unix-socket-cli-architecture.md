# 0002 — Unix-socket CLI ↔ app architecture

- **Status:** Accepted
- **Date:** 2026-05-25
- **Deciders:** Crow maintainers

## Context

The Manager session (and any external shell) needs to drive Crow programmatically — create sessions, attach worktrees, send keystrokes to a terminal, change session status. The constraints:

- The app already holds the canonical state (sessions, terminals, worktrees, links). Spawning a second process to mutate that state would mean either duplicating the state or building a much more invasive sync layer.
- We do not want to expose Crow to the network. Even a localhost HTTP listener can be picked up by other processes on the machine, browser fetches, or accidental tunneling.
- Calls need request/response semantics and typed payloads — a one-shot fire-and-forget queue isn't enough.
- The CLI is invoked from many places (Manager Claude Code, shell scripts, hooks, `crow-workspace/setup.sh`); per-call cost matters.

## Decision

The `crow` CLI is a **thin client that speaks newline-delimited JSON-RPC 2.0 over a Unix domain socket** at `~/.local/share/crow/crow.sock` to the running Crow app. All state mutations are routed through `CommandRouter` and executed on the main actor.

The socket directory is `0700` and the socket file is `0600`, so only the local user can connect. Maximum message size is bounded (1 MB) to prevent runaway payloads.

## Consequences

**Easier:**

- Single source of truth for app state — the CLI cannot drift from what the app sees.
- No network exposure. Unix-socket file permissions are sufficient access control on a single-user dev machine.
- Concurrent CLI calls are safe by construction: each connection is dispatched to GCD's global concurrent queue, and all state mutations land on the main actor via `await MainActor.run { ... }`. This is documented in `CLAUDE.md` under "Concurrency Safety."
- Typed RPC. The CLI and app share the request/response types, so adding a command is a single Swift-level change.

**Harder / accepted:**

- The app must be running for the CLI to work. This is intentional — the CLI is a remote control, not a stand-alone tool — but it means scripts must check for the app or be tolerant of a missing socket.
- Cross-machine use (e.g. SSH-ing in to drive Crow) needs SSH socket forwarding rather than a network port; we consider this a feature, not a limitation.

## Alternatives considered

- **AppleScript / OSAScript bridge.** Rejected — slower per call, weakly typed, and harder to drive from non-Apple tooling.
- **Localhost HTTP listener.** Rejected — port allocation, accidental exposure to other processes, and TLS isn't appropriate for a single-user dev tool.
- **File-based command queue / drop-box.** Rejected — no native request/response, hard to make atomic, and would still need a polling loop on the app side.

## References

- Code:
  - `Packages/CrowIPC/Sources/CrowIPC/SocketServer.swift`
  - `Packages/CrowIPC/Sources/CrowIPC/` (CommandRouter and request/response types)
  - `Sources/CrowCLI/main.swift`
- Reference: [`CLAUDE.md`](../../CLAUDE.md) — "Concurrency Safety" and "crow CLI Reference" sections
