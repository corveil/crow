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
            // reader task) and hub notifications (fanned in via `subscribe`)
            // both feed the single writer below.
            let (outStream, outCont) = AsyncStream.makeStream(of: String.self)
            let subscription = await eventHub.subscribe(outCont)

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Writer — the sole owner of `outbound`.
                group.addTask {
                    for await text in outStream {
                        try await outbound.write(.text(text))
                    }
                }
                // Reader — decode requests, dispatch, enqueue responses.
                group.addTask {
                    let decoder = JSONDecoder()
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    for try await message in inbound.messages(maxSize: 1 << 20) {
                        let payload: Data?
                        switch message {
                        case .text(let text): payload = text.data(using: .utf8)
                        case .binary(let buffer): payload = Data(buffer.readableBytesView)
                        }
                        guard let data = payload,
                              let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
                            continue
                        }
                        let response: JSONRPCResponse
                        if !localDirect, let deny = Self.localOnlyDenial(for: request, devRoot: devRoot) {
                            response = .error(
                                id: request.id,
                                code: RPCErrorCode.invalidParams,
                                message: deny)
                        } else {
                            response = await commandRouter.handle(request: request)
                        }
                        if let out = try? encoder.encode(response), let text = String(data: out, encoding: .utf8) {
                            outCont.yield(text)
                        }
                    }
                    // Inbound closed → end the writer so the group can unwind.
                    outCont.finish()
                }

                // When either side finishes (socket closed), tear the other down.
                _ = try? await group.next()
                group.cancelAll()
            }

            await eventHub.unsubscribe(subscription)
        }
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
    /// The `telemetry-*` / `cleanup-*` / `ui-*` settings RPCs (CROW-814) are also
    /// NOT gated. An authenticated remote peer can already change every one of
    /// those fields through the un-gated `set-config` path — that is precisely what
    /// `setConfigHarmlessToggleIsAllowedRemotely` asserts — so gating the granular
    /// methods would only push remote callers back onto the whole-config blob,
    /// which puts workspaces, jobs, gateway URLs and credential shells on the wire
    /// instead of five scalars. Un-gating is the *smaller* surface, not merely the
    /// consistent one. None of them can reach `defaults.binaries`.
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
    /// Note this gate only guards the HTTP/WebSocket `/rpc` path. Every method here
    /// also has a `crow` CLI verb (CROW-818), and the CLI reaches the daemon over its
    /// 0600 Unix socket, which never passes through `localOnlyDenial` — a CLI caller
    /// is local by construction, so that is the intended trust model, not a bypass.
    static func localOnlyDenial(for request: JSONRPCRequest, devRoot: String) -> String? {
        switch request.method {
        case "run-setup":
            return "run-setup is local-only"
        case "open-in-vscode", "open-terminal":
            // These launch a GUI app on the daemon host (VS Code / Terminal at
            // the worktree path). Restrict to loopback callers — a remote web
            // session must not spawn host processes (CROW-749).
            return "opening host apps is local-only"
        case "gateway-get", "gateway-set", "web-password-get", "web-password-set":
            // Secret reads *and* writes (CROW-815) — see the doc comment above.
            return "gateway and web-password management is local-only"
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
