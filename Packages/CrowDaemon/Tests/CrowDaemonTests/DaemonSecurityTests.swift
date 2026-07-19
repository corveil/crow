import Dispatch
import Foundation
import HTTPTypes
import Testing
import NIOCore
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// Locks down the security-sensitive guards flagged in the CROW-581 review:
/// the WebSocket `Origin` allowlist (cross-site hijacking defense), the
/// non-loopback bind detection, and the static-asset path-traversal guard.
@Suite struct WebSocketOriginGuardTests {
    @Test func allowsAbsentOrigin() {
        // Native (non-browser) clients — the CLI, websocat, test harnesses —
        // send no Origin and must be allowed.
        #expect(WebSocketOriginGuard.isAllowedOrigin(nil))
        #expect(WebSocketOriginGuard.isAllowedOrigin(""))
    }

    @Test func allowsLoopbackOrigins() {
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://127.0.0.1:8787"))
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://localhost:8787"))
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://[::1]:8787"))
        #expect(WebSocketOriginGuard.isAllowedOrigin("https://LOCALHOST"))
    }

    @Test func rejectsCrossSiteOrigins() {
        #expect(!WebSocketOriginGuard.isAllowedOrigin("https://evil.com"))
        #expect(!WebSocketOriginGuard.isAllowedOrigin("http://192.168.1.5:8787"))
        #expect(!WebSocketOriginGuard.isAllowedOrigin("http://127.0.0.1.evil.com"))
        #expect(!WebSocketOriginGuard.isAllowedOrigin("null"))
    }

    @Test func loopbackHostDetection() {
        #expect(WebSocketOriginGuard.isLoopbackHost("127.0.0.1"))
        #expect(WebSocketOriginGuard.isLoopbackHost("localhost"))
        #expect(WebSocketOriginGuard.isLoopbackHost("::1"))
        #expect(!WebSocketOriginGuard.isLoopbackHost("0.0.0.0"))
        #expect(!WebSocketOriginGuard.isLoopbackHost("192.168.1.5"))
    }

    @Test func trustsOwnBindHostButNotOthers() {
        // A specific non-loopback bind may serve its own web UI…
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://100.64.0.5:8787", boundHost: "100.64.0.5"))
        // …but cross-site origins are still rejected under that bind.
        #expect(!WebSocketOriginGuard.isAllowedOrigin("https://evil.com", boundHost: "100.64.0.5"))
        #expect(!WebSocketOriginGuard.isAllowedOrigin("http://192.168.1.9:8787", boundHost: "100.64.0.5"))
    }

    @Test func wildcardBindTrustsPrivateOriginsOnly() {
        // 0.0.0.0 is reachable via any local interface: trust LAN/tailnet…
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://192.168.1.190:8787", boundHost: "0.0.0.0"))
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://10.1.2.3:8787", boundHost: "0.0.0.0"))
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://100.100.5.9:8787", boundHost: "0.0.0.0"))
        #expect(WebSocketOriginGuard.isAllowedOrigin("http://127.0.0.1:8787", boundHost: "0.0.0.0"))
        // …but reject public origins even on a wildcard bind.
        #expect(!WebSocketOriginGuard.isAllowedOrigin("https://evil.com", boundHost: "0.0.0.0"))
        #expect(!WebSocketOriginGuard.isAllowedOrigin("http://8.8.8.8", boundHost: "0.0.0.0"))
    }

    @Test func privateHostClassification() {
        for host in ["10.0.0.1", "192.168.1.190", "172.16.0.9", "172.31.255.1", "169.254.1.1", "100.64.0.1", "127.0.0.1"] {
            #expect(WebSocketOriginGuard.isPrivateHost(host), "\(host) should be private")
        }
        for host in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "100.128.0.1", "evil.com", "203.0.113.5"] {
            #expect(!WebSocketOriginGuard.isPrivateHost(host), "\(host) should be public")
        }
    }

    @Test func trustsProxiedForwardedHostFromLoopbackPeer() {
        // `tailscale serve` / ngrok: the browser's Origin is the proxy's public
        // MagicDNS hostname (never an IP literal), and the proxy — a loopback peer
        // — reports the host it served via `X-Forwarded-Host`. A same-origin
        // upgrade (Origin host == forwarded host) is allowed even on a wildcard
        // bind (CROW-593).
        #expect(WebSocketOriginGuard.isAllowedOrigin(
            "https://macbook-pro.fin-halfbeak.ts.net", boundHost: "0.0.0.0",
            forwardedHost: "macbook-pro.fin-halfbeak.ts.net", peerIsLoopback: true))
        // A forwarded host carrying the standard :443 still matches the Origin host.
        #expect(WebSocketOriginGuard.isAllowedOrigin(
            "https://app.example.ts.net", boundHost: "127.0.0.1",
            forwardedHost: "app.example.ts.net:443", peerIsLoopback: true))
        // A trailing FQDN dot on either side normalizes away before comparison.
        #expect(WebSocketOriginGuard.isAllowedOrigin(
            "https://host.example.ts.net", boundHost: "0.0.0.0",
            forwardedHost: "host.example.ts.net.", peerIsLoopback: true))
    }

    @Test func rejectsProxiedOriginMismatchOrUntrustedPeer() {
        // Cross-site page routed through the proxy: Origin != forwarded host → rejected.
        #expect(!WebSocketOriginGuard.isAllowedOrigin(
            "https://evil.com", boundHost: "0.0.0.0",
            forwardedHost: "macbook-pro.fin-halfbeak.ts.net", peerIsLoopback: true))
        // A non-loopback peer's `X-Forwarded-Host` is untrusted (it isn't the local
        // proxy) — a direct tailnet/LAN client can't forge same-origin this way.
        #expect(!WebSocketOriginGuard.isAllowedOrigin(
            "https://macbook-pro.fin-halfbeak.ts.net", boundHost: "0.0.0.0",
            forwardedHost: "macbook-pro.fin-halfbeak.ts.net", peerIsLoopback: false))
    }
}

