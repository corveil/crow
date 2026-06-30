import Foundation
import Testing
import CrowCore
import CrowClaude

/// Locks in the invariant the Manager activity-indicator wiring depends on
/// (#539): `createManagerTerminal` writes hook config *and* the gateway env
/// block into the same `{devRoot}/.claude/settings.local.json`. Neither writer
/// may clobber the other, hooks must carry the explicit `--session <managerID>`
/// (the Manager has no worktree, so cwd-fallback routing can't resolve it), and
/// gateway-env's owner-only (0600) restriction must survive the pair.
@Suite("Manager hook-config + gateway-env coexistence")
struct ManagerHookConfigTests {

    private func makeDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-mgr-hooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readSettings(_ dir: String) -> [String: Any] {
        let path = (dir as NSString).appendingPathComponent(".claude/settings.local.json")
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return parsed
    }

    /// Hooks first, then gateway env — the order `createManagerTerminal` uses —
    /// leaves both blocks present, with hook commands bound to the Manager UUID.
    @Test
    func hooksAndGatewayEnvCoexist() throws {
        let dir = makeDir()
        try ClaudeHookConfigWriter().writeHookConfig(
            worktreePath: dir,
            sessionID: AppState.managerSessionID,
            crowPath: "/usr/local/bin/crow")
        ClaudeHookConfigWriter.writeGatewayEnv(
            dirPath: dir,
            resolved: .init(baseURL: "https://gw.example", customHeaders: "X-Token: secret"))

        let settings = readSettings(dir)
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let env = try #require(settings["env"] as? [String: Any])

        // Every registered event survived the gateway-env write.
        for event in ["SessionStart", "Stop", "PreToolUse", "PostToolUse"] {
            #expect(hooks[event] != nil, "missing hook for \(event)")
        }
        // Hook commands carry the explicit Manager UUID.
        let serialized = String(
            data: try JSONSerialization.data(withJSONObject: hooks), encoding: .utf8) ?? ""
        #expect(serialized.contains(AppState.managerSessionID.uuidString))
        #expect(serialized.contains("hook-event --session"))
        // Gateway env block is intact.
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://gw.example")
    }

    /// The gateway-env write applies owner-only (0600) perms last — the env can
    /// carry a bearer token — and that restriction holds with hooks present.
    @Test
    func gatewayEnvKeepsOwnerOnlyPermissionsWithHooks() throws {
        let dir = makeDir()
        try ClaudeHookConfigWriter().writeHookConfig(
            worktreePath: dir,
            sessionID: AppState.managerSessionID,
            crowPath: "/usr/local/bin/crow")
        ClaudeHookConfigWriter.writeGatewayEnv(
            dirPath: dir,
            resolved: .init(baseURL: "https://gw.example", customHeaders: "X-Token: secret"))

        let path = (dir as NSString).appendingPathComponent(".claude/settings.local.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    /// A Manager with no gateway (resolved == nil) clears env keys but must keep
    /// its hooks — the file is not emptied/removed out from under them.
    @Test
    func hooksSurviveWhenGatewayCleared() throws {
        let dir = makeDir()
        try ClaudeHookConfigWriter().writeHookConfig(
            worktreePath: dir,
            sessionID: AppState.managerSessionID,
            crowPath: "/usr/local/bin/crow")
        ClaudeHookConfigWriter.writeGatewayEnv(dirPath: dir, resolved: nil)

        let settings = readSettings(dir)
        #expect(settings["hooks"] as? [String: Any] != nil)
        #expect(settings["env"] == nil)
    }
}
