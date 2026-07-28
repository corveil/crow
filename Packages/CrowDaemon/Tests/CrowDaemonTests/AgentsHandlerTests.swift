import Foundation
import Testing
import CrowClaude
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// End-to-end coverage of the `agents-get` / `agents-set` handlers behind
/// `crow agents` (CROW-811): the real router, against a real `config.json` in a
/// temp dev root.
///
/// The unit tests in `AgentsRPCSupportTests` pin the pure decode/encode; these pin
/// what only the handler can get wrong — that a patch persists exactly what it was
/// given, that a rejection writes nothing at all, and above all that clearing a
/// role **removes** the key rather than nulling it.
///
/// **Registry hygiene.** `AgentRegistry.shared` is a process-wide singleton with no
/// unregister, seeded additively by whichever tests ran first (eight files in this
/// target register `ClaudeCodeAgent()`; two also register Cursor), and Swift Testing
/// runs suites in parallel. So each test below registers Claude Code itself
/// (idempotent), asserts only that `available` *contains* it — never its count or
/// exact contents — and uses `unregisteredKind` for rejection cases: a string
/// nothing will ever register.
@Suite struct AgentsHandlerTests {
    /// A kind no agent will ever be registered for, so rejection tests can't be
    /// broken by another suite registering a real harness first.
    private let unregisteredKind = "crow-811-unregistered"

    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-agents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func configPath(_ devRoot: String) -> String {
        ((devRoot as NSString).appendingPathComponent(".claude") as NSString)
            .appendingPathComponent("config.json")
    }

