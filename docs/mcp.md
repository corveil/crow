# MCP

Crow serves a **read-only** MCP surface, so clients that speak the Model Context
Protocol — Cowork, a Grok bot, Claude on the web, Desktop and mobile — can read the
board without a Crow-launched agent session.

> **Scope.** This page is about `crowd` *serving* MCP. It is a different axis from
> Crow *provisioning* MCP servers into coding agents, which Crow deliberately does
> not do — the user configures `mcpServers` in `~/.claude.json` and Crow only
> mirrors it into other harnesses (CROW-528, [configuration.md](configuration.md)).
> See [ADR 0019](adr/0019-read-only-mcp-server.md) for why the two coexist.

## What it can and cannot do

**Read-only, and structurally so.** The tool catalog is a closed allowlist of eight
tools over seven read RPC methods. There is no passthrough tool and no way to name an
RPC method from the wire, so the local-only surfaces — gateways, the web password,
MCP tokens themselves, `run-setup`, hook events, host-app launches, the Corveil CLI
verify/reinstall actions — are unreachable regardless of transport or scope.

There is **no prompt-send**: nothing here can type into an agent's terminal, create
a session, change a status, or write config. That is deliberate and enforced by a
build gate (`MCPLedgerExportTests`), not by convention.

## Transports

| Transport | How | Credential | For |
| --- | --- | --- | --- |
| stdio | `crow mcp serve` | none | a client on the machine running `crowd` |
| HTTP | `POST /mcp` | `Authorization: Bearer crow_mcp_…` (minted) | an off-box client that can send a header |
| HTTP + OAuth | `POST /mcp` | an OAuth access token, after you approve the app | Claude's connectors: claude.ai, Claude Desktop, the mobile apps |

The split is the trust model. A caller who can run `crow mcp serve` can already run
every other `crow` verb against the 0600 Unix socket, so a token there would gate
nothing. A caller arriving over HTTP has proven nothing, so it presents a scoped,
expiring token — either one you minted and pasted, or one Crow issued over OAuth to
an app you approved with the web password.

## Scopes

| Scope | Grants |
| --- | --- |
| `sessions:read` | `get_board_summary`, `list_sessions`, `get_session`, `list_stuck_sessions` |
| `board:read` | `list_tickets`, `list_reviews` |
| `todos:read` | `list_todos`, `get_todo` |

There is no `sessions:write`, no `prompt:send`, and no `admin` — not "not yet
implemented" but *not defined*, so a token cannot name a capability the server might
later grow into.

`tools/list` is **filtered by the presented token**, not merely enforced at call
time: a `board:read` token never sees that the session tools exist. A
deny-after-call would still teach the model that they do.

## Tools

| Tool | Scope | Answers |
| --- | --- | --- |
| `get_board_summary` | `sessions:read` | Counts by status, with the session names under each |
| `list_sessions` | `sessions:read` | Sessions, filterable by status and kind |
| `get_session` | `sessions:read` | One session in full, by UUID |
| `list_stuck_sessions` | `sessions:read` | What needs a human, and why |
| `list_tickets` | `board:read` | The ticket board (issue bodies omitted) |
| `list_reviews` | `board:read` | The reviews board, by group |
| `list_todos` | `todos:read` | Scratch items, with their provenance trail |
| `get_todo` | `todos:read` | One Scratch item in full, by UUID |

`list_stuck_sessions` is the one worth knowing about. It joins two payloads that are
disjoint on their own — `list-sessions` carries the agent's activity and pending
attention, `list-sessions-live` carries PR checks and the auto-merge / auto-rebase
watcher verdicts — and reports each reason with its underlying message:

`waiting_on_input` · `idle_too_long` · `checks_failing` · `auto_merge_stuck` ·
`auto_rebase_stuck`

`list_tickets` drops the issue `body`, the only unbounded field in that payload; one
long issue would otherwise crowd the rest of the board out of the model's context.
Open the row's `url` for the full text.

## Local client (stdio)

Point any MCP client at the `crow` binary:

```json
{
  "mcpServers": {
    "crow": {
      "command": "crow",
      "args": ["mcp", "serve"]
    }
  }
}
```

Narrow it if the client only needs one half:

