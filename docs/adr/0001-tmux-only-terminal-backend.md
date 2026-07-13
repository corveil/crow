# 0001 — tmux as the sole terminal backend

- **Status:** Accepted
- **Date:** 2026-05-25
- **Deciders:** Crow maintainers

## Context

Crow originally embedded one libghostty surface per terminal pane. As we built out the Manager pattern and parallel sessions, three problems became load-bearing rather than incidental:

1. **Shell-readiness was guesswork.** We used a 5-second sleep before sending the first command into a new terminal, because there was no signal that the shell had drained its rc files and was ready for input. Anything that took longer than 5 s dropped its first input on the floor; anything faster wasted seconds per session.
2. **Input was bounded by libghostty's write path.** Large prompt bodies (especially the pre-fetched ticket text in initial prompts) could outrun the surface's input buffer, producing dropped characters and reordered keystrokes.
3. **Survival across app restarts was effectively impossible.** Each terminal was tied to a per-process libghostty surface; relaunching Crow meant rebuilding every session from scratch.

`docs/terminal-runtime-research.md` documents the underlying analysis and the libghostty bottleneck in detail.

## Decision

Crow uses **tmux as its sole terminal backend.** A single libghostty surface attaches to a persistent tmux server at a stable socket (`$TMPDIR/crow-tmux.sock`); per-session state is the tmux binding (window/pane) stored on `SessionTerminal.tmuxBinding`.

A single-instance lock at `$TMPDIR/crow-instance.lock` prevents two Crow processes from racing the same tmux server. The "Restart tmux Server" menu item rebuilds the cockpit on demand without a full app relaunch.

## Consequences

**Easier:**

- Reliable shell-readiness via `SentinelWaiter` (we emit a sentinel from the shell rc and watch for it on the pipe). The 5 s sleep is gone.
- Bounded, ordered input via `tmux load-buffer` + `paste-buffer` — large prompts paste atomically.
- Sessions survive app restarts. On launch, Crow re-attaches to the existing tmux server and adopts pre-existing windows via `adoptTerminal`.
- One libghostty surface to maintain rather than N per-terminal surfaces.

**Harder / accepted:**

- Hard runtime dependency on `tmux` being installed. `TmuxDiscovery` resolves the binary at startup; absence is a hard error.
- Multi-backend flexibility is gone. Adding another backend (Kitty, iTerm controller mode, etc.) means re-introducing the abstraction we just deleted.
- Orphan tmux sockets from older Crow versions need explicit reaping (`TmuxOrphanReaper`).

## Alternatives considered

- **Keep per-terminal libghostty surfaces.** Rejected — this was the root cause of the three problems above; no path forward without addressing the surface-per-terminal model itself.
- **Kitty / iTerm controller-mode backends.** Rejected — would require maintaining a second backend abstraction for marginal gain; tmux is already a hard dependency on most dev machines.
- **Custom PTY multiplexer in-process.** Rejected — re-implements what tmux already does well, and loses the "tmux session survives Crow crashes" property.

## References

- PRs: [#229](https://github.com/corveil/crow/pull/229) (feature flag), [#302](https://github.com/corveil/crow/pull/302) (default backend), [#334](https://github.com/corveil/crow/pull/334) (remove legacy Ghostty path), [#324](https://github.com/corveil/crow/pull/324) (Manager on tmux), [#353](https://github.com/corveil/crow/pull/353) (persist across restarts), [#377](https://github.com/corveil/crow/pull/377) (restart-server menu)
- Research: [`docs/terminal-runtime-research.md`](../terminal-runtime-research.md)
- Code:
  - `Packages/CrowTerminal/Sources/CrowTerminal/TmuxBackend.swift`
  - `Packages/CrowTerminal/Sources/CrowTerminal/TmuxController.swift`
  - `Packages/CrowTerminal/Sources/CrowTerminal/SentinelWaiter.swift`
  - `Packages/CrowTerminal/Sources/CrowTerminal/TmuxOrphanReaper.swift`
  - `Sources/Crow/App/TmuxDiscovery.swift`
