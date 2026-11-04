import Foundation
import CrowCodex
import CrowCore

/// Codex's share of the AI gateway (CROW-1407, ADR 0030): which gateway a Codex
/// launch routes through, and the key export that has to precede it.
///
/// Gateway selection is Claude's rule, unchanged. A worker session takes the
/// gateway of the workspace that claims it (``SessionService/workspaceGatewayMatch(for:)``,
/// path first, then PR repo slug). A Manager takes its tagged workspace's
/// gateway, falling back to `managerGateway` (``SessionService/managerGatewayMatch(for:)``).
/// Only the *shape* differs. See ``CodexGatewayArgs``.
///
/// The work is split in two so the key never reaches a persisted or
/// transported string:
///
/// - ``codexGatewayRoute(for:)`` is non-secret (base URL + upstream). It feeds
///   the `-c` overrides baked into every Codex command, including a Manager
///   terminal's stored `command` and `setup.sh`'s `crow new-terminal --command`.
/// - ``codexGatewayKeyPrefix(for:command:)`` resolves the key (`op read` when
///   it's a reference) and is called only at the moment text is typed into a
///   pane. It looks for the override that names the key's env var, so it fires
///   for every routed Codex command whichever path built it, and for nothing
///   else.
extension SessionService {
    /// The gateway a Codex launch for `session` would use, before the Codex
    /// opt-in is consulted. A config read only, no subprocess.
    func codexCandidateGateway(for session: Session) -> WorkspaceGateway? {
        if session.isManager {
            return managerGatewayMatch(for: session)?.gateway
        }
        return workspaceGatewayMatch(for: session.id)?.gateway
    }

    /// Where `session`'s Codex launch routes, or nil to launch Codex exactly as
    /// before. Logs one line whenever the session has a gateway, naming the
    /// outcome, so a Codex session that bypasses Corveil says why. Header names
    /// and base URL only, never a value.
    func codexGatewayRoute(for session: Session) -> CodexGatewayArgs.Route? {
        let prefix = "[SessionService] Codex gateway for session \(session.id)"
        switch CodexGatewayArgs.route(for: codexCandidateGateway(for: session)) {
        case .success(let route):
            CrowLog.info("\(prefix): routed via \(route.baseURL) (X-Corveil-Upstream: \(route.upstream))")
            return route
        case .failure(.noGateway):
            return nil  // The common case for an un-gatewayed workspace — stay quiet.
        case .failure(let skip):
            CrowLog.info("\(prefix): not routed — \(skip.reason)")
            return nil
        }
    }

    /// `export CROW_CORVEIL_GATEWAY_KEY='…' && ` when `command` is a routed Codex
    /// launch, else `""`. Call it only where text is about to be typed into a
    /// pane, never where a command is stored, because the result holds the key.
    ///
    /// A key that can't be resolved (a failed `op read`, or a gateway that was
    /// edited since the command was built) is exported empty rather than
    /// skipped, so Codex reaches Corveil without `X-Corveil-Key` and gets a 401.
    /// It never silently falls back to OpenAI direct.
    func codexGatewayKeyPrefix(for session: Session, command: String) -> String {
        guard CodexGatewayArgs.commandRequestsKey(command) else { return "" }
        let key = codexCandidateGateway(for: session).flatMap { CodexGatewayArgs.resolveKey($0) }
        if key == nil {
            CrowLog.info("[SessionService] Codex gateway for session \(session.id): no Corveil key resolved; Codex will be rejected by the gateway")
        }
        return CodexGatewayArgs.keyExportPrefix(key ?? "")
    }

    /// ``codexGatewayKeyPrefix(for:command:)`` keyed by session id, for the paste
    /// paths that hold a terminal rather than a `Session`. `""` when the session
    /// is gone.
    func codexGatewayKeyPrefix(sessionID: UUID, command: String) -> String {
        guard CodexGatewayArgs.commandRequestsKey(command),
              let session = appState.sessions.first(where: { $0.id == sessionID })
        else { return "" }
        return codexGatewayKeyPrefix(for: session, command: command)
    }
}