    @MainActor
    private func router(devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    @MainActor
    private func call(
        _ method: String, _ params: [String: JSONValue] = [:], devRoot: String
    ) async -> JSONRPCResponse {
        await router(devRoot: devRoot)
            .handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    private func agents(_ response: JSONRPCResponse) -> [String: JSONValue]? {
        response.result?["agents"]?.objectValue
    }

    // MARK: - Reads

    @Test @MainActor func getReturnsDefaultsWhenNoConfigExists() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let payload = agents(await call("agents-get", devRoot: devRoot))
        #expect(payload?["default_agent_kind"] == .string("claude-code"))
        #expect(payload?["by_kind"] == .object([:]))
        #expect(payload?["effective"] == .object([
            "work": .string("claude-code"),
            "review": .string("claude-code"),
            "job": .string("claude-code"),
            "manager": .string("claude-code"),
            "workerRun": .string("claude-code"),
        ]))
        #expect(payload?["config_readable"] == .bool(true))
    }

    /// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed";
    /// reporting the second as readable would present invented defaults as fact.
    @Test @MainActor func getReportsConfigUnreadable() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try FileManager.default.createDirectory(
            atPath: (devRoot as NSString).appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        try #"{"workspaces": "not-an-array"}"#
            .write(toFile: configPath(devRoot), atomically: true, encoding: .utf8)

        let payload = agents(await call("agents-get", devRoot: devRoot))
        #expect(payload?["config_readable"] == .bool(false))
        #expect(payload?["default_agent_kind"] == .string("claude-code"))
    }

    /// Pins that a `known` row carries no `default` field. `list-agents` has one
    /// and it means the *registry* default; here it would be read as the
    /// *configured* default sitting right beside it.
    @Test @MainActor func knownListsRegisteredAgentsWithTheExpectedFields() async {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let entries = agents(await call("agents-get", devRoot: devRoot))?["known"]?.arrayValue
        let claude = entries?.first { $0.objectValue?["kind"] == .string("claude-code") }
        #expect(claude != nil)
        #expect(claude?.objectValue?["name"]?.stringValue?.isEmpty == false)
        // Claude Code is always available — the one row whose flag is knowable
        // without depending on what's installed on the test machine.
        #expect(claude?.objectValue?["available"] == .bool(true))
        for entry in entries ?? [] {
            #expect(Set(entry.objectValue?.keys ?? [:].keys)
                == ["kind", "name", "binary", "available"])
        }
    }

    // MARK: - Writes

    @Test @MainActor func setDefaultAgentKindPersists() async throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call(
            "agents-set", ["default_agent_kind": .string("claude-code")], devRoot: devRoot)

        #expect(resp.result?["saved"] == .bool(true))
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaultAgentKind == .claudeCode)
    }

    @Test @MainActor func setRoleOverridePersistsAndLeavesEverythingElseAlone() async throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.workspaces = [WorkspaceInfo(
            name: "Corveil", provider: "github", cli: "gh", alwaysInclude: ["corveil/crow"])]
        seed.defaultAgentKind = .claudeCode
        seed.agentsByKind = ["review": .codex]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        _ = await call(
            "agents-set", ["by_kind": .object(["work": .string("claude-code")])], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.agentsByKind["work"] == .claudeCode)
        // The role we didn't mention keeps its value — that is the PATCH.
        #expect(onDisk.agentsByKind["review"] == .codex)
        #expect(onDisk.defaultAgentKind == .claudeCode)
        #expect(onDisk.workspaces.map(\.name) == ["Corveil"])
    }

    /// The load-bearing test of the ticket. `[String: AgentKind]` cannot decode a
    /// JSON null and `AppConfig.init(from:)` decodes the map with `try`, so writing
    /// `{"review": null}` would make the *whole* config.json undecodable — every
    /// workspace, job and credential invisible, and every later write refused.
    @Test @MainActor func clearRemovesTheKeyRatherThanNullingIt() async throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.agentsByKind = ["review": .claudeCode, "work": .claudeCode]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call(
            "agents-set", ["clear": .array([.string("review")])], devRoot: devRoot)
        #expect(resp.result?["saved"] == .bool(true))

        // (a) the decoded map has no such key
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(!onDisk.agentsByKind.keys.contains("review"))
        #expect(onDisk.agentsByKind["work"] == .claudeCode)

        // (b) the raw file has no `review` key and no null anywhere in the map
        let raw = try Data(contentsOf: URL(fileURLWithPath: configPath(devRoot)))
        let object = try #require(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let byKind = try #require(object["agentsByKind"] as? [String: Any])
        #expect(byKind["review"] == nil)
        #expect(!byKind.values.contains { $0 is NSNull })

        // (c) and the file still loads at all — what a null write would break
        #expect(ConfigStore.loadConfig(devRoot: devRoot) != nil)

        // The response agrees with disk.
        #expect(agents(resp)?["by_kind"] == .object(["work": .string("claude-code")]))
        #expect(agents(resp)?["effective"]?.objectValue?["review"] == .string("claude-code"))
    }

    @Test @MainActor func clearingAnAbsentRoleSucceedsAndChangesNothing() async throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call(
            "agents-set", ["clear": .array([.string("manager")])], devRoot: devRoot)

        #expect(resp.result?["saved"] == .bool(true))
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.agentsByKind.isEmpty)
    }

    /// `set` echoes the same subtree `get` reports, so a caller can read, edit and
    /// resubmit without a second round trip.
    @Test @MainActor func setEchoesTheSameSubtreeAsGet() async {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let set = await call(
            "agents-set", ["by_kind": .object(["job": .string("claude-code")])], devRoot: devRoot)
        let get = await call("agents-get", devRoot: devRoot)

        #expect(set.result?["agents"] == get.result?["agents"])
    }

    // MARK: - Rejections write nothing

    /// Every decode happens before `mutateConfig` is entered, so a rejection never
    /// takes the lock, never writes, and never bumps mtime (which would push a
    /// spurious "Config reloaded" to every open browser).
    @Test @MainActor func rejectionsLeaveConfigByteIdentical() async throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.agentsByKind = ["review": .claudeCode]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)
        let before = try Data(contentsOf: URL(fileURLWithPath: configPath(devRoot)))

        let cases: [(String, [String: JSONValue])] = [
            ("empty params", [:]),
            ("clear and set the same role", [
                "by_kind": .object(["review": .string("claude-code")]),
                "clear": .array([.string("review")]),
            ]),
            ("unregistered default", ["default_agent_kind": .string(unregisteredKind)]),
            ("unregistered role kind", [
                "by_kind": .object(["work": .string(unregisteredKind)])
            ]),
            ("unknown role name", ["by_kind": .object(["deploy": .string("claude-code")])]),
            ("unknown role in clear", ["clear": .array([.string("deploy")])]),
            ("wrong-typed default", ["default_agent_kind": .bool(true)]),
            ("wrong-typed by_kind", ["by_kind": .string("claude-code")]),
            ("wrong-typed clear", ["clear": .string("work")]),
        ]
        for (label, params) in cases {
            let resp = await call("agents-set", params, devRoot: devRoot)
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(label) must be rejected")
            let after = try Data(contentsOf: URL(fileURLWithPath: configPath(devRoot)))
            #expect(after == before, "\(label) must not write")
        }
    }

    /// The rejection has to name the alternatives — the available set is
    /// binary-dependent and decided at daemon boot, so a user can't infer it.
    @Test @MainActor func unregisteredKindRejectionNamesWhatIsAvailable() async {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call(
            "agents-set", ["default_agent_kind": .string(unregisteredKind)], devRoot: devRoot)

        #expect(resp.error?.message.contains(unregisteredKind) == true)
        #expect(resp.error?.message.contains("claude-code") == true)
    }

    /// Treating an undecodable config as "missing" and falling back to defaults
    /// would silently reset every workspace, job and credential on this write.
    @Test @MainActor func setRefusesToOverwriteAnUndecodableConfig() async throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try FileManager.default.createDirectory(
            atPath: (devRoot as NSString).appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        let corrupt = #"{"workspaces": "not-an-array"}"#
        try corrupt.write(toFile: configPath(devRoot), atomically: true, encoding: .utf8)

        let resp = await call(
            "agents-set", ["default_agent_kind": .string("claude-code")], devRoot: devRoot)

        #expect(resp.error?.code == RPCErrorCode.applicationError)
        #expect(try String(contentsOfFile: configPath(devRoot), encoding: .utf8) == corrupt)
    }
}
