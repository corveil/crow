import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

/// CROW-1409: a Codex Manager must not resume by id across `model_provider`s,
/// because Codex 0.166's TUI refuses that and drops the pane to a shell.
@Suite("CodexThreadProvider")
struct CodexThreadProviderTests {
    private let id = "01a1ace4-3546-7381-b164-ab297834178c"
    private let route = CodexGatewayArgs.Route(baseURL: "https://corveil.io/v1", upstream: "chatgpt_codex")

    private func agent(recorded: String?, configured: String = "openai") -> OpenAICodexAgent {
        OpenAICodexAgent(threadProviders: .init(
            recorded: { _ in recorded }, configured: { configured }))
    }

    private func manager(_ agent: OpenAICodexAgent, id: String?, route: CodexGatewayArgs.Route?) -> String {
        agent.managerLaunchCommand(
            sessionName: "Manager 2", remoteControlEnabled: false, autoPermissionMode: false,
            telemetryPort: nil, conversationID: id, gatewayRoute: route)
    }

    // MARK: Launch decision

    @Test func matchingProviderStillResumesById() {
        // Unrouted, thread recorded under the user's configured provider.
        let plain = manager(agent(recorded: "corveil", configured: "corveil"), id: id, route: nil)
        #expect(plain.hasSuffix("resume '\(id)' --no-alt-screen"))
        // Routed, thread recorded under crow-corveil (ADR 0028 unchanged).
        let routed = manager(agent(recorded: "crow-corveil"), id: id, route: route)
        #expect(routed.hasSuffix("resume '\(id)' --no-alt-screen"))
        #expect(CodexGatewayArgs.commandRequestsKey(routed))
    }

    /// The ticket's case: a hand-started `corveil` thread, then a routed launch.
    @Test func routedLaunchDropsAThreadRecordedUnderAnotherProvider() {
        let cmd = manager(agent(recorded: "corveil", configured: "corveil"), id: id, route: route)
        #expect(!cmd.contains("resume"))
        #expect(cmd.hasSuffix(" --no-alt-screen"))
        // Still routed: dropping the id must not drop the gateway.
        #expect(CodexGatewayArgs.commandRequestsKey(cmd))
    }

    /// Routing turned off for a Manager whose thread is `crow-corveil`.
    @Test func unroutedLaunchDropsACrowCorveilThread() {
        let cmd = manager(agent(recorded: "crow-corveil", configured: "openai"), id: id, route: nil)
        #expect(!cmd.contains("resume"))
    }

    /// A Manager created before routing was turned on: default-provider thread.
    @Test func routingTurnedOnDropsADefaultProviderThread() {
        let cmd = manager(agent(recorded: "openai"), id: id, route: route)
        #expect(!cmd.contains("resume"))
    }

    /// Rows that predate CROW-1409 (or a pruned rollout) have no known
    /// provider. That never falls through to a by-id resume.
    @Test func unknownProviderIsAMismatch() {
        #expect(!manager(agent(recorded: nil), id: id, route: nil).contains("resume"))
        #expect(!manager(agent(recorded: nil), id: id, route: route).contains("resume"))
    }

    @Test func noStoredIdNeverConsultsTheLookups() {
        let agent = OpenAICodexAgent(threadProviders: .init(
            recorded: { _ in Issue.record("recorded consulted"); return nil },
            configured: { Issue.record("configured consulted"); return "openai" }))
        #expect(!manager(agent, id: nil, route: nil).contains("resume"))
        #expect(!manager(agent, id: "  ", route: route).contains("resume"))
    }

    @Test func launchProviderIsCrowCorveilOnlyWhenRouted() {
        #expect(CodexThreadProvider.launchProvider(route: route, configured: { "corveil" }) == "crow-corveil")
        #expect(CodexThreadProvider.launchProvider(route: nil, configured: { "corveil" }) == "corveil")
    }

    // MARK: Rollout reading

    private func scratchSessions() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-codex-provider-\(UUID().uuidString)/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeRollout(
        in sessions: URL, day: String, stamp: String, id: String, firstLine: String
    ) throws {
        let dir = sessions.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = firstLine + "\n" + #"{"type":"response_item","payload":{}}"# + "\n"
        try body.write(to: dir.appendingPathComponent("rollout-\(stamp)-\(id).jsonl"),
                       atomically: true, encoding: .utf8)
    }

