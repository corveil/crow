# 0019 — MCP is a third client, not a mirror of the RPC surface

- **Status:** Accepted
- **Date:** 2026-08-13
- **Deciders:** @dhilgaertner

## Context

Crow's control plane is JSON-RPC, reachable two ways: the `crow` CLI over a 0600
Unix socket ([ADR 0002](./0002-unix-socket-cli-architecture.md)) and the web client
over `/rpc` ([ADR 0009](./0009-crowd-sole-authority-clients-only.md)). Both are
first-party clients we ship.

Two consumers arrived that are neither. Cowork runs on the same machine as `crowd`
and wants to answer questions about the board. A Grok bot runs somewhere else
entirely and wants the same. Neither has a Crow-launched agent session to drive the
CLI from, and neither speaks Crow's dialect of JSON-RPC — they speak MCP.

The obvious implementation is a thin adapter: enumerate `CommandRouter.methodNames`
and emit one MCP tool per RPC method. That is wrong three times over.

**It blows the context.** There are ~101 methods. A tool list that large costs
thousands of tokens on every `tools/list` and pushes the model toward the wrong tool
by sheer surface area — the question "what needs attention?" has no single RPC
answer, so the model would have to discover the `list-sessions` /
`list-sessions-live` join itself, every time.

**It leaks what `/rpc` already refuses.** `RPCWebSocketHandler.localOnlyDenial` keeps
`gateway-*`, `web-password-*`, `run-setup`, `hook-event`, and the host-app launches
away from remote peers. A 1:1 adapter would re-expose all of them unless it grew a
second, parallel denial list — and two lists that must agree are a list that will
eventually disagree.

**It makes every future RPC a public API.** Under a 1:1 rule, adding a handler
silently adds a Grok-reachable tool. The failure is invisible: nothing breaks, the
surface just quietly widens.

There is also a decision to reconcile. **CROW-528** established that Crow
*provisions* no MCP of its own — the user configures `mcpServers` in `~/.claude.json`
and Crow only mirrors that into Codex, Cursor and OpenCode. Serving MCP looks like a
reversal and is not one; the two are opposite directions on the same wire.

## Decision

**MCP is a third client with a task-shaped surface, generated from an allowlist the
`ParityLedger` gates. It is read-only.**

Four parts:

**1. A closed tool catalog, not a projection.** `MCPToolCatalog` (in `CrowIPC`)
declares six tools over five read methods. Tools are shaped to questions, not to
handlers — `list_stuck_sessions` joins `list-sessions` and `list-sessions-live`,
which are disjoint payloads that neither answer alone, and `list_tickets` drops the
unbounded issue `body`. There is no passthrough tool, so an RPC method cannot be
named from the wire.

**2. The ledger decides what may be exported.** `ParityLedger.RPCEntry` gains
`mcp: MCPExposure`, defaulting to `.none`. A new RPC is therefore *not* exported
unless someone types `mcp: .read(scope:)` on its row — the ledger diff is the review
surface, exactly as [ADR 0016](./0016-cli-control-plane-parity.md) intends for CLI
coverage. `MCPLedgerExportTests` fails the build when a tool reads an unflagged
method, when a flagged method has no tool, when an exported method is a write, or
when an exported method is local-only.

**3. Two transports, two trust models.** `crow mcp serve` bridges stdio to the Unix
socket with no token: a caller who can run it can already run every `crow` verb, so a
token would gate nothing. `POST /mcp` requires a scoped bearer token that expires by
default. The endpoint is exempt from `WebAuthMiddleware` and authenticates itself,
which is *stricter* than the middleware — that gate is opt-in and inert when no web
password is set, while `/mcp` never has a tokenless path.

