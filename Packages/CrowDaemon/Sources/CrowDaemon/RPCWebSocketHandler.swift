import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

/// Serves the existing JSON-RPC protocol over a WebSocket at `/rpc`.
///
/// One JSON object per WebSocket message: decode a ``JSONRPCRequest``, run it
/// through the shared ``CommandRouter`` (the very same router the Unix-socket
/// server uses), and write the ``JSONRPCResponse`` back. No semaphore bridge —
/// unlike `SocketServer`, we're already in an async context (CROW-581).
///
/// A single writer task owns `outbound`: both RPC responses and `EventHub`
/// broadcast notifications flow through one per-connection `AsyncStream`, so
/// they never interleave frames on the socket (CROW-581, M-D).
///
/// The reader does **not** run handlers itself. It hands each request to a
/// per-connection ``RPCDispatcher`` and immediately reads the next frame, so a
/// slow method can no longer hold the socket's read loop and time out every
/// request queued behind it (#931). Responses may therefore arrive out of
/// order — safe by construction, since the client correlates by JSON-RPC id —
/// while ``RPCLanePolicy`` keeps writes to the same session (or the same config
/// file, Manager, or job) in strict arrival order.
enum RPCWebSocketHandler {
    static func mount(
        on router: Router<CrowWSContext>,
        commandRouter: CommandRouter,
        eventHub: EventHub,
        boundHost: String,
        sessions: SessionStore,
        devRoot: String
    ) {
        router.ws("/rpc") { request, context in
            // Reject cross-site upgrades (Origin) AND unauthenticated non-local
            // access (web password) — `/rpc` reaches `add-worktree`, which shells
            // out to git (CROW-581 review, CROW-593).
            let originOK = WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
            let auth = WebAuthGuard.authorize(
                remoteAddress: context.remoteAddress,
                cookieHeader: request.headers[.cookie],
                forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!],
                forwardedProto: request.headers[HTTPField.Name("x-forwarded-proto")!],
                configProvider: { ConfigStore.loadConfig(devRoot: devRoot) },
                sessions: sessions)
            return (originOK && auth.isAuthorized) ? .upgrade() : .dontUpgrade
        } onUpgrade: { inbound, outbound, wsContext in
            // Captured at upgrade: first-run `run-setup` is a write+re-exec and
            // must stay local-direct (loopback, no XFF) like SecretRoutes — on a
            // non-loopback bind with auth still inert, Origin alone isn't enough
            // (review Yellow / CROW-605).
            let localDirect = WebAuthGuard.isLocalDirect(
                remoteAddress: wsContext.requestContext.remoteAddress,
                forwardedFor: wsContext.request.headers[HTTPField.Name("x-forwarded-for")!])
            // One outbound channel per connection: RPC responses (from the
            // dispatched operations) and hub notifications (fanned in via
            // `subscribe`) both feed the single writer below.
            let (outStream, outCont) = AsyncStream.makeStream(of: String.self)
            let subscription = await eventHub.subscribe(outCont)
            // Handlers no longer run on the read loop (#931).
            let dispatcher = RPCDispatcher()
            // Carries an abnormal read failure past the task group so it can be
            // rethrown once teardown is done. A child task's error is otherwise
            // discarded when the group's scope exits, which is why an over-limit
            // message used to close as if the client had simply gone away —
            // `WSCore` maps `InternalError.close(_:)` to a close code only if the
            // error reaches it, so the client had no way to tell "too big" from
            // "daemon died" (CROW-956).
            let readFailure = ErrorBox()

            // No `try`: `withThrowingTaskGroup` is `rethrows`, and this body
            // throws nothing — the one call that could, `group.next()`, is
            // deliberately `try?`'d below so `shutdown()` always runs. It stays a
            // *throwing* group because the child tasks throw; their errors are
            // simply discarded at scope exit, which is the whole reason
            // `readFailure` exists. Re-adding `try` only restores the warning
            // (CROW-993).
            await withThrowingTaskGroup(of: Void.self) { group in
                // Writer — the sole owner of `outbound`. Unchanged: responses
                // may now arrive out of order, but they still cross the socket
                // one frame at a time from one task, and the client correlates
                // by JSON-RPC id.
                group.addTask {
                    for await text in outStream {
                        try await outbound.write(.text(text))
                    }
                }
                // Reader — decode, hand off, read the next frame.
                group.addTask {
                    // Single-threaded on this task, so it stays hoisted. The
                    // encoder does NOT: `JSONEncoder` isn't `Sendable`, and the
                    // dispatched operations encode concurrently (see `emit`).
                    let decoder = JSONDecoder()
                    // The writer's stream must end however this task exits, or
                    // the group never unwinds. `finish()` is idempotent.
                    defer { outCont.finish() }

                    do {
                        for try await message in inbound.messages(maxSize: CrowDaemon.maxWebSocketFrameSize) {
                            let payload: Data?
                            switch message {
                            case .text(let text): payload = text.data(using: .utf8)
                            case .binary(let buffer): payload = Data(buffer.readableBytesView)
                            }
                            guard let data = payload,
                                  let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
                                continue
                            }

                            // The local-only gate stays on the sequential path. It
                            // is the security boundary, and for `set-config` it
                            // reads config.json from disk — a decision that must not
                            // be taken against a config another dispatch is mid-write
                            // on.
                            if !localDirect, let deny = Self.localOnlyDenial(for: request, devRoot: devRoot) {
                                Self.emit(
                                    .error(id: request.id, code: RPCErrorCode.invalidParams, message: deny),
                                    to: outCont)
                                continue
                            }

                            let lane = RPCLanePolicy.lane(for: request)
                            let accepted = await dispatcher.dispatch(lane: lane) {
                                let response = await commandRouter.handle(request: request)
                                Self.emit(response, to: outCont)
                            }
                            // Answer rather than drop: a refused request that got no
                            // reply would sit until the client's deadline, which is
                            // the symptom this whole change exists to remove.
                            if !accepted {
                                Self.emit(
                                    .error(
                                        id: request.id,
                                        code: RPCErrorCode.applicationError,
                                        message: "Too many requests in flight on this connection"),
                                    to: outCont)
                            }
                        }

                        // Inbound closed cleanly → let everything already accepted
                        // reach the writer before `defer` ends its stream. Released
                        // early by `shutdown()` below when the *writer* is what died.
                        await dispatcher.drain()
                    } catch {
                        // CROW-956: the line whose absence made an over-limit message
                        // indistinguishable from a dead daemon. Fires at most once per
                        // connection and only on an ABNORMAL end — a client that closes
                        // normally ends `messages(...)` without throwing and takes the
                        // `drain()` path above, so a browser tab closing stays silent.
                        // Cancellation is our own teardown (the writer died and the
                        // group is unwinding), so it stays silent too.
                        //
                        // Scope, measured rather than assumed: this catches a
                        // *fragmented* message over `maxSize`, which `WSCore` throws
                        // from `nextMessage`. It does NOT catch a single FRAME over
                        // `maxFrameSize` — NIO's decoder answers that one with a 1009
                        // close of its own, below this handler, and the inbound stream
                        // then simply ends, so that path takes the clean branch above
                        // and is diagnosable only from the client's close code. Do not
                        // "fix" that by widening the catch; there is nothing to catch.
                        //
                        // The cause is not matchable by type from here either: `WSCore`'s
                        // `InternalError` is package-private and `NIOWebSocket` is not a
                        // declared dependency. So interpolate it — `messageTooLarge`
                        // names itself. Do NOT branch on that string.
                        if !(error is CancellationError) {
                            CrowDaemon.log(
                                "WARNING: /rpc read ended abnormally (per-message limit "
                                + "\(CrowDaemon.maxWebSocketFrameSize) bytes) — socket closed, "
                                + "in-flight requests dropped: \(error)")
                            readFailure.set(error)
                        }
                    }
                }

                // When either side finishes (socket closed), tear the other down.
                // Still `try?`: this returns whichever task finished FIRST, so the
                // reader's error may not be the result observed here — it is caught
                // where it is produced, above. Turning this into a `do/catch` would
                // also risk skipping the `shutdown()` whose ordering is load-bearing.
                _ = try? await group.next()
                // Before `cancelAll`: this releases the reader if it is parked in
                // `drain()`, and unparks anything queued on a lane or a permit.
                // Cancelling the group first would leave those waiters suspended
                // — `Task<Void, Never>.value` and `withCheckedContinuation` do
                // not resume on cancellation — and the group would never unwind.
                await dispatcher.shutdown()
                group.cancelAll()
                outCont.finish()
            }

