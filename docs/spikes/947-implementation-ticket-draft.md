# DRAFT — implementation ticket for CROW-947 (Phase 1)

> **This file is a draft. It has not been filed.**
> File with `gh issue create --title "…" --body-file docs/spikes/947-implementation-ticket-draft.md`
> after the open questions on [#947](https://github.com/corveil/crow/issues/947) are answered.
>
> #947 asks for `crow:auto` on the implementation ticket. **Labelling is left to the owner** —
> this draft deliberately applies none, since `crow:auto` would dispatch an agent at a
> scope the owner has not yet signed off.
>
> **Suggested title:** `Per-session read-only viewer links, Phase 1: grants + scoped RPC gate (CROW-947)`
>
> Everything below the rule is the proposed issue body.

---

Implements Phase 1 of the design agreed in [#947](https://github.com/corveil/crow/issues/947). Feasibility analysis, cost breakdown, and the reasoning behind each choice below: `docs/spikes/947-readonly-viewer-links.md`.

The owner mints a per-session, expiring, revocable grant. A holder of the link sees that session's metadata, PR status, and artifacts — and nothing else, enforced at the daemon rather than hidden in the UI.

## Scope

**In:**

1. `ShareGrant` model + store — `{token, sessionID, createdAt, expiresAt, revoked, capabilities}`, persisted in `store.json`.
2. Token redemption endpoint — `POST /view/redeem`, token in the **body**, exchanged for a scoped cookie.
3. `ConnectionRole` on `/rpc` — default-deny viewer allowlist, with `session_id` params pinned to the grant.
4. `notify` event scoping in `EventHub`.
5. `crow share create | list | revoke` CLI verbs + backing RPCs.
6. Viewer route `#/view/<token>` in `app.js` — metadata, PR status, artifacts. Read-only affordances only.

**Out (later phases, do not build here):**

- Live terminal follow / any PTY for viewers — Phase 2, and see spike §1.3 before choosing an approach.
- Terminal scrollback for viewers — the `terminalScrollback` capability may be *defined* in the model but must be unimplemented and rejected in Phase 1.
- In-app Share button, active viewer count, revoke UI — Phase 3.
- Any change to owner behaviour. An owner's `/rpc`, `/terminal`, and cookie handling must be byte-identical after this change.

## Requirements

### R1 — The gate is default-deny, and `isWrite` is not the predicate

Add a viewer allowlist **separate from `RPCWebSocketHandler.localOnlyDenial`**. That function is default-*allow* (deny 8 named methods); reusing it or adding viewer cases to its `switch` would grant a viewer every method nobody remembered to name.

Exactly six methods are viewer-reachable, all pinned to the grant's session:

| Method | Param to pin |
|---|---|
| `get-session` | `session_id` |
| `list-links` | `session_id` |
| `list-worktrees` | `session_id` |
| `list-terminals` | `session_id` |
| `list-artifacts` | `session_id` |
| `get-pr-status` | `session_id` |

Everything else — all 91 remaining methods — is denied. Note in particular that 23 of the 29 `ParityLedger` `.read(…)` methods must be denied, including `get-state`, `list-sessions`, `list-sessions-live`, `get-config`, and `defaults-get`. **Do not derive the allowlist from `isWrite`.**

Allowlisting a method name is insufficient: all six handlers take `session_id` as a parameter and trust it (`EngineRouter.swift:280`, `:695`, `:854`, `:1079`, `:321`; `RPCHandlers.swift:617`). The gate must reject a request whose `session_id` is not the granted one.

Additionally strip `path` and `dir` from `list-artifacts` responses to viewers — absolute filesystem paths are a needless disclosure to a non-owner.

### R2 — The viewer role must not be reachable through the local-direct fast path

`WebAuthGuard.authorize` returns `Decision(isAuthorized: true, reason: "local")` for a loopback peer with no `X-Forwarded-For` *before loading config* (`WebAuth.swift:174-176`), and `RPCWebSocketHandler` skips its gate entirely when `localDirect` (`:114`). Evaluate the role independently of that path. Prefer extending `Decision` with the role over adding a second call at each site, so the check cannot be omitted at a future call site.

### R3 — Cookie must not collide with the owner's

Use a distinct cookie name **and** a distinct path — e.g. `crow_view` at `Path=/view` — not a second `crow_session` at `Path=/`. Same name + path means an owner who opens a link they minted overwrites their own session, and re-logging-in revokes the viewer's. A distinct path also means the browser never attaches the viewer cookie to `/rpc` at all.

Keep the existing flags: `HttpOnly; Secure; SameSite=Lax`.

### R4 — Redemption happens at a real endpoint

`#/view/<token>` is a URL fragment; it never reaches the server (ADR 0018), so the mitigation "rate-limit `/view/*`" in #947 cannot work as written. Keep the token in the fragment — that keeps it out of server logs, `Referer`, and proxy access logs — and add `POST /view/redeem` taking the token **in the body**, returning the R3 cookie. Strip the fragment client-side after redemption.

Rate-limit redemption with a **separate** limiter instance. `LoginRateLimiter` is global rather than per-IP by design (`WebAuth.swift:127-130`, because behind a proxy every attempt shares the loopback peer); sharing one instance means guessing traffic against share links locks the owner out of `/login`.

### R5 — Grants expire and persist

Default TTL 24 h, settable via `crow share create --expires`. Reuse the existing sweeper shape — `sessions.prune()` already runs on a 300 s timer at `CrowDaemon.swift:491`.

Persist in `store.json`, not `config.json`. **Use the single injected `JSONStore` owned by `SessionService`** — a throwaway `JSONStore()` reads its own stale snapshot and its whole-store write can clobber a record another writer just added (#728, and `CLAUDE.md` § Concurrency Safety).

### R6 — Scope `notify`, leave `changed` alone

`EventHub.changedFrame` carries no payload (`EventHub.swift:18`) — it is a re-fetch nudge and needs no filtering, because the re-fetch itself goes through R1. `notify` carries `{event, key, title, body}` (`:66`) with per-session automation text and **does** leak across sessions. Add an optional session scope to `subscribe` (`:25`) and a predicate in `broadcast` (`:38`).

### R7 — Never shareable

Reject grant creation for: the Manager session, any session with no worktree, and global terminals. Enforce server-side at mint time *and* at connection time — a session can become a Manager-adjacent thing after a grant is minted.

## Build gates (these fail CI, not review)

- **`ParityLedger.rpcMethods`** — every new `share-*` RPC needs a row, or `RPCLedgerParityTests` fails. Add a `viewerReachable` classification column in the same change so the six-method allowlist is enumerated where the parity test gates it; a future RPC then cannot become viewer-reachable without an explicit decision.
- **`RPCLanePolicy.rules`** — every new method needs an entry or `RPCLanePolicyTests` fails.
- **ADR 0016** (`docs/adr/0016-cli-control-plane-parity.md`) — every user-mutable capability needs a CLI path, enforced by `scripts/check-cli-parity.sh` on the Linux lane. This is why `crow share …` is in scope rather than deferred with the UI.
- **ADR 0019** (to be written) — the client-authority-tiers ADR should land **before or with** this ticket. The spike's §6 explains why: ADR 0009 states "no client is privileged", and this introduces the first mintable, delegable credential class. Do not merge this without that record.

## Acceptance

- [ ] A viewer connection calling `get-state`, `list-sessions`, `get-config`, or `defaults-get` receives a denial — asserted per method, not by sampling.
- [ ] A viewer calling `get-session` with a `session_id` other than the grant's receives a denial.
- [ ] A viewer's `/terminal` upgrade is refused outright (no PTY in Phase 1).
- [ ] A viewer receives `changed` frames but no `notify` frame keyed to another session.
- [ ] An expired or revoked grant is refused at redemption **and** on an already-open socket.
- [ ] Minting against the Manager session is refused.
- [ ] An owner opening their own share link does not lose their owner session (R3).
- [ ] Grants survive a `crowd` restart; `crow share revoke` survives one too.
- [ ] Owner behaviour unchanged — existing `DaemonSecurityTests` and `LocalOnlyRPCGateTests` pass untouched.

## Testing notes

- Extend `DaemonSecurityTests` rather than starting a new file — it already holds the local-only gate's cases and the read/write reasoning they encode.
- A table-driven test asserting **all 97** methods against the viewer gate is worth more than six positive cases: it is what makes a newly added method fail loudly instead of defaulting open.
- Client changes need a jsdom suite under `Packages/CrowDaemon/web-tests/`, and it must be added to `package.json`'s `test:ci` script explicitly or CI silently skips it.
- Per ADR 0012 (`docs/adr/0012-tests-never-touch-live-data.md`), grant-store tests must not touch a live `store.json`.

## Estimate

Plumbing is ~3 Swift files and ~120 lines (spike §2). The audit and its tests are the majority of the work, and the `ParityLedger` column is what keeps that audit from decaying.