@Suite struct StaticAssetGuardTests {
    @Test func acceptsPlainBasenames() {
        #expect(StaticAssets.isSafeAssetName("xterm.js"))
        #expect(StaticAssets.isSafeAssetName("xterm-addon-fit.js"))
    }

    @Test func rejectsTraversalAndSeparators() {
        #expect(!StaticAssets.isSafeAssetName(""))
        #expect(!StaticAssets.isSafeAssetName(".."))
        #expect(!StaticAssets.isSafeAssetName("../Package.swift"))
        #expect(!StaticAssets.isSafeAssetName("a/b"))
        #expect(!StaticAssets.isSafeAssetName("/etc/passwd"))
    }
}

@Suite struct DaemonOptionsTests {
    @Test func parsesAllFlags() {
        let options = DaemonOptions.parse([
            "crowd", "--http-port", "9001", "--host", "0.0.0.0",
            "--socket", "/tmp/crowd.sock", "--dev-root", "/tmp/dev",
        ])
        #expect(options.httpPort == 9001)
        #expect(options.host == "0.0.0.0")
        #expect(options.socketPath == "/tmp/crowd.sock")
        #expect(options.devRoot == "/tmp/dev")
    }

    @Test func malformedPortKeepsDefault() {
        let options = DaemonOptions.parse(["crowd", "--http-port", "not-a-number"])
        #expect(options.httpPort == 8787)
    }

    @Test func defaultsAreLoopback() {
        let options = DaemonOptions.parse(["crowd"])
        #expect(options.host == "127.0.0.1")
        #expect(WebSocketOriginGuard.isLoopbackHost(options.host))
    }
}

@Suite struct TerminalConnectionLimiterTests {
    @Test func boundsConcurrentAcquires() {
        let limiter = TerminalConnectionLimiter(max: 2)
        #expect(limiter.acquire())
        #expect(limiter.acquire())
        #expect(!limiter.acquire())  // ceiling reached
        limiter.release()
        #expect(limiter.acquire())   // slot freed
    }
}

/// In the client-default world (F cutover) the desktop app no longer binds
/// `crow.sock`, so the daemon owns it: its default IS the app's well-known
/// socket, and every existing `crow` CLI consumer reaches `crowd` unchanged. The
/// bind guard (a live connect probe) still refuses to steal a *running* legacy
/// app's socket; run an isolated daemon via an explicit `--socket` (CROW-581).
@Suite struct DaemonSocketDefaultTests {
    @Test func daemonDefaultIsTheWellKnownAppSocket() {
        let daemonSock = DaemonOptions.defaultDaemonSocketPath()
        #expect(daemonSock == SocketServer.defaultSocketPath())
        #expect(daemonSock.hasSuffix("crow.sock"))
        #expect(DaemonOptions.parse(["crowd"]).socketPath == daemonSock)
    }
}

/// One `crowd` per socket: the flock guard makes a duplicate daemon on the same
/// socket exit instead of half-starting (skipping the unix bind) and orphaning
/// `crow.sock` when the first dies — the multi-`crowd-dev` footgun (CROW-581).
@Suite struct SingleInstanceLockTests {
    private func tmpSocket() -> String {
        NSTemporaryDirectory() + "crowd-lock-\(UUID().uuidString).sock"
    }

    @Test func secondAcquireOnSameSocketIsRefused() {
        let sock = tmpSocket()
        defer { try? FileManager.default.removeItem(atPath: sock + ".lock") }
        #expect(CrowDaemon.acquireSingleInstanceLock(socketPath: sock) == true)   // first wins
        #expect(CrowDaemon.acquireSingleInstanceLock(socketPath: sock) == false)  // duplicate refused
    }

