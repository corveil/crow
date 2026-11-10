import CrowIPC
import Foundation
import Testing
@testable import CrowCore
@testable import CrowEngine

/// CROW-1423: the debug-mode gate and the redaction line of the recording
/// indicator, on the shared code `list-sessions` and `get-session` both call.
@Suite struct RecordingIndicatorTests {
    static let devRoot = "/dev/root"
    static let now = Date(timeIntervalSince1970: 2_000_000)
    // Every credential-shaped string the config below carries.
    static let secrets = [
        "sk-citadel-WORKSPACE-SECRET", "sk-citadel-MANAGER-SECRET", "sk-citadel-ORG-SECRET",
        "Bearer sk-citadel", "x-citadel-api-key", "X-Citadel-Api-Key", "authorization", "Authorization",
        "x-extra-header", "EXTRA-HEADER-VALUE", "refresh-token-value", "access-token-value",
    ]

    /// A config where every gateway, the connection and its org keys carry
    /// credentials, so a leak anywhere in the payload would show.
    static func loadedConfig(debug: Bool = true) -> (AppConfig, WorkspaceInfo) {
        let workspace = WorkspaceInfo(
            name: "corveil", uploadSessionLogs: true,
            gateway: WorkspaceGateway(
                baseURL: "https://user:pw@corveil.test/?token=QUERY-SECRET",
                customHeaders: ["x-citadel-api-key": "Bearer sk-citadel-WORKSPACE-SECRET",
                                "x-extra-header": "EXTRA-HEADER-VALUE"]))
        var config = AppConfig(workspaces: [workspace])
        config.debugMode.enabled = debug
        config.managerGateway = WorkspaceGateway(
            baseURL: "https://corveil.test",
            customHeaders: ["Authorization": "Bearer sk-citadel-MANAGER-SECRET"])
        config.corveilConnection = CorveilConnection(
            baseURL: "https://corveil.test", clientID: "client",
            orgKeys: [CorveilOrgKey(orgID: "org-c", orgName: "Corveil, Inc.", keyID: "key-c", keyPrefix: "sk-citadel-OR")],
            orgKeySecrets: ["org-c": "sk-citadel-ORG-SECRET"],
            oauth: CorveilOAuthTokens(accessToken: "access-token-value", refreshToken: "refresh-token-value"))
        return (config, workspace)
    }

