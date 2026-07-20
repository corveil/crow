# 0009 — crowd is the sole authority; every UI is a pure client

- **Status:** Accepted
- **Date:** 2026-07-05
- **Deciders:** @danny, Claude

## Context

Crow began as a macOS app that *was* the product: the session engine, the
authoritative in-memory state, the `store.json` writer, the spawner of
workspaces (git worktree + tmux window + agent process), and a JSON-RPC socket
server all lived inside the AppKit app. The `crowd` daemon (CROW-581, M0–M1) was
added as a thin gateway that mostly **forwarded** actions to the app and
returned empty/errors when the app was down. Two in-memory copies of one
`store.json` were reconciled last-writer-wins.

That shape has three standing costs: every logic change forces a CrowApp
rebuild/relaunch; "app down" degrades most features; and the two-store
reconciliation is a persistent source of divergence. It also blocks the thing we
actually want — **more than one UI**. A browser tab, the macOS window, and any
future shell should all be equal windows onto the same running system, with no
single client holding privileged state.

The CROW-581 migration (Milestones A–E1, PR #594) has already moved the engine
into a host-agnostic `CrowEngine` package (no AppKit; host affordances behind a
`HostBridge` seam) and inverted the read/query/status layer into the daemon
(agents, boards, tickets/reviews/allowlist, session-status writes all answer
locally; clients get live WebSocket push). What remains is the authority itself:
spawning, lifecycle, and store ownership.

## Decision

**`crowd` is the single source of truth. It is the only store writer, the only
spawner, and the owner of terminal + agent lifecycle. Every user interface —
web, macOS, and any number of them at once — is a pure client** that subscribes
to `crowd`'s state over the existing `/rpc` + `/terminal` + WebSocket-push
surface, sends RPCs, and renders. No client is privileged; the macOS app is just
another window onto `crowd`, indistinguishable in authority from a browser tab.

The macOS app keeps its **native shell** — it draws the real terminal, native
menus/windows/notifications, clipboard, and "open in editor" — because those are
host affordances, not state. That is exactly the `HostBridge` boundary: the app
owns its pixels and its host integrations; it owns **zero** engine, store,
spawner, or server. The web client is the same shape minus the native
affordances.

Concretely this retires `forwardToApp` and the two-store reconciliation, and it
means the app's `SessionService` / store / socket-server are removed rather than
duplicated.

## Consequences

**Easier:** one authority to reason about; N clients "for free" (the `EventHub`
already broadcasts to every `/rpc` subscriber, and tmux supports multiple
terminal attach); features work identically whether zero or five UIs are open;
no client-vs-client arbitration protocol to design, because there is only ever
one spawner; logic changes no longer require an app rebuild.

**Harder / must live with:** `crowd` must gain the capabilities the app has
today before the app can shed them — spawn orchestration
(`create-manager`/`work-on-issue`/`start-review`), agent-exit + readiness
monitoring, and sole-writer store ownership. The build order is therefore
**E2 (crowd gains spawn/lifecycle) → F (app becomes a client)**; you cannot
demote the app until `crowd` can do everything it does. During the transition
the app stays green and authoritative on its own machine until F flips it in one
coherent change (strangler-fig). `crowd` becomes a more privileged process (it
runs git and launches agents), so its network exposure stays loopback-only
unless explicitly hardened.

**Invariant other code now relies on:** no UI writes `store.json` or spawns
directly. All mutation flows through `crowd` RPCs; all state arrives via
`crowd` reads + push. New client features are RPC + render, never local engine.

## Alternatives considered

- **App-authoritative-when-present (hybrid):** daemon forwards to the app while
  it's running, acts locally only when it's down. Rejected — it preserves the
  privileged client and the two-store divergence, and needs an arbitration/
  handoff protocol precisely to paper over the split authority we're removing.
- **Keep the app as the engine, `crowd` as a permanent gateway:** rejected — it
  hard-blocks multiple concurrent UIs and keeps every change gated on an app
  rebuild.
- **Reimplement spawn logic separately in the daemon:** rejected in favor of
  hosting the same `CrowEngine.SessionService` the app uses, so spawn behavior
  has one implementation, not two that drift.

## References

- PR: https://github.com/corveil/crow/pull/594 (CROW-581, Milestones A–E1)
- Related ADRs: [0001](./0001-tmux-only-terminal-backend.md) (tmux as the sole
  terminal backend — the shared server is what lets many clients attach),
  [0002](./0002-unix-socket-cli-architecture.md) (the JSON-RPC surface clients
  speak), [0005](./0005-task-and-code-backend-protocols.md)
- Code: `Packages/CrowEngine/` (host-agnostic engine + `HostBridge`),
  `Packages/CrowDaemon/` (`crowd`), `Sources/Crow/App/` (the native client shell)