    @Test func distinctSocketsGetDistinctLocks() {
        let a = tmpSocket(), b = tmpSocket()
        defer {
            try? FileManager.default.removeItem(atPath: a + ".lock")
            try? FileManager.default.removeItem(atPath: b + ".lock")
        }
        #expect(CrowDaemon.acquireSingleInstanceLock(socketPath: a) == true)
        #expect(CrowDaemon.acquireSingleInstanceLock(socketPath: b) == true)   // isolated daemon coexists
    }
}

/// One writer of `store.json`, regardless of `--socket` (#759). The socket lock
/// above is keyed to the socket path, but the store lives at a fixed app-support
/// location — so a distinct `--socket` alone does NOT isolate the store. This
/// store-scoped flock rejects a second acquirer for the same store directory,
/// while two daemons pointed at genuinely separate store directories coexist.
@Suite struct StoreWriterLockTests {
    private func tmpStoreDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func secondAcquireForSameStoreDirIsRefused() {
        let dir = tmpStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // First writer wins; a second one — even launched with a *distinct*
        // --socket — is refused because it targets the same store directory.
        #expect(CrowDaemon.acquireStoreWriterLock(storeDirectory: dir) == true)
        #expect(CrowDaemon.acquireStoreWriterLock(storeDirectory: dir) == false)
    }

    @Test func separateStoreDirsCoexist() {
        let a = tmpStoreDir(), b = tmpStoreDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(CrowDaemon.acquireStoreWriterLock(storeDirectory: a) == true)
        #expect(CrowDaemon.acquireStoreWriterLock(storeDirectory: b) == true)   // genuinely separate stores still coexist
    }
}

/// add-worktree input hardening (CROW-581 review): option-injection and orphan
/// rows. Both checks run before any git/fs work, so no tmux/app is needed.
@Suite struct AddWorktreeValidationTests {
    @MainActor
    private func router() -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)
    }

    private func addWorktree(_ router: CommandRouter, branch: String, session: UUID) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(id: 1, method: "add-worktree", params: [
            "session_id": .string(session.uuidString),
            "repo": .string("acme"),
            "path": .string(NSTemporaryDirectory() + "wt"),
            "branch": .string(branch),
        ]))
    }

    @Test @MainActor func rejectsLeadingDashBranch() async {
        let resp = await addWorktree(router(), branch: "--upload-pack=evil", session: UUID())
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }

    @Test @MainActor func rejectsUnknownSession() async {
        let resp = await addWorktree(router(), branch: "feature/x", session: UUID())
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }
}

/// Config-derived AppState sync (CROW-581): the desktop app copies these fields
/// out of config in `AppDelegate`, but headless crowd omitted them — so the
/// ticket board ignored `defaults.excludeTicketRepos`, and the auto-permission /
/// remote-control gates never reflected config. `applyConfigToAppState` restores
/// that sync; these lock in that every field lands and the board actually filters.
@Suite struct ConfigAppStateSyncTests {
    private func tmpDevRoot() -> String {
        let p = NSTemporaryDirectory() + "crow-cfg-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @Test @MainActor func appliesExcludeReposAndPermissionGatesFromConfig() throws {
        let devRoot = tmpDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // Every value deliberately differs from the AppState default so a passing
        // assertion proves the field was copied, not left at its zero-value.
        let cfg = AppConfig(
            defaults: ConfigDefaults(
                excludeReviewRepos: ["acme/reviewskip"],
                excludeTicketRepos: ["acme/legacy", "owner/*"],
                ignoreReviewLabels: ["wip"]),
            remoteControlEnabled: true,          // AppState default: false
            managerAutoPermissionMode: false,    // AppState default: true
            jobsAutoPermissionMode: false,       // AppState default: true
            coderViewAutoPermissionMode: true,   // AppState default: false
            defaultAgentKind: .cursor,           // AppState default: .claudeCode
            agentsByKind: ["job": .codex])       // AppState default: [:]
        try ConfigStore.saveConfig(cfg, devRoot: devRoot)

        let appState = AppState()
        CrowDaemon.applyConfigToAppState(appState, devRoot: devRoot)

        #expect(appState.excludeTicketRepos == ["acme/legacy", "owner/*"])
        #expect(appState.excludeReviewRepos == ["acme/reviewskip"])
        #expect(appState.ignoreReviewLabels == ["wip"])
        #expect(appState.remoteControlEnabled == true)
        #expect(appState.managerAutoPermissionMode == false)
        #expect(appState.jobsAutoPermissionMode == false)
        #expect(appState.coderViewAutoPermissionMode == true)
        // Agent selection must land too, via the `applyAgentConfig` choke point
        // wired into `applyConfigToAppState`. This is the guard for CROW-733: a
        // launched job resolves its agent live through `agentKind(for: .job)`, so
        // deleting that daemon call site reintroduces the stale-agent bug — and
        // only this disk→config→state assertion (not the direct-setter unit tests)
        // fails when it is removed.
        #expect(appState.defaultAgentKind == .cursor)
        #expect(appState.agentsByKind == ["job": .codex])
        #expect(appState.agentKind(for: .job) == .codex)

        // The board the daemon serializes is `filteredAssignedIssues`; with the
        // field populated it now drops the excluded repos (exact + glob) — the
        // user-visible regression where tickets ignored ignored repos.
        appState.assignedIssues = [
            AssignedIssue(id: "1", number: 1, title: "keep", state: "open",
                          url: "https://x/1", repo: "acme/app", provider: .github),
            AssignedIssue(id: "2", number: 2, title: "drop-exact", state: "open",
                          url: "https://x/2", repo: "acme/legacy", provider: .github),
            AssignedIssue(id: "3", number: 3, title: "drop-glob", state: "open",
                          url: "https://x/3", repo: "owner/anything", provider: .github),
        ]
        #expect(appState.filteredAssignedIssues.map(\.repo) == ["acme/app"])
    }