    static func string(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: - Gate

    @Test func noContextAndNoLedgerReadWhileDebugModeIsOff() async {
        let (config, _) = Self.loadedConfig(debug: false)
        let reads = RecordingCounter()
        let context = await RecordingStatusJSON.Context.load(
            devRoot: Self.devRoot, config: config, loadLedger: { _ in reads.bump(); return LogSyncLedger() })
        #expect(context == nil)
        #expect(reads.value == 0)
        // An unreadable config is the same as off.
        #expect(await RecordingStatusJSON.Context.load(devRoot: Self.devRoot, config: nil) == nil)
        // And the default for an install that never set it is off.
        #expect(AppConfig().debugMode.enabled == false)
    }

    @Test func contextLoadsTheLedgerOnceWhenOn() async {
        let (config, _) = Self.loadedConfig()
        let reads = RecordingCounter()
        let context = await RecordingStatusJSON.Context.load(
            devRoot: Self.devRoot, config: config, loadLedger: { _ in reads.bump(); return LogSyncLedger() })
        #expect(context != nil)
        #expect(reads.value == 1)
    }

    // MARK: - Redaction

    /// `list-sessions` / `get-session` are readable by remote `/rpc` peers:
    /// the payload holds base URLs, key ids/names and org names only.
    @Test @MainActor func payloadCarriesNoHeaderNameOrValue() async throws {
        let (config, workspace) = Self.loadedConfig()
        let appState = AppState()
        var work = Session(name: "work", kind: .work)
        work.launchedGateway = LaunchedGateway.record(
            launchText: "export ANTHROPIC_BASE_URL='https://corveil.test' ANTHROPIC_CUSTOM_HEADERS='x-citadel-api-key: Bearer sk-citadel-WORKSPACE-SECRET' && claude",
            agentKind: .claudeCode, settingsJSON: nil)
        var manager = Session(name: "mgr", kind: .manager, workspaceID: workspace.id)
        manager.harnessConversationID = "conv-1"
        appState.sessions = [work, manager]
        appState.worktrees[work.id] = [SessionWorktree(
            sessionID: work.id, repoName: "crow", repoPath: "/dev/root/corveil/crow",
            worktreePath: "/dev/root/corveil/crow-1-x", branch: "b", isPrimary: true)]

        let traffic = GatewayTrafficBoard()
        traffic.replace([
            work.id: GatewayTraffic.Evidence(
                state: .verified, count: 3, lastAt: Self.now, seenOrganizationID: "org-c",
                seenOrganizationName: "Corveil, Inc.", seenAPIKeyID: "key-c", seenAPIKeyName: "Crow gateway",
                expectedOrganizationName: "Corveil, Inc.", detail: "Verified: 3 requests"),
        ], sources: [], at: Self.now)
        let skips = LogSyncSkipBoard()
        skips.record(manager.id, LogSyncSkipNote(reason: "no-transcript", detail: "no transcript file", scope: "conv-1"))

        let context = try #require(await RecordingStatusJSON.Context.load(
            devRoot: Self.devRoot, config: config, now: Self.now,
            loadLedger: { _ in LogSyncLedger() }, skipBoard: skips, trafficBoard: traffic))
        for session in appState.sessions {
            let row = context.row(for: session, appState: appState)
            let text = try Self.string(row)
            for secret in Self.secrets + ["QUERY-SECRET", "user:pw", "pw@"] {
                #expect(!text.contains(secret), "\(session.name) leaks \(secret): \(text)")
            }
            #expect(row.objectValue?["gateway"]?.objectValue?["state"] != nil)
            #expect(row.objectValue?["transcripts"]?.objectValue?["state"] != nil)
        }
        let workRow = context.row(for: work, appState: appState).objectValue?["gateway"]?.objectValue
        #expect(workRow?["state"] == .string("verified"))
        #expect(workRow?["traffic"]?.objectValue?["seen_key_name"] == .string("Crow gateway"))
        #expect(workRow?["base_url"] == .string("https://corveil.test"))
    }

    /// The traffic verdict reaches the glyph: a mismatch reads `mismatch`.
    @Test @MainActor func mismatchEvidenceBecomesTheGatewayState() async throws {
        let (config, workspace) = Self.loadedConfig()
        let appState = AppState()
        var manager = Session(name: "bad", kind: .manager, workspaceID: workspace.id)
        manager.harnessConversationID = "conv-bad"
        appState.sessions = [manager]
        let traffic = GatewayTrafficBoard()
        traffic.replace([
            manager.id: GatewayTraffic.Evidence(
                state: .mismatch, count: 44, lastAt: Self.now, seenOrganizationID: "org-x",
                seenOrganizationName: "Client A", seenAPIKeyID: "key-x", seenAPIKeyName: "Crow gateway",
                expectedOrganizationName: "Corveil, Inc.",
                detail: "44 of 44 requests went to Client A"),
        ], sources: [], at: Self.now)
        let context = try #require(await RecordingStatusJSON.Context.load(
            devRoot: Self.devRoot, config: config, now: Self.now, loadLedger: { _ in LogSyncLedger() },
            skipBoard: LogSyncSkipBoard(), trafficBoard: traffic))
        let gateway = context.row(for: manager, appState: appState).objectValue?["gateway"]?.objectValue
        #expect(gateway?["state"] == .string("mismatch"))
        #expect(gateway?["traffic"]?.objectValue?["seen_org"] == .string("Client A"))
        #expect(gateway?["traffic"]?.objectValue?["expected_org"] == .string("Corveil, Inc."))
        #expect(gateway?["traffic"]?.objectValue?["count"] == .int(44))
    }

    // MARK: - Schedule

    @Test func scheduleRunsAtOnceThenEveryFiveMinutes() {
        var schedule = GatewayTrafficSchedule()
        let t0 = Self.now
        #expect(schedule.next(debugMode: true, now: t0) == .run)  // crowd start with it on
        #expect(schedule.next(debugMode: true, now: t0.addingTimeInterval(30)) == .idle)
        #expect(schedule.next(debugMode: true, now: t0.addingTimeInterval(299)) == .idle)
        #expect(schedule.next(debugMode: true, now: t0.addingTimeInterval(300)) == .run)
    }

    @Test func scheduleNeverRunsWhileOffAndClearsOnceWhenTurnedOff() {
        var schedule = GatewayTrafficSchedule()
        let t0 = Self.now
        #expect(schedule.next(debugMode: false, now: t0) == .idle)
        #expect(schedule.next(debugMode: false, now: t0.addingTimeInterval(600)) == .idle)
        #expect(schedule.next(debugMode: true, now: t0.addingTimeInterval(630)) == .run)  // just turned on
        #expect(schedule.next(debugMode: false, now: t0.addingTimeInterval(660)) == .clear)
        #expect(schedule.next(debugMode: false, now: t0.addingTimeInterval(690)) == .idle)
        // Back on: runs at once, not five minutes after the last pass.
        #expect(schedule.next(debugMode: true, now: t0.addingTimeInterval(720)) == .run)
    }

    // MARK: - Poller

    /// With debug mode off, `crowd` reads no request log at all — neither an
    /// org key over HTTP nor the `corveil` CLI.
    @Test @MainActor func pollerMakesNoRequestLogReadsWhileOff() async {
        var (config, _) = Self.loadedConfig(debug: false)
        let appState = AppState()
        var session = Session(name: "w", kind: .work)
        session.harnessConversationID = "c"
        appState.sessions = [session]
        let reads = RecordingCounter()
        let board = GatewayTrafficBoard()
        board.replace([session.id: GatewayTraffic.Evidence(state: .verified, count: 1, detail: "old")],
                      sources: [], at: Self.now)
        let box = ConfigBox(config)
        let poller = GatewayTrafficPoller(
            devRoot: Self.devRoot, appState: appState, loadConfig: { _ in box.value },
            verifier: GatewayTrafficVerifier(
                http: { _, _ in reads.bump(); return nil },
                cli: { _, _ in reads.bump(); return nil },
                corveilBinary: { _ in "/fake/corveil" }, now: { Self.now }),
            board: board, now: { Self.now })

        #expect(await poller.tick() == .idle)
        #expect(await poller.tick() == .idle)
        #expect(reads.value == 0)

        // On: one pass reads. Off again: the old evidence is dropped.
        config.debugMode.enabled = true
        box.value = config
        #expect(await poller.tick() == .run)
        #expect(reads.value > 0)
        config.debugMode.enabled = false
        box.value = config
        let before = reads.value
        #expect(await poller.tick() == .clear)
        #expect(reads.value == before)
        #expect(board.evidence(for: session.id) == nil)
    }
}

final class RecordingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: AppConfig
    init(_ config: AppConfig) { self.config = config }
    var value: AppConfig {
        get { lock.withLock { config } }
        set { lock.withLock { config = newValue } }
    }
}