    /// Shape of a real 0.166 `session_meta` line, including the ~20 KB
    /// `base_instructions` that pushes `model_provider` past the first chunk.
    private func sessionMeta(id: String, provider: String?) -> String {
        var payload: [String: Any] = [
            "id": id, "cwd": "/tmp/m", "originator": "codex-tui", "cli_version": "0.166.0",
            "base_instructions": ["text": String(repeating: "x", count: 80_000)],
        ]
        if let provider { payload["model_provider"] = provider }
        let object: [String: Any] = ["timestamp": "2026-11-05T17:01:13.224Z", "type": "session_meta", "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @Test func readsTheRecordedProviderFromTheRollout() throws {
        let sessions = try scratchSessions()
        defer { try? FileManager.default.removeItem(at: sessions.deletingLastPathComponent()) }
        try writeRollout(in: sessions, day: "2026/11/04", stamp: "2026-11-04T17-48-12", id: id,
                         firstLine: sessionMeta(id: id, provider: "corveil"))
        #expect(CodexThreadProvider.recordedProvider(conversationID: id, sessionsDir: sessions.path) == "corveil")
        // Case-insensitive id match, like the locator.
        #expect(CodexThreadProvider.recordedProvider(
            conversationID: id.uppercased(), sessionsDir: sessions.path) == "corveil")
    }

    @Test func missingRolloutOrProviderIsUnknown() throws {
        let sessions = try scratchSessions()
        defer { try? FileManager.default.removeItem(at: sessions.deletingLastPathComponent()) }
        #expect(CodexThreadProvider.recordedProvider(conversationID: id, sessionsDir: sessions.path) == nil)
        try writeRollout(in: sessions, day: "2026/11/04", stamp: "2026-11-04T17-48-12", id: id,
                         firstLine: sessionMeta(id: id, provider: nil))
        #expect(CodexThreadProvider.recordedProvider(conversationID: id, sessionsDir: sessions.path) == nil)
        let other = "01a1ace4-3546-7381-b164-000000000000"
        try writeRollout(in: sessions, day: "2026/11/05", stamp: "2026-11-05T10-00-00", id: other,
                         firstLine: #"{"type":"response_item","payload":{"model_provider":"openai"}}"#)
        #expect(CodexThreadProvider.recordedProvider(conversationID: other, sessionsDir: sessions.path) == nil)
        // Path-escaping ids are refused outright.
        #expect(CodexRollout.path(conversationID: "../x", sessionsDir: sessions.path) == nil)
    }

    // MARK: config.toml

    @Test func configuredProviderReadsConfigToml() {
        #expect(CodexThreadProvider.configuredProvider(configTOML: "") == "openai")
        #expect(CodexThreadProvider.configuredProvider(configTOML: """
            model = "gpt-5"
            model_provider = "corveil"  # the operator's own

            [model_providers.corveil]
            name = "Corveil"
            model_provider = "not-this"
            """) == "corveil")
        // A key under a table is not the top-level one.
        #expect(CodexThreadProvider.configuredProvider(configTOML: """
            [model_providers.corveil]
            model_provider = "nope"
            """) == "openai")
    }

    @Test func activeProfileOverridesTheTopLevelProvider() {
        let toml = """
            model_provider = 'corveil'
            profile = "work"

            [profiles.home]
            model_provider = "openai"

            [profiles."work"]
            model_provider = "azure"
            """
        #expect(CodexThreadProvider.configuredProvider(configTOML: toml) == "azure")
        // A profile that sets no provider leaves the top-level one.
        #expect(CodexThreadProvider.configuredProvider(configTOML: """
            model_provider = "corveil"
            profile = "bare"
            [profiles.bare]
            model = "o3"
            """) == "corveil")
    }

    @Test func configuredProviderReadsCodexHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodexThreadProvider.configuredProvider(codexHome: home.path) == "openai")
        try #"model_provider = "corveil""#.write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexThreadProvider.configuredProvider(codexHome: home.path) == "corveil")
    }
}
