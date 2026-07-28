import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// End-to-end coverage of the `defaults-get` / `defaults-set` handlers behind
/// `crow defaults` (CROW-810): the real router, against a real `config.json` in
/// a temp dev root.
///
/// `DefaultsRPCSupportTests` pins the pure decode/encode; these pin the parts
/// only the handler can get wrong — that a patch touches exactly the fields it
/// was given, that it persists, and that unrelated config survives.
@Suite struct DefaultsHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-defaults-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
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

    private func strings(_ value: JSONValue?) -> [String]? {
        value?.arrayValue?.compactMap(\.stringValue)
    }

    // MARK: - Reads

    @Test @MainActor func getReturnsModelDefaultsWhenNoConfigExists() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("defaults-get", devRoot: devRoot)
        let defaults = resp.result?["defaults"]?.objectValue

        #expect(defaults?["provider"] == .string("github"))
        #expect(defaults?["cli"] == .string("gh"))
        #expect(defaults?["branch_prefix"] == .string("feature/"))
        #expect(defaults?["exclude_review_repos"] == .array([]))
        #expect(defaults?["binaries"] == .object([:]))
        // Echoes all nine even though `set` writes seven — hiding the two
        // without a CLI flag would make `get` a worse answer to "what is my
        // config?", and neither has a web editor either.
        #expect(defaults?["mirror_claude_mcp_to_codex"] == .bool(true))
        #expect(defaults?["exclude_dirs"] != nil)
        #expect(defaults?.count == 9)
        // No config on disk, so the defaults genuinely do apply.
        #expect(resp.result?["config_readable"] == .bool(true))
    }

    /// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed".
    /// Unlike `telemetry-get`, this read must not present the model defaults as
    /// fact for a corrupt config — someone debugging why an exclude list isn't
    /// working would be shown an invented empty list.
    @Test @MainActor func getReportsAnUndecodableConfigRatherThanInventingDefaults() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            atPath: claudeDir, withIntermediateDirectories: true)
        try #"{"workspaces": "not-an-array"}"#.write(
            toFile: (claudeDir as NSString).appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8)

        let resp = await call("defaults-get", devRoot: devRoot)
        #expect(resp.result?["config_readable"] == .bool(false))
    }

    // MARK: - Patch semantics

    @Test @MainActor func setPatchesOnlyProvidedFields() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.provider = "github"
        seed.defaults.branchPrefix = "feature/"
        seed.defaults.excludeReviewRepos = ["acme/docs"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("defaults-set", ["branch_prefix": .string("feat/")], devRoot: devRoot)

        let defaults = resp.result?["defaults"]?.objectValue
        #expect(defaults?["branch_prefix"] == .string("feat/"))
        #expect(defaults?["provider"] == .string("github"))
        #expect(defaults?["exclude_review_repos"] == .array([.string("acme/docs")]))
        #expect(resp.result?["saved"] == .bool(true))

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.branchPrefix == "feat/")
        #expect(onDisk.defaults.excludeReviewRepos == ["acme/docs"])
    }

    @Test @MainActor func setAppliesListAddRemoveAndClear() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.excludeReviewRepos = ["acme/docs"]
        seed.defaults.ignoreReviewLabels = ["wip", "blocked"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let added = await call("defaults-set", [
            "add_exclude_review_repos": .array([.string("acme/api"), .string("acme/web")]),
        ], devRoot: devRoot)
        #expect(strings(added.result?["defaults"]?.objectValue?["exclude_review_repos"])
            == ["acme/docs", "acme/api", "acme/web"])

        // Case-insensitive, matching `repoMatchesPatterns`: an exact-match remove
        // would report success while the repo stayed excluded.
        let removed = await call("defaults-set", [
            "remove_exclude_review_repos": .array([.string("ACME/Docs")]),
        ], devRoot: devRoot)
        #expect(strings(removed.result?["defaults"]?.objectValue?["exclude_review_repos"])
            == ["acme/api", "acme/web"])

        let cleared = await call("defaults-set", [
            "clear_ignore_review_labels": .bool(true),
        ], devRoot: devRoot)
        #expect(cleared.result?["defaults"]?.objectValue?["ignore_review_labels"] == .array([]))

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.excludeReviewRepos == ["acme/api", "acme/web"])
        #expect(onDisk.defaults.ignoreReviewLabels.isEmpty)
    }

    /// Each list's trio is scoped to that list: clearing one while adding to
    /// another is a single legitimate call.
    @Test @MainActor func listPatchesAreIndependentPerList() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.excludeReviewRepos = ["acme/docs"]
        seed.defaults.excludeTicketRepos = ["acme/old"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("defaults-set", [
            "clear_exclude_ticket_repos": .bool(true),
            "add_ignore_review_labels": .array([.string("wip")]),
        ], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.excludeTicketRepos.isEmpty)
        #expect(onDisk.defaults.ignoreReviewLabels == ["wip"])
        // Untouched list keeps its value.
        #expect(onDisk.defaults.excludeReviewRepos == ["acme/docs"])
        #expect(resp.error == nil)
    }

    /// The map is shared by `AgentKind`-keyed binary discovery and tool-name-keyed
    /// installers, so a whole-map replace would drop the other caller's keys.
    @Test @MainActor func binariesMergeRatherThanReplace() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.binaries = ["codex": "/opt/codex", "corveil": "/old/corveil"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("defaults-set", [
            "binaries": .object(["corveil": .string("/new/corveil")]),
        ], devRoot: devRoot)
        #expect(resp.result?["defaults"]?.objectValue?["binaries"] == .object([
            "codex": .string("/opt/codex"), "corveil": .string("/new/corveil"),
        ]))

        // Empty value deletes only that key.
        let deleted = await call("defaults-set", [
            "binaries": .object(["corveil": .string("")]),
        ], devRoot: devRoot)
        #expect(deleted.result?["defaults"]?.objectValue?["binaries"]
            == .object(["codex": .string("/opt/codex")]))

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.binaries == ["codex": "/opt/codex"])
    }

    /// Everything the CLI does not write must survive a `defaults` patch —
    /// including the two get-only `ConfigDefaults` fields.
    @Test @MainActor func unrelatedConfigSurvives() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.workspaces = [WorkspaceInfo(name: "ws", excludeReviewRepos: ["ws-only/repo"])]
        seed.jobs = [
            JobConfig(name: "nightly", workspace: "ws", repo: "o/r",
                      prompts: ["do stuff"], schedule: .interval(seconds: 3600)),
        ]
        seed.jiraCredential = JiraCredential(
            username: "a@b.c", tokenRef: "op://vault/item/token")
        seed.notifications.globalMute = true
        seed.telemetry = TelemetryConfig(enabled: true, port: 4319, retentionDays: 30)
        seed.defaults.excludeDirs = ["node_modules", "custom"]
        seed.defaults.mirrorClaudeMCPToCodex = false
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        _ = await call("defaults-set", ["provider": .string("gitlab")], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.provider == "gitlab")
        #expect(onDisk.workspaces.map(\.name) == ["ws"])
        #expect(onDisk.jobs.map(\.name) == ["nightly"])
        #expect(onDisk.jiraCredential?.tokenRef == "op://vault/item/token")
        #expect(onDisk.notifications.globalMute == true)
        #expect(onDisk.telemetry.port == 4319)
        // Get-only fields are not silently reset to their model defaults.
        #expect(onDisk.defaults.excludeDirs == ["node_modules", "custom"])
        #expect(onDisk.defaults.mirrorClaudeMCPToCodex == false)
    }

    /// The board filters on `effectiveExcludeReviewRepos`, which unions the
    /// defaults list with every workspace's own — so clearing the defaults half
    /// does not unhide a repo a workspace excludes. Pin it, because the obvious
    /// reading of `--clear-exclude-review-repos` is "show me everything again",
    /// and the docs have to say otherwise.
    @Test @MainActor func clearingDefaultsDoesNotTouchAWorkspacesOwnExclusions() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.excludeReviewRepos = ["acme/docs"]
        seed.workspaces = [WorkspaceInfo(name: "ws", excludeReviewRepos: ["ws-only/repo"])]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("defaults-set", [
            "clear_exclude_review_repos": .bool(true),
        ], devRoot: devRoot)

        #expect(resp.result?["defaults"]?.objectValue?["exclude_review_repos"] == .array([]))
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.excludeReviewRepos.isEmpty)
        #expect(onDisk.workspaces.first?.excludeReviewRepos == ["ws-only/repo"])
        #expect(onDisk.effectiveExcludeReviewRepos == ["ws-only/repo"])
    }

    // MARK: - Advisories

    @Test @MainActor func restartRequiredOnlyForBinariesChanges() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.binaries = ["corveil": "/opt/corveil"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let live = await call("defaults-set", ["provider": .string("gitlab")], devRoot: devRoot)
        #expect(live.result?["restart_required"] == .bool(false))

        let changed = await call("defaults-set", [
            "binaries": .object(["corveil": .string("/new/corveil")]),
        ], devRoot: devRoot)
        #expect(changed.result?["restart_required"] == .bool(true))

        // Re-setting the same path is a no-op; reporting a restart for it would
        // train users to ignore the flag.
        let same = await call("defaults-set", [
            "binaries": .object(["corveil": .string("/new/corveil")]),
        ], devRoot: devRoot)
        #expect(same.result?["restart_required"] == .bool(false))
    }

    /// Advisory, never a rejection: pointing at a tool you haven't installed yet
    /// is a legitimate flow and `Scaffolder` already skips it. But its only
    /// signal today is an `NSLog` in the daemon's stderr.
    @Test @MainActor func nonExecutableBinariesAreReportedNotRejected() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("defaults-set", [
            "binaries": .object(["corveil": .string("/nonexistent/corveil")]),
        ], devRoot: devRoot)

        #expect(resp.error == nil)
        #expect(resp.result?["saved"] == .bool(true))
        #expect(strings(resp.result?["binaries_not_executable"]) == ["/nonexistent/corveil"])
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.defaults.binaries["corveil"] == "/nonexistent/corveil")

        // A write that names no binary must not report a pre-existing broken
        // entry — that would be noise on an unrelated field's edit.
        let unrelated = await call("defaults-set", ["provider": .string("gitlab")], devRoot: devRoot)
        #expect(strings(unrelated.result?["binaries_not_executable"]) == [])
    }

    /// `provider` and `cli` are an independent pair in `GitManager`, and the web
    /// has no `cli` field at all — so flipping only the provider is a real, and
    /// previously unfixable, half-edit. Report it; don't auto-pair, which would
    /// write a field the caller didn't name.
    @Test @MainActor func providerCLIMismatchIsReportedNotAutoPaired() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let half = await call("defaults-set", ["provider": .string("gitlab")], devRoot: devRoot)
        #expect(half.result?["provider_cli_mismatch"] == .bool(true))
        let afterHalf = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(afterHalf.defaults.cli == "gh", "cli must not be written behind the caller's back")

        let both = await call(
            "defaults-set", ["provider": .string("gitlab"), "cli": .string("glab")], devRoot: devRoot)
        #expect(both.result?["provider_cli_mismatch"] == .bool(false))

        // Computed post-merge, so fixing just the cli against a stored provider clears it.
        let fixed = await call("defaults-set", ["cli": .string("glab")], devRoot: devRoot)
        #expect(fixed.result?["provider_cli_mismatch"] == .bool(false))
    }

    // MARK: - Rejections

    @Test @MainActor func setRejectsEmptyParams() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // A no-op write would still rewrite config.json and fire a spurious
        // "Config reloaded" notification in every open browser.
        let resp = await call("defaults-set", devRoot: devRoot)
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
        #expect(!FileManager.default.fileExists(
            atPath: (devRoot as NSString).appendingPathComponent(".claude/config.json")))
    }

    @Test @MainActor func setRejectsInvalidValues() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let cases: [[String: JSONValue]] = [
            ["provider": .string("bitbucket")],
            ["provider": .int(1)],
            ["cli": .string("hub")],
            ["branch_prefix": .string("bad..prefix")],
            ["branch_prefix": .string("has space/")],
            ["branch_prefix": .bool(true)],
            ["binaries": .object(["crow": .string("/usr/local/bin/crow")])],
            ["binaries": .object(["": .string("/usr/bin/true")])],
            ["binaries": .object(["bin/corveil": .string("/usr/bin/true")])],
            ["binaries": .object(["corveil": .string("relative/corveil")])],
            ["binaries": .object([:])],
            ["binaries": .array([])],
            ["add_exclude_review_repos": .array([])],
            ["add_exclude_review_repos": .array([.int(1)])],
            ["add_exclude_review_repos": .string("acme/docs")],
            ["clear_exclude_review_repos": .string("yes")],
            [
                "clear_exclude_review_repos": .bool(true),
                "add_exclude_review_repos": .array([.string("acme/docs")]),
            ],
        ]
        for params in cases {
            let resp = await call("defaults-set", params, devRoot: devRoot)
            #expect(resp.error?.code == RPCErrorCode.invalidParams,
                    "expected \(params.keys.sorted()) -> \(params) to be rejected")
        }
        // Nothing was persisted by any of them.
        #expect(!FileManager.default.fileExists(
            atPath: (devRoot as NSString).appendingPathComponent(".claude/config.json")))
    }

    /// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed".
    /// Treating the latter as "missing" and falling back to `AppConfig()` would
    /// silently reset every workspace, job and credential on the next write.
    @Test @MainActor func writeRefusesToOverwriteAnUndecodableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            atPath: claudeDir, withIntermediateDirectories: true)
        let configPath = (claudeDir as NSString).appendingPathComponent("config.json")
        let corrupt = #"{"workspaces": "not-an-array"}"#
        try corrupt.write(toFile: configPath, atomically: true, encoding: .utf8)

        let resp = await call("defaults-set", ["provider": .string("gitlab")], devRoot: devRoot)

        #expect(resp.error?.code == RPCErrorCode.applicationError)
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == corrupt)
    }
}
