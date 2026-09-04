# 0017 — No blocking I/O on the MainActor: logging goes through `CrowLog`

- **Status:** Accepted
- **Date:** 2026-07-27
- **Deciders:** @dustinhilgaertner

## Context

`crowd` is the sole authority ([0009](./0009-crowd-sole-authority-clients-only.md)), and
its RPC handlers mutate `@MainActor`-isolated state — roughly half of the 64 handlers
hop to the main actor to do it. That serialization is deliberate and
is what makes concurrent CLI use safe. It also means the main actor is a **shared,
single-threaded resource for every CLI and web client at once**: anything that blocks it
stalls the whole daemon, not one request.

`NSLog` blocks it. It funnels into CoreFoundation's `_logToStderr`, which calls
`writev(2)` on the controlling tty. A tty whose output queue is full and which nobody is
draining — Ctrl-S, a stopped terminal, an unread pane — blocks that `writev` in the
kernel with no timeout. A `sample` of a wedged daemon caught exactly this: one `NSLog`
inside `MainActor.run` holding the main actor while `crow reload-tmux-config` hung to the
CLI's 30 s read timeout and `open-terminal` timed out behind it (#874).

The reproducer was incidental. `reload-tmux-config` is not special — it just logs
unconditionally on its success path. There were **199 `NSLog` calls across 31 files**,
all of them in `crowd`'s dependency graph, and the heaviest users (`SessionService` 65,
`TmuxBackend` 21, `IssueTracker` 12) are `@MainActor` types. Three uncoordinated sinks had
grown up alongside each other — bare `NSLog`, `CrowDaemon.log`'s synchronous
`FileHandle.standardError.write`, and `CrowLog.automation` (which mirrored to `NSLog`, so
the durable-logging fix from CROW-782 was itself a wedge vector).

The same "blocking call on the main actor" shape appeared a second time in the same
issue, in `TmuxController.run`'s unbounded pipe drain. That is the same class of defect
arriving through a different door, which is what makes this a convention worth writing
down rather than two bug fixes.

## Decision

**`NSLog` is banned outside `CrowLog.swift`, enforced by `scripts/check-no-nslog.sh` in
CI. All logging goes through `CrowLog.info` / `.error` / `.automation`, which never block
the caller.**

`CrowLog` mirrors to `os_log` **on the calling thread** — a bounded `memcpy` into the
process's trace buffer, which cannot block — and then enqueues onto a bounded backlog
that a dedicated thread drains to stderr. When the sink is wedged, lines past the cap are
dropped and counted rather than queued, and the drain reports the gap when it resumes.

More generally: **a blocking syscall reached from the main actor must be bounded, moved
off the actor, or both.**

## Consequences

**Easier.** A stalled terminal can no longer take the daemon's RPC surface with it. The
unified log becomes a reliable second copy that survives a wedged stderr *and* `execv`,
so `log stream --predicate 'subsystem == "com.corveil.crowd"'` works during a hang — when
it is most wanted. One sink means one format and one place to change it.

**Also easier, unintentionally.** `NSLog` treats its first argument as a printf format
string, and 92 of the 199 sites passed interpolated, externally-influenced text (branch
names, PR titles, raw `gh` stderr, user paths) into that position, where a stray `%` reads
garbage varargs. `CrowLog.info(_ message: String)` makes that impossible by construction.
Two sites also passed a 64-bit `Int` to `%d`, which worked only by ABI accident.

**Harder / to live with.**

- **Delivery is asynchronous.** Anything that must be on disk before the process ends
  needs an explicit `CrowLog.flush(timeout:)` — `exit()` and `execv` paths do this, and
  tests that assert on file contents must too. `flush` is a barrier, not a guarantee: a
  wedged sink stays wedged and it returns `false`.
- **Logs can now have holes.** Bounded backpressure means dropping under sustained
  pressure. That is the deliberate trade: a gap plus a `dropped N line(s)` marker beats a
  hung daemon. The `os_log` copy is made before the drop, so nothing is lost outright.