    @Test @MainActor func missingConfigLeavesDefaultsUntouched() {
        // No config.json → the guard returns early; AppState keeps its defaults
        // rather than being clobbered to empty/false.
        let appState = AppState()
        CrowDaemon.applyConfigToAppState(
            appState, devRoot: NSTemporaryDirectory() + "no-such-\(UUID().uuidString)")
        #expect(appState.excludeTicketRepos.isEmpty)
        #expect(appState.managerAutoPermissionMode == true)
    }
}

// MARK: - Web-access auth (CROW-593)

/// PBKDF2 password hashing: correct/incorrect verify, a fresh random salt per
/// call, and rejection of malformed stored records.
@Suite struct PasswordHashTests {
    @Test func verifiesCorrectRejectsWrong() {
        // Low iterations keep the test fast; the KDF path is identical.
        let rec = PasswordHash.make(password: "correct horse", iterations: 2000)
        #expect(PasswordHash.verify(password: "correct horse", record: rec))
        #expect(!PasswordHash.verify(password: "Correct horse", record: rec))
        #expect(!PasswordHash.verify(password: "", record: rec))
    }

    @Test func distinctSaltsPerHash() {
        let a = PasswordHash.make(password: "same", iterations: 2000)
        let b = PasswordHash.make(password: "same", iterations: 2000)
        #expect(a.saltB64 != b.saltB64)   // fresh random salt each call…
        #expect(a.hashB64 != b.hashB64)   // …so the derived key differs too
    }

    @Test func rejectsMalformedRecord() {
        #expect(!PasswordHash.verify(password: "x",
            record: WebAuthConfig(hashB64: "", saltB64: "", iterations: 0)))
        #expect(!PasswordHash.verify(password: "x",
            record: WebAuthConfig(hashB64: "!!notbase64!!", saltB64: "!!", iterations: 1000)))
    }

    @Test func constantTimeEqualBasics() {
        #expect(PasswordHash.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        #expect(!PasswordHash.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        #expect(!PasswordHash.constantTimeEqual([1, 2], [1, 2, 3]))   // length mismatch
    }
}

@Suite struct SessionStoreTests {
    @Test func issueValidateRevoke() {
        let store = SessionStore()
        let token = store.issue()
        #expect(store.isValid(token))
        #expect(!store.isValid("deadbeef"))   // never issued
        #expect(!store.isValid(nil))
        store.revoke(token)
        #expect(!store.isValid(token))         // revoked → gone
    }

    @Test func expiredTokenIsInvalid() {
        let store = SessionStore(ttl: -1)      // expires the instant it's issued
        #expect(!store.isValid(store.issue()))
    }
}

@Suite struct LoginRateLimiterTests {
    @Test func throttlesBurstThenRecovers() {
        let limiter = LoginRateLimiter(max: 3, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(limiter.allow(now: t0))
        #expect(limiter.allow(now: t0))
        #expect(limiter.allow(now: t0))
        #expect(!limiter.allow(now: t0))                        // ceiling hit
        #expect(limiter.allow(now: t0.addingTimeInterval(61)))  // window slid past
    }
}

/// The per-request/-upgrade authorize() matrix — the crux of the model: local is
/// always trusted, the gate is inert until a password is set, and once set only a
/// loopback https proxy with a valid session gets in.
@Suite struct WebAuthGuardTests {
    private func peer(_ ip: String) -> SocketAddress? { try? SocketAddress(ipAddress: ip, port: 8787) }
    private func withPassword() -> AppConfig {
        var c = AppConfig()
        c.webAuth = WebAuthConfig(hashB64: "nonempty", saltB64: "s", iterations: 210_000)
        return c
    }

    @Test func localLoopbackNoProxyIsTrusted() {
        // Returns before the config is consulted — hence configProvider = { nil }.
        let d = WebAuthGuard.authorize(
            remoteAddress: peer("127.0.0.1"), cookieHeader: nil, forwardedFor: nil, forwardedProto: nil,
            configProvider: { nil }, sessions: SessionStore())
        #expect(d.isAuthorized)
        #expect(d.reason == "local")
    }