*Amended by CROW-1465:* `POST /mcp` also accepts OAuth access tokens, a third
credential path for clients that cannot send a fixed header. See
[the amendment below](#amendment-oauth-for-claude-connectors-crow-1465).

**4. Dual-era protocol.** Revision `2026-07-28` replaced the `initialize` handshake
with per-request metadata and a mandatory `server/discover`. It is weeks old;
shipping clients still open with the handshake. The spec blesses serving both on one
endpoint, and we do, deciding per request. Clients need to know nothing.

### Relationship to CROW-528

CROW-528 is about **Crow writing MCP config into coding agents** — it decided Crow
provisions nothing and merely mirrors the user's own `~/.claude.json`. This ADR is
about **`crowd` answering MCP requests**. Crow as MCP *client-config author* versus
Crow as MCP *server*: opposite directions, no conflict. CROW-528's rule stands
unchanged, and nothing here writes to any harness's config.

## Consequences

**Easier.** "What can a Grok bot reach?" is a grep of `MCPToolCatalog`, and the
answer cannot drift from the ledger without failing a test that runs in the Linux PR
lane. The model gets six well-named tools instead of a hundred, and the one question
operators actually ask — what needs a human — has a tool that answers it directly
instead of requiring a join the model has to rediscover.

**Harder.** Every new tool is hand-written: a schema, a shaping function, a ledger
flag, and a scope decision. That is more work than a projection would be, and it is
the work we want done deliberately. Growing the surface to writes is a bigger step
still, because `exportedMethodsAreReadOnly` fails the build until someone changes the
test — which is the point at which a human decides.

**Lived with.** The MCP layer lives in `CrowIPC`, so **`CrowIPC` now depends on
`CrowCore`** (for `MCPScope` and `MCPTokenRecord`, which `ParityLedger` and
`AppConfig` need and therefore cannot leave). That inverts nothing — `CrowCore` has
no dependencies at all, so the graph stays acyclic — but it does mean the wire
package is no longer a leaf. The alternative was putting `JSONValue` in `CrowCore`,
a much larger refactor of a type ~100 files touch.

Placement is also what makes the gate run: `CrowIPC` and `CrowCore` are both in
`ci.yml`'s `LINUX_PACKAGES`, while `CrowDaemon` is Darwin-only and its tests do not
run on PRs ([ADR 0007](./0007-linux-ci-swift.md)). Only Hummingbird route wiring and
the SHA-256 stayed in the daemon.

**A second mirror to keep honest.** `ParityLedger.localOnlyRPCMethods` restates the
unconditional cases of `RPCWebSocketHandler.localOnlyDenial` so the export gate can
assert disjointness from `CrowCore`. A mirror that can drift is worse than none, so
`LocalOnlyRPCGateTests` pins the two in both directions. This is the same split
ADR 0016 already makes for the RPC ledger: the authoritative check beside the truth,
a mirror where CI can see it.

**Token hashing diverges from the web password, deliberately.** `WebAuthConfig` uses
PBKDF2 at 210,000 iterations because it protects a low-entropy human password.
An MCP token is 32 CSPRNG bytes we generate, so guessing is 2²⁵⁶ regardless of KDF —
and it is verified on *every request* rather than once per login, where 210,000
iterations would be a self-inflicted denial of service. SHA-256, constant-time
compared, no salt. Same reasoning as a GitHub personal access token. This will look
like an inconsistency to anyone reading the two files side by side; it is not.

## Amendment: OAuth for Claude connectors (CROW-1465)

**Context.** Claude's custom connectors (claude.ai, Claude Desktop and the mobile
apps) call MCP servers from Anthropic's cloud and authenticate with OAuth as the MCP
authorization spec describes it, or not at all. They cannot send
`Authorization: Bearer crow_mcp_…`, so no Claude connector could reach `/mcp`.

**Decision.** Crow is its own OAuth 2.1 authorization server for `/mcp`. That is a
third credential path beside stdio (locality) and minted tokens:

- **Discovery.** A `401` from `/mcp` carries `resource_metadata` (RFC 9728), and
  Crow serves protected-resource metadata and authorization-server metadata
  (RFC 8414). Every URL is derived from `X-Forwarded-Host` / `-Proto`, trusted only
  from a loopback peer, the same assumption `WebAuthGuard` makes.
- **Registration.** Dynamic registration (RFC 7591) registers public clients only:
  `token_endpoint_auth_method: none`, `https` or loopback redirect URIs. Fresh
  registrations live in memory until approved, so an unauthenticated caller can
  never grow `config.json`. Client ID Metadata Documents are not supported, because
  they would have the daemon fetch an arbitrary URL on an unauthenticated request.