- **The stderr line format changed.** `<ISO8601> processName[pid] <message>`, dropping
  `NSLog`'s thread id. This matches `crowd-automation.log`, so both sinks now sort and
  grep alike; `[crowd] …` lines gain a timestamp they never had.
- **`os_log` truncates around 1 KB.** Multi-line diagnostic bundles (e.g.
  `TmuxBackend.captureDiagnostics`) arrive whole on stderr but truncated in the unified
  log.
- **A dedicated thread, permanently.** It is parked on a condition variable when idle.
- **`crowd.log` rotation reopens launchd's capture fds.** launchd holds stdout/stderr
  open for the process lifetime, so a rename alone would leave writes on the old inode.
  The drain thread size-caps the file at 5 MB (one `…log.1` generation, 0o600) and
  `dup2`s a new open over fd 1/2 so later writes follow. A tty is left alone so
  `scripts/daemon-run.sh` still prints to the terminal. `crowd-automation.log` stays a
  decision log — general traffic is not mixed into it.

## Alternatives considered

- **`os_log` only, dropping stderr.** Loses the dev-mode inner loop: `scripts/daemon-run.sh`
  output is the terminal, and the `[CrowTelemetry …]` markers exist to be grepped there.
- **A bare serial `DispatchQueue`.** `DispatchQueue.async` already never blocks the
  caller, so it would fix the reported bug — but its queue is unbounded, so a wedged tty
  trades a hang for unbounded memory growth. Bounding it requires a structure in front,
  at which point the queue is only a thread-wakeup mechanism.
- **`O_NONBLOCK` on the daemon's stderr** (suggested on the issue). The flag lives on the
  *shared open file description*, so setting it on an inherited tty mutates the parent
  shell's stderr too, and every other process on that tty starts seeing `EAGAIN`.
- **A `CrowLog.info(_:_ args: CVarArg...)` overload**, which would have made all 199 sites
  a token swap. Rejected: it perpetuates printf in a Swift 6 codebase and preserves the
  format-string injection hole the single-`String` signature closes.
- **Retrofitting log levels across all 199 sites.** 199 judgment calls in one diff.
  `error(_:)` ships unused; reclassification is incremental.
- **Redirecting stderr to a file by default outside launchd.** Narrows the window but does
  not close it (a full disk or a stalled network mount still blocks), and it takes the
  daemon's output away from the terminal a developer is watching.
- **A `newsyslog.d` plist, or giving `CrowLog` its own `crowd.log` and dropping
  launchd `StandardOutPath`.** newsyslog still needs the process to reopen the fd (or
  SIGUSR1/HUP) and splits the 5 MB policy out of Crow. Dropping launchd capture would
  miss leftover `print()` and runtime writes; feeding that volume into
  `crowd-automation.log` would evict the auto-merge trail. Rotation next to
  `rotateIfNeeded` plus `dup2` keeps one policy and the existing capture.

## References

- Issue: [#874](https://github.com/corveil/crow/issues/874), [#1197](https://github.com/corveil/crow/issues/1197)
- Related ADRs: [0007](./0007-linux-ci-swift.md) (CrowCore builds on Linux, so `import os`
  is `#if canImport(Darwin)`-fenced), [0009](./0009-crowd-sole-authority-clients-only.md)
  (why the main actor is shared by every client), [0012](./0012-tests-never-touch-live-data.md)
  (the log directory resolves to a temp dir under a test runner)
- Code: `Packages/CrowCore/Sources/CrowCore/CrowLog.swift`,
  `Packages/CrowAutostart/Sources/CrowAutostart/LaunchdAutostart.swift`,
  `scripts/check-no-nslog.sh`,
  `Packages/CrowTerminal/Sources/CrowTerminal/TmuxController.swift` (the bounded-drain
  half of the same defect class),
  `Packages/CrowTerminal/Sources/CrowTerminal/PTYProcess.swift` (`CLOEXEC_DEFAULT`, its
  root cause)