    @Test func noPasswordIsInertForRemote() {
        // Opt-in: with no password configured a proxied peer is still allowed.
        let d = WebAuthGuard.authorize(
            remoteAddress: peer("127.0.0.1"), cookieHeader: nil, forwardedFor: "1.2.3.4", forwardedProto: "https",
            configProvider: { AppConfig() }, sessions: SessionStore())
        #expect(d.isAuthorized)
    }

    @Test func nonLoopbackDeniedOncePasswordSet() {
        // A direct LAN peer must go through the proxy; denied regardless of headers.
        let d = WebAuthGuard.authorize(
            remoteAddress: peer("100.64.0.5"), cookieHeader: nil, forwardedFor: nil, forwardedProto: nil,
            configProvider: { withPassword() }, sessions: SessionStore())
        #expect(!d.isAuthorized)
    }

    @Test func proxiedHttpsWithValidSessionIsAuthorized() {
        let sessions = SessionStore()
        let token = sessions.issue()
        let d = WebAuthGuard.authorize(
            remoteAddress: peer("127.0.0.1"), cookieHeader: "crow_session=\(token)",
            forwardedFor: "9.9.9.9", forwardedProto: "https",
            configProvider: { withPassword() }, sessions: sessions)
        #expect(d.isAuthorized)
        #expect(d.reason == "valid session")
    }

    @Test func proxiedButNotHttpsIsDenied() {
        let d = WebAuthGuard.authorize(
            remoteAddress: peer("127.0.0.1"), cookieHeader: nil,
            forwardedFor: "9.9.9.9", forwardedProto: "http",
            configProvider: { withPassword() }, sessions: SessionStore())
        #expect(!d.isAuthorized)
    }

    @Test func proxiedHttpsWithoutValidSessionIsDenied() {
        let d = WebAuthGuard.authorize(
            remoteAddress: peer("127.0.0.1"), cookieHeader: "crow_session=bogus",
            forwardedFor: "9.9.9.9", forwardedProto: "https",
            configProvider: { withPassword() }, sessions: SessionStore())
        #expect(!d.isAuthorized)
    }

    @Test func loopbackPeerDetection() {
        #expect(WebAuthGuard.isLoopbackPeer(peer("127.0.0.1")))
        #expect(WebAuthGuard.isLoopbackPeer(peer("::1")))
        #expect(!WebAuthGuard.isLoopbackPeer(peer("192.168.1.9")))
        #expect(!WebAuthGuard.isLoopbackPeer(nil))
    }

    @Test func localDirectRequiresLoopbackAndNoProxyHeader() {
        // Loopback peer, no X-Forwarded-For → local-direct (may manage secrets).
        #expect(WebAuthGuard.isLocalDirect(remoteAddress: peer("127.0.0.1"), forwardedFor: nil))
        #expect(WebAuthGuard.isLocalDirect(remoteAddress: peer("::1"), forwardedFor: ""))
        #expect(WebAuthGuard.isLocalDirect(remoteAddress: peer("127.0.0.1"), forwardedFor: "   "))
        // Loopback peer WITH X-Forwarded-For → a local reverse proxy forwarding a
        // remote user; NOT local-direct, so the remote user can't manage secrets.
        #expect(!WebAuthGuard.isLocalDirect(remoteAddress: peer("127.0.0.1"), forwardedFor: "203.0.113.7"))
        // Non-loopback / unknown peer → never local-direct.
        #expect(!WebAuthGuard.isLocalDirect(remoteAddress: peer("192.168.1.9"), forwardedFor: nil))
        #expect(!WebAuthGuard.isLocalDirect(remoteAddress: nil, forwardedFor: nil))
    }

    @Test func cookieParsing() {
        #expect(WebAuthGuard.sessionToken(fromCookie: "a=1; crow_session=abc; b=2") == "abc")
        #expect(WebAuthGuard.sessionToken(fromCookie: "other=x") == nil)
        #expect(WebAuthGuard.sessionToken(fromCookie: nil) == nil)
    }
}

/// `SecretRoutes.buildGateway` enforces `WorkspaceGateway`'s both-or-neither
/// invariant (a base URL and at least one header, or neither) and treats an
/// empty or `clear` body as "no gateway" (CROW-593).
@Suite struct SecretGatewayValidationTests {
    private func body(_ url: String?, _ headers: [String: String]?, clear: Bool? = nil) -> SecretRoutes.GatewayBody {
        SecretRoutes.GatewayBody(baseURL: url, headers: headers, clear: clear)
    }

    @Test func bothPresentBuildsGateway() throws {
        let g = try SecretRoutes.buildGateway(body("https://gw.example", ["X-Api-Key": "k"])).get()
        #expect(g?.baseURL == "https://gw.example")
        #expect(g?.customHeaders["X-Api-Key"] == "k")
    }