```json
{ "command": "crow", "args": ["mcp", "serve", "--scope", "board:read"] }
```

`crowd` must be running — `crow mcp serve` is a bridge to it, not a second copy of
the engine. If the daemon is down, tool calls come back as `isError` results saying
so rather than dropping the connection.

## Remote client (HTTP)

Mint a token on the machine running `crowd` — minting is local-only, so this cannot
be done from a remote browser or over `/rpc`:

```bash
crow mcp token mint --name grok-bot --scope board:read
```

```json
{
  "saved": true,
  "token": "crow_mcp_kJ8x…",
  "warning": "This token is shown once and cannot be recovered.",
  "record": { "id": "…", "name": "grok-bot", "prefix": "kJ8x…", "expires_at": "…" }
}
```

Copy it now. Only a SHA-256 hash is stored, so there is no `--reveal` to come back
to; a lost token is replaced, not recovered.

Then point the client at the endpoint:

```json
{
  "mcpServers": {
    "crow": {
      "url": "https://crow.example.ts.net/mcp",
      "headers": { "Authorization": "Bearer crow_mcp_kJ8x…" }
    }
  }
}
```

Or by hand:

```bash
curl -s https://crow.example.ts.net/mcp \
  -H 'Authorization: Bearer crow_mcp_kJ8x…' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

**Expose it the same way you expose the web UI**: bind `crowd` to loopback and put
an HTTPS proxy (Tailscale serve, ngrok) in front. `/mcp` does not require the web
password — a bearer token replaces it — but it does not create a way in that the
proxy has not already permitted.

Tokens are listed and revoked from either side:

```bash
crow mcp token list
crow mcp token revoke --name grok-bot
```

Settings → Web access has the same controls, local browser only.

## Claude connectors (Desktop, mobile, web)

Claude's custom connectors run in Anthropic's cloud, not on your machine, and they
can't send a fixed `Authorization` header. They authenticate with OAuth, as the MCP
authorization spec describes, so Crow acts as its own OAuth authorization server for
`/mcp`. A connector added on claude.ai also works in Claude Desktop and the mobile
apps.

What happens when you add the connector:

1. Claude calls `/mcp`, gets a `401` whose `WWW-Authenticate` carries
   `resource_metadata="https://<host>/.well-known/oauth-protected-resource/mcp"`, and
   reads that document and `/.well-known/oauth-authorization-server`.
2. It registers itself at `/oauth/register` (RFC 7591 dynamic client registration,
   as a public client).
3. It opens `/oauth/authorize` in your browser. Crow shows a consent page with the
   app's name, the host it will send you back to (`claude.ai`), and a checkbox per
   scope. **You approve with Crow's web password.**
4. Claude exchanges the code (PKCE `S256` is mandatory) at `/oauth/token` and gets a
   one-hour access token and a refresh token, which rotates every time it is used.

### Set a web password first

Once these endpoints are public, the consent page is the only thing between a
stranger and a token. Web auth is opt-in, so the consent page does not rely on it:
it **always** asks for the web password, from localhost too. If no web password is
set, it says "Set a web password first" and issues nothing.

```bash
crow web-password set
```

Or Settings → Web access, from a local browser.

### Expose only the MCP paths

Anthropic's servers must reach `/mcp`, so a tailnet-only `tailscale serve` is not
enough. Use Tailscale Funnel, but put it on its own port so the web UI stays
tailnet-only. Funnel is switched on per port, not per path, so funneling the port
your web UI uses would make the whole UI public.

Keep `crowd` bound to loopback (the default, `127.0.0.1:8787`), then publish only
these paths on port `8443`:

```bash
tailscale funnel --bg --https=8443 --set-path=/mcp http://127.0.0.1:8787/mcp
tailscale funnel --bg --https=8443 --set-path=/.well-known/oauth-protected-resource \
  http://127.0.0.1:8787/.well-known/oauth-protected-resource
tailscale funnel --bg --https=8443 --set-path=/.well-known/oauth-authorization-server \
  http://127.0.0.1:8787/.well-known/oauth-authorization-server
