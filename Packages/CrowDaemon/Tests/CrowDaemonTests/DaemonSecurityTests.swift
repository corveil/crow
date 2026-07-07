import Foundation
import Testing
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

/// add-worktree input hardening (CROW-581 review): option-injection and orphan
/// rows. Both checks run before any git/fs work, so no tmux/app is needed.
@Suite struct AddWorktreeValidationTests {
    @MainActor
    private func router() -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, forwardSocket: nil)
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
            coderViewAutoPermissionMode: true)   // AppState default: false
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