    @Test func emptyOrClearMeansNoGateway() throws {
        #expect(try SecretRoutes.buildGateway(body("", [:])).get() == nil)
        #expect(try SecretRoutes.buildGateway(nil).get() == nil)
        // clear wins even when fields are present.
        #expect(try SecretRoutes.buildGateway(body("https://gw", ["X": "y"], clear: true)).get() == nil)
    }

    @Test func halfFilledIsRejected() {
        if case .success = SecretRoutes.buildGateway(body("https://gw", [:])) {
            Issue.record("baseURL with no headers should be rejected")
        }
        if case .success = SecretRoutes.buildGateway(body("", ["X": "y"])) {
            Issue.record("headers with no baseURL should be rejected")
        }
    }

    @Test func blankHeaderValuesKeepStoredSecrets() throws {
        // Local editor prefills stripped keys with empty values; updating only
        // the base URL must not wipe the stored auth header (review Yellow #1).
        let stored = WorkspaceGateway(
            baseURL: "https://old.example",
            customHeaders: ["X-Api-Key": "SECRET", "X-Extra": "keep-me"])
        let incoming = WorkspaceGateway(
            baseURL: "https://new.example",
            customHeaders: ["X-Api-Key": "", "X-Extra": "", "X-New": "fresh"])
        let merged = try SecretRoutes.mergingPreservedHeaders(incoming: incoming, stored: stored).get()
        #expect(merged?.baseURL == "https://new.example")
        #expect(merged?.customHeaders["X-Api-Key"] == "SECRET")
        #expect(merged?.customHeaders["X-Extra"] == "keep-me")
        #expect(merged?.customHeaders["X-New"] == "fresh")
    }

    @Test func blankHeaderWithNoStoredValueIsDroppedWhenSiblingRemains() throws {
        let incoming = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["X-Api-Key": "real", "X-Empty": ""])
        let merged = try SecretRoutes.mergingPreservedHeaders(incoming: incoming, stored: nil).get()
        #expect(merged?.customHeaders["X-Api-Key"] == "real")
        #expect(merged?.customHeaders["X-Empty"] == nil)
    }

    @Test func allBlankHeadersWithNoStoredSecretAreRejected() {
        // URL + only blank headers (no stored secret to restore) would encode a
        // half-filled gateway that AppConfig refuses to decode — wiping the
        // whole config on the next load (review Red on #623).
        let incoming = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["X-Api-Key": ""])
        if case .success = SecretRoutes.mergingPreservedHeaders(incoming: incoming, stored: nil) {
            Issue.record("URL with no keepable headers must be rejected")
        }
    }

    @Test func renamedBlankHeaderWithNoStoredMatchIsRejected() {
        // Renaming the only header key to a blank-valued new name leaves no
        // keepable headers after merge — same undecodable shape as above.
        let stored = WorkspaceGateway(
            baseURL: "https://gw.example", customHeaders: ["X-Old": "SECRET"])
        let incoming = WorkspaceGateway(
            baseURL: "https://gw.example", customHeaders: ["X-New": ""])
        if case .success = SecretRoutes.mergingPreservedHeaders(incoming: incoming, stored: stored) {
            Issue.record("renamed blank header with no stored match must be rejected")
        }
    }

    @Test func nilIncomingClearsGateway() throws {
        let stored = WorkspaceGateway(baseURL: "https://gw", customHeaders: ["X": "y"])
        #expect(try SecretRoutes.mergingPreservedHeaders(incoming: nil, stored: stored).get() == nil)
    }

    @Test func nonBlankIncomingValueOverridesStored() throws {
        let stored = WorkspaceGateway(
            baseURL: "https://gw", customHeaders: ["X-Api-Key": "OLD"])
        let incoming = WorkspaceGateway(
            baseURL: "https://gw", customHeaders: ["X-Api-Key": "NEW"])
        let merged = try SecretRoutes.mergingPreservedHeaders(incoming: incoming, stored: stored).get()
        #expect(merged?.customHeaders["X-Api-Key"] == "NEW")
    }
}

/// `CrowDaemon.resolvedExecutablePath` must return an absolute path to *this*
/// process so `reexec` can `execv` after a PATH-launched `crowd` (review Yellow #2).
@Suite struct ReexecPathResolutionTests {
    @Test func resolvedExecutablePathIsAbsoluteAndExists() {
        let path = CrowDaemon.resolvedExecutablePath()
        #expect(path != nil)
        guard let path else { return }
        #expect(path.hasPrefix("/"), "expected absolute path, got \(path)")
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }
}

/// The `webAuth` hash/salt are secrets: blanked on transport (the browser only
/// learns "set or not") and restored across a `set-config` that omits them, so a
/// settings save never wipes the password.
@Suite struct WebAuthSecretStrippingTests {
    @Test func stripsHashAndSaltButKeepsPresence() {
        var cfg = AppConfig()
        cfg.webAuth = WebAuthConfig(hashB64: "SECRET_HASH", saltB64: "SECRET_SALT", iterations: 210_000)
        let stripped = SettingsSecrets.strippedForTransport(cfg)
        #expect(stripped.webAuth != nil)          // presence preserved → UI shows "set"
        #expect(stripped.webAuth?.hashB64 == "")
        #expect(stripped.webAuth?.saltB64 == "")
    }