            await eventHub.unsubscribe(subscription)
            // After teardown, never before: `WSCore` turns this into the close
            // code the client sees (1009 for an over-limit message), so it has
            // to escape `onUpgrade` rather than die with its child task.
            if let error = readFailure.take() { throw error }
        }
    }

    /// One-slot, thread-safe error handoff from a connection's reader task to
    /// the `onUpgrade` closure that rethrows it. A plain `var` capture would be
    /// a data race across the task group.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ error: Error) { lock.lock(); defer { lock.unlock() }; self.error = error }
        func take() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }

    /// Encode and enqueue one response for the connection's single writer.
    ///
    /// The encoder is built per call rather than hoisted per connection as it
    /// once was: `JSONEncoder` is not `Sendable`, and dispatched operations now
    /// encode concurrently (#931). Allocation is cheap next to the handler that
    /// produced the response.
    private static func emit(
        _ response: JSONRPCResponse,
        to continuation: AsyncStream<String>.Continuation
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let out = try? encoder.encode(response),
              let text = String(data: out, encoding: .utf8) else { return }
        continuation.yield(text)
    }

    /// Methods / fields that must stay local-direct (loopback, no XFF), matching
    /// `SecretRoutes` — the shared `CommandRouter` can't tell a local Unix-socket
    /// caller from a remote `/rpc` peer (review Yellow / CROW-593).
    ///
    /// - `run-setup`: write+re-exec of an arbitrary `dev_root`.
    /// - `set-config` when `defaults.binaries` change: absolute local binary paths
    ///   that execute at the next agent launch (persistent RCE on an
    ///   unauthenticated non-loopback bind). Other `set-config` fields flow through.
    /// - `open-in-vscode` / `open-terminal`: launch a GUI app on the daemon host
    ///   at the worktree path — a remote peer must not spawn host processes (CROW-749).
    /// - `gateway-*` / `web-password-*`: the CLI's route to the same secret
    ///   surfaces `SecretRoutes` serves the browser (CROW-815). Writes must stay
    ///   local so a remote client can't change the password gating remote access;
    ///   **reads are gated too**, because `gateway-get` with `reveal` returns the
    ///   gateway auth headers verbatim. The web Settings UI is unaffected — it
    ///   reads gateway state through `get-config` (stripped) and writes through
    ///   `SecretRoutes`.
    ///
    /// Scheduled `jobs` are intentionally NOT gated here (CROW-665): the Jobs
    /// editor is a core web-Settings surface, so an authenticated remote session
    /// may edit them, matching how the desktop app manages jobs. The `job-*` RPCs
    /// are likewise un-gated (same jobs-array surface; today only the CLI, which is
    /// always local, uses them).
    ///
    /// `notifications-get` / `notifications-set` are un-gated for the same reason
    /// (CROW-813): they read and write `AppConfig.notifications`, which carries no
    /// secrets and is already remotely editable through un-gated `set-config` —
    /// Settings → Notifications is a core web surface. Gating only the CLI's path
    /// to it would be inconsistent, not safer.
    ///
    /// The tmux-maintenance methods (`restart-manager`, `restart-tmux-server`,
    /// `reload-tmux-config`, `launch-agent`, `retry-readiness`) are also NOT gated,
    /// deliberately: Settings → About's maintenance group calls the first three from
    /// the web, so gating them here would break that surface. They shell out on the
    /// daemon host but launch nothing on its GUI. `LocalOnlyRPCGateTests` pins this.
    ///
    /// The `telemetry-*` / `cleanup-*` / `ui-*` settings RPCs (CROW-814) and
    /// `automation-*` (CROW-812) are also NOT gated. An authenticated remote peer
    /// can already change every one of those fields through the un-gated
    /// `set-config` path — that is precisely what
    /// `setConfigHarmlessToggleIsAllowedRemotely` asserts, using
    /// `remoteControlEnabled`, an automation field — so gating the granular
    /// methods would only push remote callers back onto the whole-config blob,
    /// which puts workspaces, jobs, gateway URLs and credential shells on the wire
    /// instead of a handful of scalars. Un-gating is the *smaller* surface, not
    /// merely the consistent one. Settings → Automation is a core web surface, so
    /// gating only the CLI's path to it would be inconsistent, not safer. None of
    /// them can reach `defaults.binaries`.
    ///
    /// `defaults-get` / `defaults-set` (CROW-810) split along that same line, with
    /// one carve-out. `defaults-get` is NOT gated: it returns a strict subset of
    /// what un-gated `get-config` already sends every authenticated remote
    /// browser — `SettingsSecrets.strippedForTransport` blanks the Jira token, the
    /// webAuth hash/salt and gateway header values, but *not* `defaults.binaries`,
    /// and `settings.js` renders the corveil path (read-only) for remote peers
    /// today. The rule that falls out and is worth keeping: gate a *read* only
    /// when it returns what stripping would have removed. `gateway-get` with
    /// `reveal` does; this doesn't.
    ///
    /// `defaults-set` IS gated, but only when the request carries a `binaries`
    /// param — see the case below for why presence and not a diff.
    /// `defaults.binaries` therefore remains the sole local-only config field,
    /// now enforced across two methods instead of one.
    ///
    /// `agents-get` / `agents-set` (CROW-811) follow that same rule: they read and
    /// write `AppConfig.defaultAgentKind` + `agentsByKind`, which name a harness
    /// rather than carry a credential, and Settings → General's Agent pickers edit
    /// them remotely through `set-config` already. Note the neighbouring
    /// `defaults.binaries` — the *path* to an agent binary — stays local-only; the
    /// distinction is between choosing among binaries the daemon already found and
    /// telling it to execute a new one.
    ///
    /// The `workspace-*` RPCs (CROW-809) are NOT gated either, by the same
    /// argument: Settings → Workspaces is a core web surface whose every field is
    /// already remotely writable through `set-config`. The one thing that *would*
    /// justify gating — the per-workspace AI gateway — is excluded rather than
    /// gated: `WorkspaceRPC.workspaceJSON` reduces it to a `gateway_set` flag and
    /// a base URL, never the `customHeaders` values, and no `workspace-*` method
    /// writes it. Authoring that credential stays with `gateway-set`, which *is*
    /// gated above. So the remote-reachable surface here is strictly smaller than
    /// the `set-config` it replaces.
    ///
    /// Note this gate only guards the HTTP/WebSocket `/rpc` path. Every method here
    /// also has a `crow` CLI verb (CROW-818), and the CLI reaches the daemon over its
    /// 0600 Unix socket, which never passes through `localOnlyDenial` — a CLI caller
    /// is local by construction, so that is the intended trust model, not a bypass.
    static func localOnlyDenial(for request: JSONRPCRequest, devRoot: String) -> String? {
        switch request.method {
        case "run-setup":
            return "run-setup is local-only"
        case "hook-event":
            // Agent hook processes emit this over the daemon's 0600 Unix socket
            // (never /rpc), so a remote caller has no legitimate use for it. It
            // also mutates per-session hook state and appends to the bounded
            // unresolved-drop diagnostic log — gating it loopback-only keeps an
            // authenticated remote peer from poisoning that log's dedup cap or
            // forging session state (#903 review).
            return "hook-event is local-only"
        case "open-in-vscode", "open-terminal":
            // These launch a GUI app on the daemon host (VS Code / Terminal at
            // the worktree path). Restrict to loopback callers — a remote web
            // session must not spawn host processes (CROW-749).
            return "opening host apps is local-only"
        case "gateway-get", "gateway-set", "web-password-get", "web-password-set":
            // Secret reads *and* writes (CROW-815) — see the doc comment above.
            return "gateway and web-password management is local-only"
        case "mcp-token-list", "mcp-token-mint", "mcp-token-revoke":
            // MCP bearer tokens (CROW-1004). `mcp-token-mint` returns the plaintext
            // token exactly once, so a remote peer that could call it would be
            // minting itself the credential that gates remote MCP access — the same
            // shape of hole as a remote `web-password-set`. `mcp-token-list` returns
            // no secret but is gated alongside them, matching `web-password-get`.
            //
            // Note the `/mcp` endpoint itself is a *different* door: it authenticates
            // with a bearer token and reaches only `MCPToolCatalog`'s read-only
            // allowlist, which by construction contains none of the methods listed
            // in this switch. `MCPLedgerExportTests` asserts that emptiness.
            return "MCP token management is local-only"
        case "corveil-verify", "corveil-reinstall-skill":
            // Settings → Corveil CLI's two buttons (CROW-1011). Both execute
            // `defaults.binaries["corveil"]` — an absolute path on the daemon
            // host — so they hand a caller the arbitrary-execution half of the
            // capability that field's *write* gate (below) exists to withhold,
            // reachable from a read of config that is not gated. `open-in-vscode`
            // / `open-terminal` are gated on the same argument: a remote session
            // does not get to spawn host processes.
            return "corveil verify and reinstall are local-only"
        case "corveil-connect", "corveil-status", "corveil-disconnect", "corveil-orgs":
            // The Corveil connection write path (CROW-1120). `corveil-connect`
            // stores OAuth tokens and `corveil-disconnect` clears the connection —
            // both author a credential, exactly like `gateway-set`. The two reads
            // carry no secret, but are gated alongside the writes so the whole
            // connection is one local-only surface, the same way `mcp-token-list`
            // is gated beside the mint/revoke it lists. A remote browser that needs
            // a read-only Integrations view still gets the non-secret fields
            // through the stripped `get-config` (`SettingsSecrets`), so nothing web
            // breaks. The browser's own write door is `POST /config/corveil-connection`
            // in `SecretRoutes`, gated the same way.
            return "Corveil connection management is local-only"
        case "corveil-list-orgs", "corveil-select-org", "corveil-deselect-org":
            // Org listing + one-key-per-org provisioning (CROW-1121). All three act
            // with the stored OAuth bearer — a credential — against Corveil: listing
            // the user's orgs and minting/revoking the per-org gateway key. A remote
            // peer must no more drive a key mint than it may read the token that
            // authorizes it, so these are gated exactly like the connection verbs
            // above. The read-only Integrations view gets nothing from these; it
            // reads provisioned-org metadata through the stripped `get-config`.
            return "Corveil org provisioning is local-only"
        case "corveil-detect-gateways", "corveil-link-gateway":
            // Gateway migration (CROW-1126). `corveil-detect-gateways` reports
            // redacted key prefixes from the config's gateways and
            // `corveil-link-gateway` adopts an existing plaintext key into the
            // connection as an org's key — authoring a credential, like the
            // connection verbs above. Both are gated so the whole migration surface
            // stays part of the one local-only Corveil connection surface.
            return "Corveil gateway migration is local-only"
        case "set-config":
            guard setConfigTouchesPrivilegedFields(request, devRoot: devRoot) else { return nil }
            return "set-config binaries is local-only"
        case "defaults-set":
            // The only granular settings RPC that can reach `defaults.binaries`
            // — absolute local paths that execute at the next agent launch.
            // Gated on the *presence* of the param, not on a diff against disk
            // like `set-config` above.
            //
            // `set-config` needs the diff because it is a whole-blob replace:
            // every remote Settings save re-sends the binaries it just read
            // through `get-config`, and denying those would break the web
            // Settings tab (`setConfigUnchangedBinariesAndJobsIsAllowed`).
            // `defaults-set` is a PATCH — a caller that doesn't mean to touch
            // binaries omits the key — so there is no innocent echo to make room
            // for. A diff here would have to re-implement
            // `DefaultsRPC.mergeBinaries`' semantics (`"name": ""` deletes)
            // *inside a security predicate*, against a config read outside
            // `withConfigLock`. Two merge implementations, one of them the
            // boundary, is a strictly worse failure mode than denying a remote
            // no-op nobody sends.
            //
            // Deliberately `!= nil` on the raw `JSONValue` rather than
            // `?.objectValue`: key presence is then decided without the decoder's
            // cooperation, so a wrong-typed or null `binaries` is denied rather
            // than waved through to fail later in the handler.
            guard request.params?["binaries"] != nil else { return nil }
            return "defaults-set binaries is local-only"
        default:
            return nil
        }
    }

    /// True when the incoming `set-config` payload would change agent binary
    /// overrides relative to what's on disk. Scheduled `jobs` are no longer
    /// privileged — an authenticated remote session may edit them (CROW-665).
    static func setConfigTouchesPrivilegedFields(_ request: JSONRPCRequest, devRoot: String) -> Bool {
        guard let json = request.params?["config"]?.stringValue,
              let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            // Malformed — let the real handler return invalidParams.
            return false
        }
        let current = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
        return incoming.defaults.binaries != current.defaults.binaries
    }
}
