import CrowCodex
import CrowCore
import CrowIPC
import Foundation

/// The `recording` object on `list-sessions` / `get-session` rows (spike:
/// sidebar recording indicator): did the agent launch through a gateway, and
/// has its transcript reached Corveil?
///
/// ⚠️ REDACTION. Both RPCs are readable by remote `/rpc` peers. This object
/// carries a gateway **base URL** and fixed explanatory text only, the same
/// line `WorkspaceRPC.workspaceJSON` holds: never a header name or value.
///
/// Read-path cheap: config + ledger are passed in (one read per poll), and
/// nothing here shells out (`op read` is never called).
public enum RecordingStatusJSON {
    public static func build(
        session: Session, worktreePath: String?, prLinks: [SessionLink],
        devRoot: String?, config: AppConfig?, ledger: LogSyncLedger,
        skipNotes: [LogSyncSkipNote], now: Date = Date()
    ) -> JSONValue {
        let gateway = gatewayIndicator(
            session: session, worktreePath: worktreePath, prLinks: prLinks,
            devRoot: devRoot, config: config)
        let transcripts = RecordingStatus.transcripts(
            session: session, worktreePath: worktreePath, devRoot: devRoot, config: config,
            ledger: ledger, skipNotes: skipNotes, now: now)

        var g: [String: JSONValue] = [
            "state": .string(gateway.state.rawValue),
            "base_url": gateway.baseURL.map { .string($0) } ?? .null,
            "detail": .string(gateway.detail),
        ]
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
        devRoot: String?, config: AppConfig?
    ) -> RecordingStatus.GatewayIndicator {
        var configuredGateway: WorkspaceGateway?
        if let config {
            if session.isManager {
                configuredGateway = ManagerSessionController.managerGatewayMatch(
                    workspaceTag: session.managerWorkspaceTag, config: config).gateway
            } else if let devRoot {
                configuredGateway = SessionService.gatewayMatch(
                    worktreePath: worktreePath, prLinks: prLinks, devRoot: devRoot, config: config)?.gateway
            }
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
            launched: session.launchedGateway, configuredBaseURL: configuredURL,
            harnessRoutable: routable,
            agentName: CrowAttribution.agentDisplayName(for: kind))
    }
}
