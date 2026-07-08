import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowEngine
import CrowProvider
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// Board RPCs (Ticket Board / Reviews / Allowlist) answer locally off the
/// daemon's own `AppState`. This suite pins the no-provider contract — no
/// tmux/providers needed — so the web UI degrades gracefully: reads return an
/// empty board, actions surface an application error.
@Suite struct BoardForwarderTests {
    /// A router with no providers / tmux wired.
    @MainActor
    private func offlineRouter() -> CommandRouter {
        makeCommandRouter(
            appState: AppState(),
            store: JSONStore(),
            git: GitManager(),
            devRoot: NSTemporaryDirectory(),
            cockpit: nil)
    }

    @Test @MainActor func readBoardsReturnEmptyWhenAppDown() async {
        let router = offlineRouter()

        let tickets = await router.handle(request: JSONRPCRequest(id: 1, method: "list-tickets"))
        #expect(tickets.error == nil)
        #expect(tickets.result?["issues"]?.arrayValue?.isEmpty == true)
        #expect(tickets.result?["done_last_24h"]?.intValue == 0)

        let reviews = await router.handle(request: JSONRPCRequest(id: 2, method: "list-reviews"))
        #expect(reviews.error == nil)
        #expect(reviews.result?["reviews"]?.arrayValue?.isEmpty == true)

        let allow = await router.handle(request: JSONRPCRequest(id: 3, method: "list-allowlist"))
        #expect(allow.error == nil)
        #expect(allow.result?["entries"]?.arrayValue?.isEmpty == true)

        let live = await router.handle(request: JSONRPCRequest(id: 4, method: "list-sessions-live"))
        #expect(live.error == nil)
        #expect(live.result?["sessions"]?.objectValue?.isEmpty == true)
    }

    @Test @MainActor func boardActionsErrorWhenAppDown() async {
        let router = offlineRouter()
        // Spawn/label actions genuinely need the app's SessionService / gh; they
        // still error with the app down. (The store-backed status transitions —
        // mark-in-review / complete-session / set-session-active — now run
        // locally, so they're covered by LocalStatusTests instead.)
        let actions = [
            "work-on-issue", "start-review", "promote-allowlist", "refresh-tickets", "refresh-allowlist",
            "create-manager", "mark-issue-done", "add-merge-label",
        ]
        for method in actions {
            let resp = await router.handle(request: JSONRPCRequest(id: 1, method: method))
            #expect(resp.error != nil, "\(method) should error when the app is down")
            #expect(resp.error?.code == RPCErrorCode.applicationError, "\(method) should be an application error")
        }
    }
}

/// M-E slice: the store-backed session status transitions gained an app-down
/// local path (mirroring `set-status`), so they work headless. Pure
/// `session.status` writes — the local path runs only with the app off, so
/// there's no two-writer divergence (CROW-581).
@Suite struct LocalStatusTests {
    @MainActor
    private func seededRouter() -> (CommandRouter, AppState, Session) {
        let appState = AppState()
        let store = JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crowd-status-\(UUID().uuidString)"))
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        store.mutate { $0.sessions = [session] }
        let router = makeCommandRouter(
            appState: appState, store: store, git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)
        return (router, appState, session)
    }

    @Test @MainActor func statusTransitionsRunLocallyWhenAppDown() async {
        for (method, expected) in [
            ("mark-in-review", SessionStatus.inReview),
            ("complete-session", .completed),
            ("set-session-active", .active),
        ] {
            let (router, appState, session) = seededRouter()
            let resp = await router.handle(request: JSONRPCRequest(
                id: 1, method: method, params: ["session_id": .string(session.id.uuidString)]))
            #expect(resp.error == nil, "\(method) should run locally with the app down")
            #expect(resp.result?["status"]?.stringValue == expected.rawValue)
            #expect(appState.sessions.first?.status == expected)
        }
    }

    @Test @MainActor func statusTransitionRejectsMissingSessionID() async {
        let (router, _, _) = seededRouter()
        let resp = await router.handle(request: JSONRPCRequest(id: 1, method: "mark-in-review"))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }
}

/// Unlike the board reads, `list-agents` is **local**: the daemon registers its
/// own coding agents at startup, so the agent picker works with the desktop app
/// down (CROW-581, M-B). This pins that inversion — a bare router still
/// returns the registered agents.
@Suite struct AgentsLocalTests {
    @Test @MainActor func listAgentsIsLocalNotForwarded() async {
        // Register in this process's registry, as `CrowDaemon.run()` does.
        AgentRegistry.shared.register(ClaudeCodeAgent())

        let router = makeCommandRouter(
            appState: AppState(), store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)

        let resp = await router.handle(request: JSONRPCRequest(id: 1, method: "list-agents"))
        #expect(resp.error == nil)
        let kinds = (resp.result?["agents"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["kind"]?.stringValue }
        #expect(kinds.contains(AgentKind.claudeCode.rawValue),
                "list-agents must serve the locally-registered Claude agent even with the app down")
    }
}