    @Test func preservesSecretsAcrossBlankedRoundTrip() {
        var current = AppConfig()
        current.webAuth = WebAuthConfig(hashB64: "REAL_HASH", saltB64: "REAL_SALT", iterations: 210_000)
        let incoming = SettingsSecrets.strippedForTransport(current)   // what the browser sends back
        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
        #expect(merged.webAuth?.hashB64 == "REAL_HASH")
        #expect(merged.webAuth?.saltB64 == "REAL_SALT")
    }
}

// MARK: - Security surface re-homed from the retired root suite (CROW-607)

/// `WebAuthMiddleware` is the HTTP-side gate: it exempts the login/health/brand
/// endpoints and runs every other path — crucially `/auth/check`, the web UI's
/// session-validity probe — through `WebAuthGuard.authorize` (exhaustively
/// covered in `WebAuthGuardTests`). These lock in the wrapper decisions: the
/// exempt allowlist and the unauthorized-response selector (login page vs 401).
@Suite struct WebAuthMiddlewareGatingTests {
    private typealias MW = WebAuthMiddleware<CrowHTTPContext>

    @Test func exemptsOnlyLoginLogoutHealthAndBrand() {
        for path in ["/login", "/logout", "/health", "/brand.svg"] {
            #expect(MW.isAuthExempt(path: path), "\(path) must bypass the auth gate")
        }
    }

    @Test func authCheckAndAppRoutesAreGated() {
        // `/auth/check` is NOT exempt — it flows through `authorize`, so an
        // unauthenticated remote peer gets 401 rather than a blanket 204. That
        // routing is the whole point of the probe (CROW-593).
        #expect(!MW.isAuthExempt(path: "/auth/check"))
        for path in ["/", "/index.html", "/app.js", "/rpc",
                     "/config/web-password", "/config/manager-gateway"] {
            #expect(!MW.isAuthExempt(path: path), "\(path) must be gated")
        }
    }

    @Test func servesLoginPageOnlyForNavigationalGET() {
        // A browser navigation (GET + Accept: text/html) → the login page (200)…
        #expect(MW.serveLoginPageForUnauthorized(method: .get, accept: "text/html"))
        #expect(MW.serveLoginPageForUnauthorized(method: .get, accept: "text/html,application/xhtml+xml"))
        // …but an XHR/fetch GET, a non-GET, or a missing Accept → a bare 401.
        #expect(!MW.serveLoginPageForUnauthorized(method: .get, accept: "application/json"))
        #expect(!MW.serveLoginPageForUnauthorized(method: .get, accept: nil))
        #expect(!MW.serveLoginPageForUnauthorized(method: .post, accept: "text/html"))
    }
}

/// The Content-Security-Policy is attached to the provider-data-rendering app
/// page only, and carries the hardening directives that make a future
/// innerHTML slip non-exploitable (no external/inline script, no exfiltration)
/// (CROW-593 review).
@Suite struct ContentSecurityPolicyTests {
    @Test func appliesToIndexOnly() {
        #expect(StaticAssets.appliesCSP(to: "index.html"))
        // login.html has an inline script; terminal.html is a debug page; the
        // static assets don't render provider data — none carry the CSP.
        for name in ["login.html", "terminal.html", "app.js", "app.css", "settings.js", "brand.svg"] {
            #expect(!StaticAssets.appliesCSP(to: name), "\(name) must not carry the CSP")
        }
    }

    @Test func policyCarriesHardeningDirectives() {
        let csp = StaticAssets.contentSecurityPolicy
        for directive in [
            "default-src 'self'",
            "script-src 'self' 'wasm-unsafe-eval'",   // xterm's Sixel wasm, no arbitrary eval
            "connect-src 'self'",                      // same-origin /rpc + /terminal WS only
            "object-src 'none'",
            "base-uri 'none'",
            "frame-ancestors 'none'",                  // no clickjacking
        ] {
            #expect(csp.contains(directive), "CSP missing: \(directive)")
        }
        // No wildcard host or inline-script escape hatch slipped in.
        #expect(!csp.contains("script-src 'self' 'unsafe-inline'"))
        #expect(!csp.contains("*"))
    }
}

