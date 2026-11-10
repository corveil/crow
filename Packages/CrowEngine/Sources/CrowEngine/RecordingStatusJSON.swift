import CrowCodex
import CrowCore
import CrowIPC
import Foundation

/// The `recording` object on `list-sessions` / `get-session` rows (CROW-1423,
/// a debug-mode feature): did the agent's traffic reach the gateway, and has
/// its transcript reached Corveil?
///
/// ⚠️ REDACTION. Both RPCs are readable by remote `/rpc` peers. This object
/// carries a gateway **base URL** (scheme, host, port, path), key **ids and
/// names**, org names and fixed explanatory text only — the same line
/// `WorkspaceRPC.workspaceJSON` holds. Never a header name or value, never a
/// key. `RecordingStatusJSONTests` asserts it against a config full of
/// credentials.
///
/// Read-path cheap: one ``Context`` per RPC loads config and the ledger once
/// and indexes the ledger, and nothing here shells out (`op read` is never
/// called) or touches the network.
public enum RecordingStatusJSON {

    /// What one read of the indicator needs, loaded once per RPC and shared by
    /// every row.
    public struct Context: Sendable {
        public let devRoot: String?
        public let config: AppConfig
        public let ledger: RecordingStatus.LedgerIndex
        public let now: Date
        let skipBoard: LogSyncSkipBoard
        let trafficBoard: GatewayTrafficBoard

        /// Nil — and the ledger is never loaded — unless debug mode is on.
        /// That is the whole gate for the RPC side: no context, no
        /// `recording` field.
        public static func load(
            devRoot: String?, config: AppConfig?, now: Date = Date(),
            loadLedger: @Sendable (String) async -> LogSyncLedger = Context.sharedLedger,
            skipBoard: LogSyncSkipBoard = .shared,
            trafficBoard: GatewayTrafficBoard = .shared
        ) async -> Context? {
            guard let config, config.debugMode.enabled else { return nil }
            var ledger = LogSyncLedger()
            if let devRoot { ledger = await loadLedger(devRoot) }
            return Context(
                devRoot: devRoot, config: config, ledger: RecordingStatus.LedgerIndex(ledger), now: now,
                skipBoard: skipBoard, trafficBoard: trafficBoard)
        }

        /// The process-wide ledger for `devRoot` (the store the collector writes).
        @Sendable public static func sharedLedger(devRoot: String) async -> LogSyncLedger {
            await LogSyncLedgerStore.shared(devRoot: devRoot).snapshot()
        }

        /// The `recording` object for one session row.
        @MainActor
        public func row(for session: Session, appState: AppState) -> JSONValue {
            RecordingStatusJSON.build(
                session: session,
                worktreePath: appState.primaryWorktree(for: session.id)?.worktreePath,
                prLinks: appState.links(for: session.id),
                devRoot: devRoot, config: config, ledger: ledger,
                skipNotes: skipBoard.notes(for: session.id),
                traffic: trafficBoard.evidence(for: session.id), now: now)
        }
    }

    public static func build(
        session: Session, worktreePath: String?, prLinks: [SessionLink],
        devRoot: String?, config: AppConfig?, ledger: RecordingStatus.LedgerIndex,
        skipNotes: [LogSyncSkipNote], traffic: GatewayTraffic.Evidence? = nil, now: Date = Date()
    ) -> JSONValue {
        let gateway = gatewayIndicator(
            session: session, worktreePath: worktreePath, prLinks: prLinks,
            devRoot: devRoot, config: config, traffic: traffic)
        let transcripts = RecordingStatus.transcripts(
            session: session, worktreePath: worktreePath, devRoot: devRoot, config: config,
            ledger: ledger, skipNotes: skipNotes, now: now)

        var g: [String: JSONValue] = [
            "state": .string(gateway.state.rawValue),
            "base_url": gateway.baseURL.map { .string($0) } ?? .null,
            "detail": .string(gateway.detail),
        ]
        // Request-log proof (key ids/names and org names only — never a key).
        if let traffic, traffic.state != .none {
            var v: [String: JSONValue] = [
                "state": .string(traffic.state.rawValue),
                "count": .int(traffic.count),
            ]
            if let at = traffic.lastAt { v["last_seen_at"] = .string(ISO8601DateFormatter().string(from: at)) }
            if let org = traffic.seenOrganizationName { v["seen_org"] = .string(org) }
            if let key = traffic.seenAPIKeyName { v["seen_key_name"] = .string(key) }
            if let id = traffic.seenAPIKeyID { v["seen_key_id"] = .string(id) }
            if let org = traffic.expectedOrganizationName { v["expected_org"] = .string(org) }
            g["traffic"] = .object(v)
        }
        if let launched = session.launchedGateway {
            g["launched_at"] = .string(ISO8601DateFormatter().string(from: launched.at))
            g["launched_via"] = .string(launched.via.rawValue)
        }
        var t: [String: JSONValue] = [
            "state": .string(transcripts.state.rawValue),
            "detail": .string(transcripts.detail),
        ]
        if let uploaded = transcripts.uploaded { t["uploaded"] = .int(uploaded) }
        if let total = transcripts.total { t["total"] = .int(total) }
        return .object(["gateway": .object(g), "transcripts": .object(t)])
    }

    /// The gateway a launch of this session's harness would get now, compared
    /// against what it was launched with.
    static func gatewayIndicator(
        session: Session, worktreePath: String?, prLinks: [SessionLink],
        devRoot: String?, config: AppConfig?, traffic: GatewayTraffic.Evidence? = nil
    ) -> RecordingStatus.GatewayIndicator {
        var configuredGateway: WorkspaceGateway?
        if let config {
            configuredGateway = GatewayTrafficVerifier.resolvedGateway(
                session: session, worktreePath: worktreePath, prLinks: prLinks, devRoot: devRoot, config: config)
        }
        let kind = session.agentKind
        let routable: Bool
        let configuredURL: String?
        if kind == .claudeCode {
            routable = true
            configuredURL = configuredGateway.flatMap { $0.isEmpty ? nil : $0.baseURL }
        } else if kind == .codex {
            routable = true
            // `authMode` only picks the upstream; the base URL doesn't depend
            // on it, so skip reading ~/.codex/auth.json on a read path.
            if case .success(let route) = CodexGatewayArgs.route(for: configuredGateway, authMode: { nil }) {
                configuredURL = route.baseURL
            } else {
                configuredURL = nil
            }
        } else {
            routable = false
            configuredURL = nil
        }
        return RecordingStatus.gateway(
            launched: session.launchedGateway,
            // Shown to remote peers: the same reduction the launch record gets.
            configuredBaseURL: configuredURL.map { LaunchedGateway.displayableBaseURL($0) ?? "(a URL Crow can't display)" },
            harnessRoutable: routable,
            agentName: CrowAttribution.agentDisplayName(for: kind),
            traffic: traffic)
    }
}