/// M-C inversion: when the daemon owns the board services, `list-tickets` /
/// `list-reviews` / `list-allowlist` answer **locally** off `appState`
/// (populated by the daemon's own IssueTracker/AllowListService) instead of
/// forwarding — so the boards work with the app down (CROW-581). The service
/// instances here are never polled; passing them just flips the router to the
/// owned-data path.
@Suite struct LocalBoardTests {
    @Test @MainActor func listTicketsServesLocalAppStateWhenOwned() async {
        let appState = AppState()
        appState.assignedIssues = [
            AssignedIssue(
                id: "github:acme/api#7", number: 7, title: "Fix login", state: "open",
                url: "https://github.com/acme/api/issues/7", repo: "acme/api",
                provider: .github, projectStatus: .backlog),
        ]
        let tracker = IssueTracker(appState: appState, providerManager: ProviderManager())
        let router = makeCommandRouter(
            appState: appState, store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, tracker: tracker)

        let resp = await router.handle(request: JSONRPCRequest(id: 1, method: "list-tickets"))
        #expect(resp.error == nil)
        let issues = resp.result?["issues"]?.arrayValue ?? []
        #expect(issues.count == 1)
        #expect(issues.first?.objectValue?["number"]?.intValue == 7)
    }

    @Test @MainActor func listAllowlistServesLocalAppStateWhenOwned() async {
        let appState = AppState()
        appState.allowEntries = [AllowEntry(pattern: "Bash(npm test:*)", sources: [.global])]
        let allowList = AllowListService(appState: appState, devRoot: NSTemporaryDirectory())
        let router = makeCommandRouter(
            appState: appState, store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, allowList: allowList)

        let resp = await router.handle(request: JSONRPCRequest(id: 1, method: "list-allowlist"))
        #expect(resp.error == nil)
        let entries = resp.result?["entries"]?.arrayValue ?? []
        #expect(entries.count == 1)
        #expect(entries.first?.objectValue?["pattern"]?.stringValue == "Bash(npm test:*)")
        #expect(entries.first?.objectValue?["is_global"]?.boolValue == true)
    }
}

/// `get-config` / `set-config` back the web Settings modal. Unlike the board
/// reads (which return empty when the app is down), config falls back to reading
/// and writing `{devRoot}/.claude/config.json` directly, so Settings work
/// headless. This suite pins that app-down contract: credential **values** are
/// stripped on read and preserved (never clobbered) on write.
@Suite struct ConfigForwarderTests {
    /// A fresh, isolated devRoot so each test owns its `.claude/config.json`.
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func offlineRouter(devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    /// A config carrying plaintext secrets, so we can prove they never leave and
    /// are never clobbered.
    private func configWithSecrets() -> AppConfig {
        var c = AppConfig()
        c.remoteControlEnabled = true
        c.jiraCredential = JiraCredential(username: "me@corp.com", tokenRef: "PLAINTEXT-JIRA-TOKEN")
        c.managerGateway = WorkspaceGateway(
            baseURL: "https://gw.example", customHeaders: ["Authorization": "Bearer GATEWAY-SECRET"])
        return c
    }

    private func encode(_ config: AppConfig) throws -> String {
        String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    }

    @Test @MainActor func getConfigStripsSecretsWhenAppDown() async throws {
        let devRoot = tempDevRoot()
        try ConfigStore.saveConfig(configWithSecrets(), devRoot: devRoot)

        let resp = await offlineRouter(devRoot: devRoot)
            .handle(request: JSONRPCRequest(id: 1, method: "get-config"))
        #expect(resp.error == nil)
        #expect(resp.result?["app_running"]?.boolValue == false)
        #expect(resp.result?["dev_root"]?.stringValue == devRoot)

        let json = try #require(resp.result?["config"]?.stringValue)
        // Plaintext secrets must not appear anywhere in the transported string.
        #expect(!json.contains("PLAINTEXT-JIRA-TOKEN"))
        #expect(!json.contains("GATEWAY-SECRET"))

        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.jiraCredential?.username == "me@corp.com")   // non-secret kept
        #expect(decoded.jiraCredential?.tokenRef == "")              // secret stripped
        #expect(decoded.managerGateway?.baseURL == "https://gw.example")
        #expect(decoded.managerGateway?.customHeaders["Authorization"] == "")
        #expect(decoded.remoteControlEnabled == true)
    }

    @Test @MainActor func getConfigReturnsDefaultWhenNoFile() async throws {
        let resp = await offlineRouter(devRoot: tempDevRoot())
            .handle(request: JSONRPCRequest(id: 1, method: "get-config"))
        #expect(resp.error == nil)
        let json = try #require(resp.result?["config"]?.stringValue)
        // Decodes to a valid (default) config — no crash, no error.
        _ = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    @Test @MainActor func setConfigPreservesStoredSecretsWhenAppDown() async throws {
        let devRoot = tempDevRoot()
        try ConfigStore.saveConfig(configWithSecrets(), devRoot: devRoot)

        // Simulate a browser: it got the stripped config, flipped a non-secret
        // toggle, and sent it back with the credential values still blank.
        var incoming = SettingsSecrets.strippedForTransport(configWithSecrets())
        incoming.remoteControlEnabled = false

        let resp = await offlineRouter(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "set-config", params: ["config": .string(try encode(incoming))]))
        #expect(resp.error == nil)
        #expect(resp.result?["saved"]?.boolValue == true)

        // On disk: the stored secrets survived; the non-secret edit applied.
        let saved = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(saved.jiraCredential?.tokenRef == "PLAINTEXT-JIRA-TOKEN")
        #expect(saved.managerGateway?.customHeaders["Authorization"] == "Bearer GATEWAY-SECRET")
        #expect(saved.remoteControlEnabled == false)
    }

    @Test @MainActor func setConfigRejectsMalformedConfig() async {
        let resp = await offlineRouter(devRoot: tempDevRoot()).handle(request: JSONRPCRequest(
            id: 1, method: "set-config", params: ["config": .string("not-json")]))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }
}

