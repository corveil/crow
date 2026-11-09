import Foundation
import CrowCore

// Spike: sidebar recording indicator. Records the gateway each agent launch
// actually went out with, at the moment Crow types the launch line.
extension SessionService {
    /// Persist ``Session/launchedGateway`` for one launch of `agentKind`.
    ///
    /// `launchText` is the exact text typed into the pane. It may hold a
    /// credential (a single-header `ANTHROPIC_CUSTOM_HEADERS`, a Codex key
    /// export), so it is only parsed for the base URL and never stored or
    /// logged. `cwd` is where Claude reads `.claude/settings.local.json`.
    @MainActor
    func recordLaunchedGateway(sessionID: UUID, agentKind: AgentKind, launchText: String, cwd: String?) {
        let settings = cwd.flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0)
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.local.json"))
        }
        let record = LaunchedGateway.record(launchText: launchText, agentKind: agentKind, settingsJSON: settings)
        guard let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        appState.sessions[idx].launchedGateway = record
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                data.sessions[i].launchedGateway = record
            }
        }
        CrowLog.info("[SessionService] Launched \(agentKind.rawValue) for session \(sessionID.uuidString): gateway \(record.via.rawValue)\(record.baseURL.map { " -> \($0)" } ?? "")")
    }
}