tailscale funnel --bg --https=8443 --set-path=/oauth http://127.0.0.1:8787/oauth
tailscale funnel status
```

Then check that only those paths are public. From a machine **off** your tailnet:

```bash
curl -s https://<machine>.<tailnet>.ts.net:8443/.well-known/oauth-protected-resource/mcp | jq .
# → "resource": "https://<machine>.<tailnet>.ts.net:8443/mcp"

curl -s -o /dev/null -w '%{http_code}\n' https://<machine>.<tailnet>.ts.net:8443/
# → 404 — the web UI is not on the Funnel port
```

Any tunnel that forwards those four path prefixes over HTTPS and sets
`X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host` (cloudflared and ngrok
can) works the same way. Crow derives every URL in the metadata from those headers,
and trusts them only from a loopback peer.

The OAuth endpoints refuse a request that reached `crowd` directly from another
machine, or through a proxy that forwarded plain HTTP: the web password and refresh
tokens must not cross the network in clear.

### Add the connector

In claude.ai, open **Settings → Connectors → Add custom connector**. Enter a name and
the URL `https://<machine>.<tailnet>.ts.net:8443/mcp`. Leave the OAuth client ID and
secret empty; Claude registers itself. Click **Connect**, then approve on Crow's
consent page with the web password and the scopes you want.

Ask Claude on your phone "what's stuck in Crow?" and it calls `list_stuck_sessions`.

### What a connected app holds

| | Lifetime | Stored by Crow as |
| --- | --- | --- |
| Access token | 1 hour | an ordinary `mcpTokens` record (SHA-256 hash), linked to its grant |
| Refresh token | 30 days, renewed on every use | a SHA-256 hash on the grant; each use replaces it |
| Authorization code | 5 minutes, single use | a SHA-256 hash, in memory only |

The scopes you tick at consent are the most the app can ever have. `tools/list` is
filtered by them exactly as for a minted token, and a refresh can narrow them but
never widen them. A code used twice revokes the grant it produced, because a second
use means someone else has the code.

Connected apps appear in `crow mcp token list` under `grants`, and in Settings → Web
access under **Connected apps**. Revoking one kills its refresh token and every
access token it holds:

```bash
crow mcp token revoke --name Claude
```

Fresh registrations are kept in memory until you approve one, so an
unauthenticated caller can't grow `config.json`. If `crowd` restarts between Claude
registering and you approving, start the connection again.

Crow advertises dynamic registration only. It does not accept Client ID Metadata
Documents, because that would mean fetching an arbitrary URL on an unauthenticated
request. Claude falls back to dynamic registration when CIMD is not advertised.

## Protocol support

Crow is **dual-era**: it answers both the current stateless revision and the older
handshake, on one endpoint, deciding per request.

| Revision | How a request identifies itself | Supported |
| --- | --- | --- |
| `2026-07-28` | `_meta["io.modelcontextprotocol/protocolVersion"]` + `MCP-Protocol-Version` header | yes — including the mandatory `server/discover` |
| `2025-11-25`, `2025-06-18`, `2025-03-26` | an `initialize` handshake | yes |

That matters because `2026-07-28` removed the `initialize` handshake, protocol-level
sessions, and the GET stream only recently, and most shipping clients still open with
the handshake. A client needs to know nothing about this.

HTTP specifics, for anyone debugging with `curl`:

| Situation | Response |
| --- | --- |
| No or bad token | `401` + `WWW-Authenticate: Bearer realm="crow-mcp", resource_metadata="…"` (`error="invalid_token"` when a token was presented) |
| Invalid `Origin` | `403` |
| `GET` / `DELETE /mcp` | `405` — this revision has no GET stream or sessions |
| Unknown method | `404` + JSON-RPC `-32601` |
| Unsupported protocol version | `400` + `-32022`, carrying the `supported` list |
| Header disagrees with body | `400` + `-32020` |
| Notification (no `id`) | `202`, no body |

## See also

- [ADR 0019](adr/0019-read-only-mcp-server.md) — why the surface is task-shaped
  rather than one tool per RPC, and how it relates to CROW-528
- [ADR 0016](adr/0016-cli-control-plane-parity.md) — the ledger that gates which
  RPCs may be exported
- [cli-reference.md](cli-reference.md#mcp-commands) — the `crow mcp` verbs