- **Consent is the gate, and it requires the web password.** Once the OAuth paths
  are public, consent is the only check between a stranger and a token. Web auth is
  opt-in, so a consent that leaned on `WebAuthMiddleware` would approve anyone on a
  daemon with no password. The consent POST therefore always verifies the web
  password, from loopback too, and with none configured it refuses and issues
  nothing. It has its own rate limit, separate from `/login`'s, so a stranger
  hammering the public consent page cannot lock the operator out of the web UI.
- **Tokens.** Authorization code with mandatory PKCE `S256`. Codes are single-use,
  expire after five minutes, and a replay revokes the grant they produced. Access
  tokens are ordinary `MCPTokenRecord`s with a one-hour expiry and a `grantID`, so
  `MCPRoutes` validates them with the code it already had, and they reach only
  `MCPToolCatalog`. Refresh tokens are SHA-256-hashed on the grant
  (`AppConfig.mcpOAuthGrants`) and rotate on every use.
- **Management.** No verb creates a grant; approving one is a browser action that
  shows which client is being approved. `crow mcp token list` and Settings → Web
  access list grants, and `crow mcp token revoke` removes a grant with all of its
  access tokens. These stay local-only.

**Not changed.** The tool catalog, the scopes, and `exportedMethodsAreReadOnly`.
OAuth is another way to *hold* a read-only token, not a way to widen one. Write
tools over MCP remain a separate decision.

**Consequence.** Publishing `/mcp` is the operator's step. The documented setup
funnels only `/mcp`, the `.well-known` metadata paths and the three `/oauth/`
endpoints, each as an exact-path mount, on a dedicated port. Funnel is enabled per
port, so funneling the web UI's port would make the whole UI public.

## Alternatives considered

**One MCP tool per RPC method.** Mechanical, always current, no catalog to maintain.
Rejected for the three reasons under *Context* — chiefly that it makes every future
handler a public API by default, with an invisible failure mode.

**An off-the-shelf Swift MCP SDK.** None is a declared dependency today, and the
protocol surface we need is small: six methods, no SSE, no sampling, no resources.
Vendoring an SDK to gain `tools/list` would add a dependency to the daemon and still
leave the dual-era decision, the auth, and the catalog to write. Reconsider if the
server ever needs streaming or elicitation.

**Modern-only (`2026-07-28`).** Cleanest code — stateless, no handshake, one path.
Rejected because the revision is two weeks old and the clients this exists for
almost certainly still send `initialize`, which would fail with no fall-forward
mechanism for them to recover from.

**Reusing `JSONRPCRequest` / `JSONRPCResponse` for MCP.** They are a narrow subset:
`id` is a non-optional `Int`, results are always dictionaries, errors carry no
`data`, and notifications have no representation. MCP needs all four. Widening the
shared types would touch every RPC path to serve one client; a separate envelope
that converts inward at one point is smaller and safer.

**Gating MCP behind the web password instead of tokens.** One credential, already
built. Rejected because it is all-or-nothing (no scopes, no expiry, no revoking one
client), because the cookie is a browser affordance a bot would have to emulate, and
because it is opt-in — a daemon with no web password would serve MCP to anyone who
could reach it.

## References

- Ticket: [corveil/crow#1004](https://github.com/corveil/crow/issues/1004)
- Related ADRs: [0002](./0002-unix-socket-cli-architecture.md) (the Unix socket and
  its trust model), [0007](./0007-linux-ci-swift.md) (why the export gate lives in
  `CrowIPC`), [0009](./0009-crowd-sole-authority-clients-only.md) (crowd is the sole
  authority; MCP is a client like any other),
  [0016](./0016-cli-control-plane-parity.md) (the ledger this extends)
- Code: `Packages/CrowIPC/Sources/CrowIPC/MCP/`,
  `Packages/CrowCore/Sources/CrowCore/Models/MCPToken.swift`,
  `Packages/CrowCore/Sources/CrowCore/Parity/ParityLedger.swift`,
  `Packages/CrowDaemon/Sources/CrowDaemon/MCPRoutes.swift`,
  `Packages/CrowCLI/Sources/CrowCLILib/Commands/MCPCommands.swift`
- Docs: [`docs/mcp.md`](../mcp.md)
