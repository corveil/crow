# Spike #947 — Per-session read-only viewer links

**Issue:** [#947](https://github.com/corveil/crow/issues/947) · **Date:** 2026-08-10 · **Author:** @dhilgaertner
**Status:** Feasibility read for discussion — **no decision taken, nothing implemented.**
**Recommends:** Hybrid **A + C** (not the ticket's A + B), and an **ADR before code** — see [§6](#6-this-needs-an-adr-0019).

Issue #947 proposes per-session read-only share links and sketches four options. Those options were written from the outside; this spike checks each against the daemon and quantifies what the code makes cheap and what it makes expensive. Per the ticket's own closing line it does **not** implement anything — the implementation ticket is drafted separately in [`947-implementation-ticket-draft.md`](./947-implementation-ticket-draft.md), ready to file but unfiled.

Three findings change the ticket's framing. They are the reason this is a document rather than a comment.

1. **`localOnlyDenial` is a denylist. A viewer needs the opposite polarity** — and `isWrite` is not the predicate. [§1.1](#11-the-rpc-gate)
2. **`tmux attach -r` does not scope anything.** It blocks keystrokes; it does not stop a viewer watching the Manager. [§1.3](#13-the-terminal-path)
3. **EventHub filtering is mostly unnecessary.** The `changed` frame carries no payload. [§1.2](#12-eventhub)

---

## 1. Feasibility read

### 1.1 The RPC gate

**What `localOnlyDenial` actually is.** One `static func` at `RPCWebSocketHandler.swift:312`, called from exactly one place — `RPCWebSocketHandler.swift:114` — with a single boolean of per-connection state, `localDirect`, captured at upgrade (`:58`). It is **default-allow**: a `switch` that names 8 methods unconditionally (`run-setup`, `hook-event`, `open-in-vscode`, `open-terminal`, `gateway-get`/`-set`, `web-password-get`/`-set`) plus 2 conditionally (`set-config`, `defaults-set`, both only when they touch `defaults.binaries`). Everything else falls through to `nil`.

Its 85-line doc comment (`:226-311`) is the closest thing Crow has to a written authorization policy, and it states the governing rule outright:

> gate a *read* only when it returns what stripping would have removed

**Does a `ConnectionRole.viewer` fit this pattern or fight it?** The *shape* fits almost perfectly. One call site, one captured per-connection value, `(request) -> String?`. A `role` enum captured beside `localDirect` at `:58` and threaded into the gate is a genuinely small change — the gate function is `static` and takes `(request, devRoot)` today, so it grows one parameter and one branch.

The *polarity* is inverted, and that is where this gets dangerous. `localOnlyDenial` is a denylist over 97 methods. A viewer needs an **allowlist**: default-deny, permit ~6. Writing the viewer rule as more `case` arms in the same switch would silently grant a viewer every method nobody remembered to name. The two rules must be separate functions with separate defaults, however similar they look.

**`isWrite` is not the viewer predicate.** `ParityLedger.rpcMethods` (`ParityLedger.swift:87`) already classifies all 97 methods, and it is compiler-gated against the live router by `RPCLedgerParityTests` — a tempting ready-made partition. It is the wrong one:

| | count | |
|---|---:|---|
| All RPC methods | 97 | daemon `makeCommandRouter` ∪ engine `makeEngineRouter` |
| `.read(…)` | 29 | |
| **Session-scoped reads** | **6** | `get-session`, `list-links`, `list-worktrees`, `list-terminals`, `list-artifacts`, `get-pr-status` |
| Reads that must still be **denied** | **23** | fleet-wide or config-wide |

All 23 denied reads, enumerated — an implementer building a default-deny gate needs the list, not a description of it:

`list-sessions` · `list-sessions-live` · `list-tickets` · `list-reviews` · `list-agents` · `list-allowlist` · `get-scorecard` · `get-state` · `get-config` · `defaults-get` · `agents-get` · `automation-get` · `workspace-list` · `workspace-get` · `telemetry-get` · `cleanup-get` · `ui-get` · `version-update-get` · `notifications-get` · `gateway-get` · `web-password-get` · `job-list` · `job-get`

The ones that matter most: `get-state` returns the entire `DaemonStateSnapshot` — every session, every worktree path, plus `AppConfig`; `list-sessions` / `list-sessions-live` are the whole sidebar the ticket explicitly wants hidden; `defaults-get` returns `defaults.binaries`, absolute local binary paths, deliberately un-stripped (`RPCWebSocketHandler.swift:275-283`). (`gateway-get` and `web-password-get` are already local-socket-only and unreachable by a remote viewer regardless — listed for completeness, since a default-deny gate should not depend on a second gate holding.)

A viewer gate built on `isWrite` would hand a share-link holder `get-state`. That is the single most consequential correction to the ticket's Option A.

**Allowlisting the method is not enough.** All six safe reads take `session_id` as a *parameter* and trust it — verified at `EngineRouter.swift:280` (`get-session`), `:695` (`list-worktrees`), `:854` (`list-terminals`), `:1079` (`list-links`), `:321` (`get-pr-status`), and `RPCHandlers.swift:617` (`list-artifacts`). None checks ownership, because until now every `/rpc` caller was the owner. So the gate must **pin the param to the grant**, not merely permit the method — six param checks, not six name checks.

**Cost, concretely.** Plumbing: `RPCWebSocketHandler.swift` (capture a role, one new branch), `WebAuth.swift` (`Decision` grows a role; a grant store), `ParityLedger.swift` (a third classification column so the allowlist is enumerated where the parity test can gate it). Three files, maybe 120 lines. The ticket calls Option A's downside "role plumbing end-to-end"; measured, the plumbing is the cheap part. **The audit is the work** — and `ParityLedger` has already done 80% of it by forcing every method to be enumerated in one reviewable place.

Extending that ledger with a `viewerReachable` column means a future method cannot silently *skip* classification: `RPCLedgerParityTests.ledgerMatchesRegisteredMethods` asserts name-set parity in both directions against the live router, so an unledgered method fails the build. Be precise about what that buys, though — the parity test checks **names only**. The existing `isWrite` classification is validated against the method *name* in `CrowCLITests/ParityGateTests.swift`, never against runtime behaviour, so a row can be classified *wrongly* and CI stays green. The column gates **enumeration, not correctness**. What closes that gap is the exhaustive per-method assertion in the implementation ticket's acceptance criteria, not the ledger itself.

### 1.2 EventHub

The ticket budgets for "EventHub subscriptions filtered to the shared session only." Most of that is not needed.

`EventHub` is 97 lines (`EventHub.swift`). `subscribe` takes a continuation and nothing else (`:25`); `broadcast` loops over every subscriber unconditionally (`:38-42`). So there is no filtering today — the ticket is right about that. But there are only two frame types, and they differ completely:

- **`changed`** (`:18`) is the literal string `{"jsonrpc":"2.0","method":"changed"}`. **Zero payload.** It means "re-fetch"; the client then pulls via RPC, where §1.1's gate already applies. It leaks nothing and needs no filtering.
- **`notify`** (`:66-96`) carries `{event, key, title, body}` — human-readable automation text (`checksFailing`, `autoRebaseConflicts`, …) keyed by session UUID. This *does* leak: a subscribed viewer would receive automation notifications for every session in the fleet.

So the work is: scope `notify`, leave `changed` alone. One optional session parameter on `subscribe`, one predicate in `broadcast`. ~15 lines. This is the cheapest item in the whole feature and the ticket over-budgets it.

One caveat worth stating: the pull-not-push design means viewer scoping lives entirely in the RPC gate. That is a good property — one boundary, not two — but it also means a gap in §1.1 is not backstopped anywhere.

### 1.3 The terminal path

**The reassuring half.** Crow does *not* hold one shared attach that a second client would fight over. Every `/terminal` connection opens its own ephemeral **grouped** tmux session — `TerminalCockpit.openViewSession()` (`:86-90`) runs `tmux new-session -d -s crowd-web-<8hex> -t crow-cockpit` — which shares the cockpit's window *list* but keeps an independent current-window pointer. Adding `-r` to `attachCommand` (`:98-101`) would therefore make **that one viewer** read-only and touch nothing else. The desktop app and every other browser are separate tmux clients on separate session names. Leaked groups are already reaped at startup, gated on `session_attached == 0` (`:71-82`).

So the ticket's implied worry — what happens to the owner's own attachment — is a non-issue. Good.

**The disqualifying half.** `-r` makes a tmux *client* ignore input. `select-window` is not client input. `TerminalWebSocket.swift:93-97` decodes a JSON control frame and calls `cockpit.selectWindow(group:index:)`, which shells out to `tmux select-window -t "<group>:<index>"` as a **separate process** — server-side, entirely outside the read-only client's input path.

And the window index space is global. The cockpit holds one tmux window per `SessionTerminal` across *every* session; `list-terminals` hands the client the raw index (`EngineRouter.swift:888-892`, `"window": t.tmuxBinding.map { .int($0.windowIndex) }`). Nothing validates `control.window` — it goes straight through.

> A viewer on a read-only attach can send `{"type":"select-window","window":N}` for `N = 0…`, walk the whole cockpit, and watch the Manager, every other session, and every global terminal.

That is precisely the ticket's **"Never shareable"** list, violated by the option the ticket recommends.

**And `select-window` does not merely switch the view — it replays history.** `TerminalWebSocket.swift:98-106` follows every successful selection with `cockpit.replayData(group:index:)` and yields the result. So the escape above is not only "watch the Manager live": walking `N = 0…` hands the viewer up to 50 000 lines of replayed scrollback *per window*. §5.1 and §5.3 compose into something worse than either states alone, and it is the strongest single argument for never accepting a window selection from the client at all.

Fixing this means the daemon must derive, per frame, the window indices belonging to the granted session and reject the rest. Those indices are **mutable** — `new-terminal` allocates, `close-terminal` frees, `recreate-terminal` kills and rebuilds a window (`EngineRouter.swift:947-966`) — so the check must be live, not captured at connect. That is real, ongoing work the ticket does not account for.

Two more unguarded inputs on the same socket:

- **`resize`** (`TerminalWebSocket.swift:87-92`) is floored at 1×1 and otherwise trusted. See §5.2 — the blast radius is narrower than it first appears, but not zero.
- **`pty.write`** (`:81-82`) is the keystroke path `-r` does close. It is the *only* one of the three that `-r` closes.

**Net: Option B is cheap to make read-only and expensive to make per-session.** That inversion is the thing needed to choose between B and C.

### 1.4 Web password and cookie coexistence

`WebAuth.swift` is the whole auth model in 236 lines, and three properties matter here.

**Cookie collision.** The owner's cookie is `crow_session=…; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=<ttl>` (`:230-232`, `ttl` defaulting to 7 days from `SessionStore.init`, `:95`). A viewer cookie must not reuse that name — an owner who opens a link they minted, to check what the viewer sees, would overwrite their own session, and logging back in would revoke the viewer's. Use a distinct name *and* a distinct `Path` (e.g. `crow_view` at `Path=/view`), so the browser never attaches the viewer cookie to `/rpc` at all. Defence in depth for free: the viewer credential is not merely rejected at `/rpc`, it is not sent. And note `Max-Age` is a real field to decide rather than copy — a viewer cookie inheriting the owner's 7-day default would outlive a 24-hour grant, leaving the cookie valid and the grant dead.

**Grants need their own store.** `SessionStore` (`:90-123`) is `[String: Date]` — token to expiry, no metadata field of any kind. A grant needs a session ID, capabilities, and a revoked flag, so this is a new type rather than an extra key. It is also **in-memory and wiped on daemon restart** (`:88-89`). Reusing it means every `crowd` restart silently kills every share link — see [§5.4](#54-grants-and-daemon-restart--design-gap-not-a-vulnerability).

**The local-direct fast path is the sharp edge.** `authorize` returns `Decision(isAuthorized: true, reason: "local")` for a loopback peer with no `X-Forwarded-For` **before it ever loads config** (`:174-176`), and `RPCWebSocketHandler` skips `localOnlyDenial` entirely when `localDirect` is true (`:114`). A viewer role must therefore be evaluated *independently of and after* that fast path. If a viewer connection ever presents as local-direct — during local testing, or through the raw-TCP-forwarder case the file itself documents at `:18-20` ("a raw TCP forwarder that omits it would look local") — it is not a viewer, it is a full owner. `Decision` growing a role field, rather than callers making a second call, is what keeps that from being possible to forget.

### 1.5 Artifacts

Split verdict, and the split is instructive.

**The HTTP path is genuinely well built.** `GET /artifacts/:session/:file` has four independent guards: a UUID gate on the session segment (`Artifacts.swift:39-40`), a bare-filename gate rejecting `/` and `..` after the router percent-decodes (`:152-155`), symlink resolution with containment against the resolved root (`:169-180`), and `nosniff` (`:88`) plus `Content-Disposition: attachment` for anything not a known inline image type (`:94-96`, so a planted SVG cannot execute in the daemon origin). The containment check exists because of a real planted-symlink case — `shot.png` → `~/.claude/config.json` (`:71-74`).

**The RPC has no ownership check at all.** `list-artifacts` (`RPCHandlers.swift:616-619`) takes any `session_id` and returns `name`, `size`, `mtime`, `url`, and `path` — plus `dir`, an absolute filesystem path. Fine when every caller is the owner; not fine for a viewer. Pin the param (§1.1) and the surface is safe. Note the absolute paths are still a minor disclosure to a non-owner; dropping `path`/`dir` from a viewer's response costs nothing.

---

## 2. What the code makes cheap, and what it makes expensive

| Option | Verdict | Measured cost |
|---|---|---|
| **A** — viewer tokens + RPC allowlist | **Cheap, and the audit is half-done** | Plumbing ~3 files / ~120 lines. The real work is classifying 97 methods — and `ParityLedger` already enumerates them in one compiler-gated place, so a `viewerReachable` column makes the classification *permanent* rather than a point-in-time review. Highest value per line in the whole feature. |
| **B** — read-only tmux attach (`attach -r`) | **Cheap to start, expensive to finish** | `-r` is a one-line change to `attachCommand` and safely per-client (§1.3). But it closes one of three inbound paths. Scoping `select-window` needs live, per-frame session→window-index derivation against a mutable index space, forever. `resize` needs its own gate. This is the option that looks cheapest and is not. |
| **C** — dedicated one-way viewer stream | **Cheaper than the ticket claims** | The "duplicate streaming logic" is ~60 lines of PTY spawn + `AsyncStream` pump + limiter + teardown, most of it mechanical. In exchange, three gates are *deleted rather than written*: no `pty.write`, no `resize`, no `select-window` accepted from the client — the window is chosen server-side from the grant. A gate you never wrote cannot regress. |
| **D** — scoped login | **Dead, and the code says why** | `CommandRouter` (`CommandRouter.swift:13`) is a flat `[String: Handler]` **shared with the Unix-socket server**, and handlers receive params with no caller identity. Filtering `list-sessions` would mean per-handler awareness of a role that does not reach handlers — replicated 97 times instead of enforced once at the boundary. The ticket's own instinct here is right. |

**Recommendation: A + C.** Same skeleton as the ticket's hybrid, with the terminal half changed from a gated `attach -r` to a one-way route. The argument is not stylistic: every gate B must add, C does not need. Given the terminal is the surface where a mistake exposes the Manager, "no inbound path exists" is a materially stronger property than "inbound paths are checked."

---

## 3. Recommendations on the five open questions

These are the owner's calls. Each is a recommendation with its tradeoff, reasoned from the code rather than from taste.

### Q1 — Is live follow (Option B) required for v1, or is a scrollback snapshot enough?

**Recommend: snapshot only. Defer live follow.**

A snapshot is nearly free: `TerminalCockpit.replayData` (`:121-126`) already captures a pane and `replayFrame` (`:141-147`) already packages it as a self-contained xterm frame — pure, unit-tested, and prepending `ESC[H ESC[2J ESC[3J` so repeated loads rebuild rather than stack. A viewer route can call it and return bytes. No PTY, no grouped tmux session per viewer, no pressure on `TerminalConnectionLimiter`'s ceiling of 16 (`WebSocketOriginGuard.swift:119`).

Live follow drags in all of §1.3. **Tradeoff:** "watch me work" is the more compelling demo, and a snapshot needs a manual refresh. If live follow turns out to be the actual point of the feature, that is a legitimate reason to overrule this — but it should be a deliberate choice to buy §1.3's cost, not an assumption that `-r` covers it.

### Q2 — Should share links expire by default (e.g. 24 h)?

**Recommend: yes, 24 h — and make it the only option in v1.**

TTL enforcement is already free. `SessionStore` is a token→expiry map with `prune()` already firing on a 300-second timer (`CrowDaemon.swift:491`); a grant store with the same shape inherits that sweeper. A non-expiring grant is a different feature: it needs durable persistence *and* a revocation path *and* a UI to see what is outstanding, or the owner accumulates links they cannot enumerate. That is Phase 3 work.

**Tradeoff:** 24 h is wrong for the "PM checks in on this all week" case. `--expires 7d` is a one-line follow-up once revocation exists; shipping unbounded-by-default first is the ordering that cannot be undone.

### Q3 — Should viewers see artifacts/images for the session?

**Recommend: yes. It is the safest item on the list.**

Per §1.5 the HTTP path already has four independent guards, hardened against a real attack. The only change is pinning `:session` to the grant. Artifacts are also usually the thing a viewer actually wants — a screenshot of the change beats a terminal transcript for "look what this does."

**Tradeoff:** agents write artifacts unsupervised, so an agent that screenshots something sensitive puts it in the share. That is a smaller and more legible surface than 50 000 lines of scrollback (Q4), and it is the same trust the owner already extends by letting the agent write there.

### Q4 — Any concern with exposing terminal scrollback even read-only?

**Recommend: yes — this is the real risk in the feature, and the asymmetry is worth naming.**

Crow strips secrets carefully on the RPC surface: `SettingsSecrets.strippedForTransport` blanks the Jira token, the web-password hash and salt, and gateway header values before `get-state` or `get-config` reach any client (`RPCHandlers.swift:996-1002`, with a comment recording that `get-state` once shipped them raw). The terminal surface has no equivalent and cannot have one. Replay is `capture-pane -S -50000` (`TerminalCockpit.replayLines` = `TmuxBackend.scrollbackHistoryLimit` = 50 000, `TmuxBackend.swift:39`) — whatever the agent printed, verbatim.

So: Crow blanks gateway auth headers from `get-state`, and would ship those same headers verbatim if the owner ever ran `crow gateway get --reveal` in a shared pane. Also in scope: `cat` of `.claude/settings.local.json`, `env`, `gh auth token`, and any `--reveal`-style output, all of which are ordinary things to have run hours before deciding to share.

Three mitigations, in value order:

1. **Make `terminalScrollback` an opt-in capability on the grant, defaulting off.** The ticket's `capabilities` array already anticipates this; the recommendation is which way it defaults. A metadata-only share — status, PR state, artifacts — covers a large share of the use case at none of this risk.
2. **Bound viewer replay well below 50 000 lines** (~2 000). The owner's own scrollback stays untouched; a viewer sees recent context rather than the session's whole history.
3. **Pre-share confirmation that names the risk** rather than gesturing at it — "the viewer will see everything printed in this terminal, including any secrets."

**Tradeoff:** a 2 000-line cap will cut off a long agent run mid-context, and opt-in-off means the first share of every session takes an extra click.

### Q5 — CLI-only share creation for v1, or in-app button from day one?

**Recommend: CLI-first — and this one is not a preference.**

[ADR 0016](../adr/0016-cli-control-plane-parity.md) requires every user-mutable capability to have a CLI path, and it is mechanically enforced: `ParityLedger.rpcMethods` is asserted equal to the live router's `methodNames` by `RPCLedgerParityTests`, and `scripts/check-cli-parity.sh` re-asserts it for the Linux lane. A new `share-*` RPC **fails the build** until it has a ledger row and an `RPCLanePolicy.rules` entry. So `crow share create/list/revoke` is required infrastructure, not v1 scope-trimming.

The button is then a thin caller. **Tradeoff:** CLI-only v1 means the feature is invisible to anyone who lives in the browser — worth being explicit that Phase 1 ships a capability, not a discoverable feature.

---

## 4. Suggested phasing, revised

The ticket's three phases are close. Two changes, both following from §1.3 and §3:

| | Ticket | Revised | Why |
|---|---|---|---|
| **1** | Grants, `#/view/<token>`, metadata + scrollback snapshot, RPC allowlist | Same, **minus scrollback by default** — `terminalScrollback` opt-in, bounded (§3 Q4). Token redeemed at a real endpoint, not read from the fragment (§5.5). | Ships the boundary and the audit, which is the irreversible part |
| **2** | Read-only tmux attach + filtered EventHub | **One-way viewer stream** (Option C), with server-side window selection from the grant. EventHub: scope `notify` only. | §1.3 — `-r` does not scope; §1.2 — `changed` needs nothing |
| **3** | Share button, viewer count, revoke UI, pause on sensitive prompts | Unchanged, **plus durable grants** (§5.4) | Revocation UI and persistence are the same problem |

---

## 5. What the security checklist misses

The ticket invites this explicitly. Six items, roughly in severity order.

### 5.1 `select-window` escapes the shared session — *high*

Fully described in §1.3. A read-only tmux attach still lets a viewer enumerate every window in the cockpit, including the Manager — and each selection **also replays up to 50 000 lines of that window's scrollback** (`TerminalWebSocket.swift:98-106`), so this row composes with §5.3 rather than sitting beside it. This is the gap between what Option B appears to provide and what it provides. Mitigation: live per-frame session→window-index validation, or (better) never accept a window selection from the client at all — Option C.

### 5.2 `resize` can reshape the owner's pane — *medium, and already partly mitigated*

`TerminalWebSocket.swift:87-92` floors `rows`/`cols` at 1×1 and otherwise trusts them.

Correcting a plausible misreading first: **`window-size latest` is tmux's default, not something `crow-tmux.conf` sets.** The conf names it only to explain what it is working around (`crow-tmux.conf:196`), and it sets `aggressive-resize on` (`:206`, added for #667) precisely to narrow it — "Size each window from only the clients for which it is the CURRENT window."

So a mitigation already exists and deserves credit: a viewer parked on a **different** window does not drag the owner's geometry. The residual exposure is a viewer on the **same** window — which is reachable by composing §5.1, since `select-window` lets a viewer choose which window that is. Two further qualifications, both from the conf's own comment (`:202-204`):

- The narrowing is **partial under `latest`**: `aggressive-resize` is fully honored under `smallest`/`largest`, and under `latest` it "still narrows which clients a window tracks" rather than eliminating the interaction.
- The conf pairs it with "app.js's focus-gated resize (only the focused surface sends a resize frame)". **That half is client-side and therefore worth nothing against a viewer**, who controls their own client. Any argument that resize is handled must rest on `aggressive-resize` alone.

Still worth fixing: a read-only viewer that can perturb the owner's environment is not read-only. Mitigation: ignore `resize` frames from viewers entirely and pin their PTY to a fixed geometry — which, like §5.1, Option C gets by construction rather than by gate.

### 5.3 Scrollback replay versus the daemon's own stripping — *high*

Covered in §3 Q4. Restated here because it belongs in the checklist as its own row: **the RPC surface strips secrets and the terminal surface cannot.** The ticket's "pre-share warning" is the right instinct but understates the size of what is being warned about — 50 000 lines by default.

### 5.4 Grants and daemon restart — *design gap, not a vulnerability*

`SessionStore` is in-memory and cleared on restart (`WebAuth.swift:88-89`). Two ways to be wrong: reuse it, and every `crowd` restart silently kills live share links with no message to either party; persist it naively, and a revoked grant can come back from an older on-disk copy.

Recommendation: persist grants in `store.json` (daemon state) rather than `config.json` (user config), so they are not entangled with settings the user hand-edits. **Sharp edge:** per `CLAUDE.md`, `JSONStore` coalesces writes only *within a single instance* and every `mutate` rewrites the whole `StoreData` — a throwaway `JSONStore()` writer can clobber a record another writer just added (#728). Grants must go through the one injected instance owned by `SessionService`. Worth noting because a grant store is exactly the kind of small self-contained thing someone gives its own store.

Whether links *should* survive a restart is a genuine question. Surviving is friendlier; not surviving is a free global kill-switch (`crow restart-manager` semantics for shares). Recommend surviving, with `crow share revoke --all` as the explicit switch.

### 5.5 Rate-limiting a hash-fragment route is impossible — *invalidates a checklist row*

The checklist proposes "rate-limit `/view/*`". With `#/view/<token>` there is no `/view/*` request: the fragment never leaves the browser, and the server sees `GET /`. [ADR 0018](../adr/0018-web-client-hash-routing.md) makes hash routing the house pattern, and `login.html:54-61` already re-appends `location.hash` after login precisely so deep links survive. So the mitigation as written cannot function.

The fragment is nonetheless the *right* place for the token — it stays out of server logs, out of `Referer`, and out of proxy access logs, which is more than a path segment achieves. The fix is to keep the fragment and add a real redemption endpoint: `POST /view/redeem` with the token in the **body**, exchanged for the scoped cookie from §1.4, with the fragment stripped afterwards. That gives something to rate-limit and something to log.

Second-order, and worth knowing before copying the existing limiter: `LoginRateLimiter` is **global, not per-IP**, deliberately — behind a proxy every attempt shares the loopback peer (`WebAuth.swift:127-130`). A redemption limiter inherits that weakness, so it must be a *separate* instance; sharing one means guessing traffic against share links locks the owner out of their own `/login`. With a 256-bit token, guessing is not the threat anyway — the limiter exists for the audit trail, so keep it cheap and isolated.

### 5.6 Minor disclosures worth one line each — *low*

- `list-artifacts` returns `path` and `dir`, absolute filesystem paths (§1.5). Drop them for viewers.
- `get-session` returns `org_goal` (the session's KPI tag) and `ticket_url`. A share link scoped to one session still discloses an internal goal string. Probably fine; should be a decision rather than an accident.
- Session *names* are frequently ticket titles. Same category.

---

## 6. This needs an ADR (0019)

[ADR 0009](../adr/0009-crowd-sole-authority-clients-only.md) says, in the Decision:

> No client is privileged; the macOS app is just another window onto `crowd`, indistinguishable in authority from a browser tab.

A viewer role contradicts that sentence directly — it makes clients distinguishable in authority by construction. Contradicting an accepted ADR is normally itself an ADR, and **the next free number is 0019** (0001–0018 exist, none superseded).

Two honest qualifications, because the argument is weaker and more interesting than it first looks:

**0009 has already been amended once, in practice, without an ADR.** `localOnlyDenial` introduced a second authority tier — local-direct versus authenticated-remote — and its 85-line doc comment (`RPCWebSocketHandler.swift:226-311`) is doing the job an ADR would have done, complete with a stated governing rule and per-family justifications. So the precedent for tiering exists; the precedent for *recording* it is a doc comment.

**0009's load-bearing invariant survives intact.** That invariant is stated in Consequences:

> no UI writes `store.json` or spawns directly. All mutation flows through `crowd` RPCs; all state arrives via `crowd` reads + push.

A viewer still goes through `crowd` RPCs. It just gets fewer of them. Nothing about daemon-as-sole-authority changes.

So the accurate framing is not "this breaks 0009" but: **0009 asserted uniform client authority as a simplifying property, that property has already been quietly relaxed once, and a viewer role relaxes it in a qualitatively new way** — the first credential class that is *mintable, delegable, and held by a third party*. `localOnlyDenial` distinguishes clients by where they connect from, which the user cannot hand to anyone. A share token is a capability the owner creates and gives away. That is a different kind of thing and deserves the record.

Recommend ADR 0019 authored **after** the five questions are answered, since an ADR records a decision and there is not one yet. Skeleton, ready to fill:

```markdown
# 0019 — Client authority tiers: the viewer role

- **Status:** Proposed
- **Date:** <YYYY-MM-DD>
- **Deciders:** @dhilgaertner, …

## Context
ADR 0009 asserted that no client is privileged. That has held for authority over
*state* — crowd remains sole writer — but not for authorization: `localOnlyDenial`
(CROW-593/605/749/815) already tiers clients by connection origin. #947 asks for a
tier the owner can *mint and hand to someone else*, which is new in kind:
delegable, revocable, and held by a party who is not the owner.

## Decision
Crow recognizes exactly <N> connection roles: owner (…), and viewer (a per-session,
capability-scoped, expiring grant). Roles are enforced at the `/rpc` and terminal
boundaries, default-deny, and enumerated in `ParityLedger` so a new RPC cannot
become viewer-reachable without an explicit classification.

## Consequences
Easier: … · Harder: every new RPC now carries a classification obligation …
Amends 0009's "no client is privileged" — the sole-authority invariant is unchanged.

## Alternatives considered
Scoped login (D) — rejected: `CommandRouter` is shared with the Unix-socket server
and carries no caller identity, so filtering would live in 97 handlers, not one gate.
Read-only tmux attach (B) alone — rejected: `-r` blocks keystrokes but not
`select-window`, so it does not scope to a session (spike #947 §1.3).

## References
- Issue: https://github.com/corveil/crow/issues/947
- Spike: docs/spikes/947-readonly-viewer-links.md
- Related ADRs: 0009, 0016 (CLI parity), 0018 (hash routing)
- Code: RPCWebSocketHandler.swift, WebAuth.swift, TerminalWebSocket.swift, ParityLedger.swift
```

---

## 7. Open items for @dhilgaertner

Beyond the ticket's five:

1. **Should grants survive a `crowd` restart?** (§5.4) Recommend yes, with `crow share revoke --all` as the kill-switch. Not asked in #947 and it constrains where the store lives.
2. **Is a metadata-only share useful on its own?** If yes, Phase 1 is genuinely shippable without any terminal exposure and Q4 stops being urgent.
3. **Should viewers see `org_goal`?** (§5.6) A share link scoped to one session still discloses the KPI tag.