/// `ConfigStore.withConfigLock` serializes the load → mutate → save of
/// `config.json` so concurrent writers (set-config / set-web-password /
/// gateway saves / onJobRan) can't clobber each other's just-loaded copy
/// (CROW-593 review #10).
@Suite struct ConfigLockConcurrencyTests {
    /// A shared, deliberately non-atomic read-modify-write under the lock: if the
    /// lock didn't serialize, concurrent increments would lose updates.
    @Test func serializesConcurrentCriticalSections() {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let iterations = 2_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            ConfigStore.withConfigLock {
                let current = counter.value    // RMW window — lossy without the lock
                counter.value = current + 1
            }
        }
        #expect(counter.value == iterations)
    }

    /// The real use-case: concurrent load-modify-save against one config.json.
    /// Every writer's append must survive — the final file has all N entries.
    @Test func concurrentLoadModifySaveLosesNoUpdates() throws {
        let devRoot = NSTemporaryDirectory() + "crow-configlock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(), devRoot: devRoot)

        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            ConfigStore.withConfigLock {
                var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                c.defaults.excludeTicketRepos.append("repo-\(i)")
                try? ConfigStore.saveConfig(c, devRoot: devRoot)
            }
        }

        let final = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(final.defaults.excludeTicketRepos.count == iterations)
        #expect(Set(final.defaults.excludeTicketRepos).count == iterations)   // all distinct, none lost
    }
}

/// Local-direct gates on `/rpc` for write+exec surfaces (review Yellow on #594).
@Suite struct LocalOnlyRPCGateTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-local-rpc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func encode(_ config: AppConfig) throws -> String {
        String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    }

    @Test func runSetupAlwaysDeniedWhenNotLocal() {
        let req = JSONRPCRequest(id: 1, method: "run-setup", params: [
            "dev_root": .string("/tmp/x"),
            "config": .string("{}"),
        ])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: req, devRoot: tempDevRoot())
            == "run-setup is local-only")
    }

    @Test func openHostAppsAreLocalOnly() {
        // The host-launch RPCs spawn a GUI app (`code` / `/usr/bin/open`) on the
        // daemon host — a remote `/rpc` peer must never reach them (CROW-749).
        for method in ["open-in-vscode", "open-terminal"] {
            let req = JSONRPCRequest(id: 1, method: method, params: [
                "session_id": .string(UUID().uuidString),
            ])
            #expect(RPCWebSocketHandler.localOnlyDenial(for: req, devRoot: tempDevRoot())
                == "opening host apps is local-only")
        }
    }

    @Test func setConfigBinariesChangeIsLocalOnly() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(), devRoot: devRoot)

        var incoming = AppConfig()
        incoming.defaults.binaries = ["claude": "/evil/claude"]
        let req = JSONRPCRequest(id: 1, method: "set-config", params: [
            "config": .string(try encode(incoming)),
        ])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: req, devRoot: devRoot)
            == "set-config binaries is local-only")
        #expect(RPCWebSocketHandler.setConfigTouchesPrivilegedFields(req, devRoot: devRoot))
    }

    @Test func setConfigJobsChangeIsAllowedRemotely() throws {
        // Jobs are no longer a local-only surface (CROW-665): an authenticated
        // remote session may edit them, so a jobs-only change must NOT trip the
        // gate. `defaults.binaries` remains local-only (see the test above).
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(), devRoot: devRoot)

        var incoming = AppConfig()
        incoming.jobs = [
            JobConfig(name: "nightly", workspace: "ws", repo: "o/r",
                      prompts: ["do stuff"], schedule: .interval(seconds: 3600)),
        ]
        let req = JSONRPCRequest(id: 1, method: "set-config", params: [
            "config": .string(try encode(incoming)),
        ])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: req, devRoot: devRoot) == nil)
        #expect(!RPCWebSocketHandler.setConfigTouchesPrivilegedFields(req, devRoot: devRoot))
    }

    @Test func setConfigHarmlessToggleIsAllowedRemotely() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var stored = AppConfig()
        stored.remoteControlEnabled = true
        try ConfigStore.saveConfig(stored, devRoot: devRoot)

        var incoming = AppConfig()
        incoming.remoteControlEnabled = false
        let req = JSONRPCRequest(id: 1, method: "set-config", params: [
            "config": .string(try encode(incoming)),
        ])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: req, devRoot: devRoot) == nil)
        #expect(!RPCWebSocketHandler.setConfigTouchesPrivilegedFields(req, devRoot: devRoot))
    }

    @Test func setConfigUnchangedBinariesAndJobsIsAllowed() throws {
        // Remote editor round-trips the same binaries/jobs it just read — must
        // not trip the gate (only *changes* are local-only).
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var stored = AppConfig()
        stored.defaults.binaries = ["claude": "/usr/local/bin/claude"]
        stored.jobs = [
            JobConfig(name: "nightly", workspace: "ws", repo: "o/r",
                      prompts: ["do stuff"], schedule: .interval(seconds: 3600)),
        ]
        try ConfigStore.saveConfig(stored, devRoot: devRoot)

        let req = JSONRPCRequest(id: 1, method: "set-config", params: [
            "config": .string(try encode(stored)),
        ])
        #expect(RPCWebSocketHandler.localOnlyDenial(for: req, devRoot: devRoot) == nil)
    }
}

