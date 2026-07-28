import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// End-to-end coverage of the `automation-*` handlers behind `crow automation`
/// (CROW-812): the real router, against a real `config.json` in a temp dev root.
///
/// `SettingsRPCSupportTests` pins the pure decode/encode; these pin the parts
/// only the handler can get wrong — that a patch touches exactly the fields it
/// was given across three different config subtrees, that it persists, that
/// unrelated config survives, and that `manager_restart_required` tracks a real
/// change rather than merely a mention.
@Suite struct AutomationHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-automation-\(UUID().uuidString)")
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

    // MARK: - Reads

    @Test @MainActor func getReturnsDefaultsWhenNoConfigExists() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("automation-get", devRoot: devRoot)
        let automation = try #require(resp.result?["automation"]?.objectValue)

        #expect(automation["manager_auto_permission_mode"] == .bool(true))
        #expect(automation["remote_control_enabled"] == .bool(false))
        #expect(automation["auto_respond"]?.objectValue?["respond_to_changes_requested"]
            == .bool(true))
        #expect(automation["defaults"]?.objectValue?["exclude_review_repos"] == .array([]))
        // No config yet is genuinely "defaults apply", not "we couldn't read it".
        #expect(automation["config_readable"] == .bool(true))
    }

    /// `loadConfig` returns nil for both "missing" and "malformed". Six of these
    /// booleans default to `true`, so reporting a fiction as fact would tell a
    /// caller automation is armed when the daemon can't read the file at all.
    @Test @MainActor func getReportsAnUndecodableConfigAsUnreadable() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try writeCorruptConfig(devRoot: devRoot)

        let resp = await call("automation-get", devRoot: devRoot)
        #expect(resp.result?["automation"]?.objectValue?["config_readable"] == .bool(false))
    }

    // MARK: - Patch semantics

    @Test @MainActor func setPatchesOnlyProvidedFields() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.remoteControlEnabled = true
        seed.attributionTrailers = true
        seed.autoRespond.respondToChangesRequested = true
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call(
            "automation-set", ["auto_merge_watcher_enabled": .bool(true)], devRoot: devRoot)

        let automation = try #require(resp.result?["automation"]?.objectValue)
        #expect(automation["auto_merge_watcher_enabled"] == .bool(true))
        #expect(automation["remote_control_enabled"] == .bool(true))

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.autoMergeWatcherEnabled == true)
        #expect(onDisk.remoteControlEnabled == true)
        #expect(onDisk.attributionTrailers == true)
        #expect(onDisk.autoRespond.respondToChangesRequested == true)
    }

    /// Setting `false` must be a real write, not read as "absent" — six of these
    /// default to `true`, so this is the only way to turn them off.
    @Test @MainActor func settingFalseIsAWriteNotANoOp() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = await call("automation-set", [
            "attribution_trailers": .bool(false),
            "respond_to_changes_requested": .bool(false),
            "jobs_auto_permission_mode": .bool(false),
        ], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.attributionTrailers == false)
        #expect(onDisk.autoRespond.respondToChangesRequested == false)
        #expect(onDisk.jobsAutoPermissionMode == false)
    }

    /// Both subtrees this handler writes — top-level and `autoRespond` — in one
    /// call, since a bug in the nesting only shows up here.
    @Test @MainActor func setWritesBothSubtreesAtOnce() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = await call("automation-set", [
            "coder_view_auto_permission_mode": .bool(true),
            "auto_rebase_and_resolve_conflicts": .bool(true),
        ], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.coderViewAutoPermissionMode == true)
        #expect(onDisk.autoRespond.autoRebaseAndResolveConflicts == true)
    }

    /// The whole reason this is a granular RPC rather than a `set-config` blob
    /// round-trip: a settings write must not disturb anything else in the file.
    /// `defaults` is the pointed case — `automation-set` reads that subtree back
    /// out in its response but must never write any of it, board-filter lists
    /// and the local-only `binaries` map alike.
    @Test @MainActor func writesPreserveUnrelatedConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.workspaces = [WorkspaceInfo(
            name: "Corveil", provider: "github", cli: "gh", alwaysInclude: ["corveil/crow"])]
        seed.jobs = [JobConfig(
            name: "nightly", workspace: "Corveil", repo: "corveil/crow",
            prompts: ["triage"], schedule: .interval(seconds: 3600))]
        seed.jiraCredential = JiraCredential(
            username: "a@b.c", tokenRef: "op://vault/jira/token")
        seed.defaults.binaries = ["claude-code": "/opt/homebrew/bin/claude"]
        seed.defaults.branchPrefix = "feature/"
        seed.defaults.excludeReviewRepos = ["corveil/*"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        _ = await call("automation-set", [
            "auto_create_watcher_enabled": .bool(true),
        ], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.autoCreateWatcherEnabled == true)
        #expect(onDisk.defaults.excludeReviewRepos == ["corveil/*"])
        #expect(onDisk.workspaces.map(\.name) == ["Corveil"])
        #expect(onDisk.jobs.map(\.name) == ["nightly"])
        #expect(onDisk.jiraCredential?.tokenRef == "op://vault/jira/token")
        #expect(onDisk.defaults.binaries == ["claude-code": "/opt/homebrew/bin/claude"])
        #expect(onDisk.defaults.branchPrefix == "feature/")
    }

    // MARK: - Board-filter lists (read-only here)

    /// The derived read-only field: the CLI can't see per-workspace excludes any
    /// other way, so without it a caller can't explain why a repo stays hidden.
    @Test @MainActor func getReportsEffectiveExcludeReviewRepos() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.excludeReviewRepos = ["corveil/*"]
        seed.workspaces = [WorkspaceInfo(name: "Acme", excludeReviewRepos: ["acme/legacy"])]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("automation-get", devRoot: devRoot)
        let defaults = try #require(
            resp.result?["automation"]?.objectValue?["defaults"]?.objectValue)
        #expect(defaults["exclude_review_repos"] == .array([.string("corveil/*")]))
        #expect(defaults["effective_exclude_review_repos"]
            == .array([.string("corveil/*"), .string("acme/legacy")]))
    }

    // MARK: - restart_required

    /// `managerAutoPermissionMode` is the one field here that isn't re-read from
    /// disk on the next board tick — it's baked into the Manager terminal's
    /// stored command — so it gets its own signal, reported only on a real change.
    @Test @MainActor func managerRestartRequiredTracksActualChanges() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.managerAutoPermissionMode = true
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let changed = await call(
            "automation-set", ["manager_auto_permission_mode": .bool(false)], devRoot: devRoot)
        #expect(changed.result?["manager_restart_required"] == .bool(true))

        // Re-setting the same value is not a change, so it must not nag.
        let same = await call(
            "automation-set", ["manager_auto_permission_mode": .bool(false)], devRoot: devRoot)
        #expect(same.result?["manager_restart_required"] == .bool(false))

        // Nor should an unrelated field.
        let other = await call(
            "automation-set", ["auto_merge_watcher_enabled": .bool(true)], devRoot: devRoot)
        #expect(other.result?["manager_restart_required"] == .bool(false))
    }

    /// `crowd` re-reads config lazily, so nothing here ever needs a daemon
    /// restart. Reported for symmetry with the other settings verbs.
    @Test @MainActor func crowdRestartIsNeverRequired() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        for params: [String: JSONValue] in [
            ["remote_control_enabled": .bool(true)],
            ["manager_auto_permission_mode": .bool(false)],
            ["auto_create_watcher_enabled": .bool(true)],
            ["respond_to_failed_checks": .bool(true)],
            ["attribution_trailers": .bool(false)],
        ] {
            let resp = await call("automation-set", params, devRoot: devRoot)
            #expect(resp.result?["restart_required"] == .bool(false), "\(params)")
        }
    }

    // MARK: - Wire contract with the CLI

    /// The one seam neither package's own tests can cover: CrowCLI and CrowDaemon
    /// never share a symbol for these param names, so a typo on either side would
    /// compile, pass `AutomationCommandParsingTests` (which checks parsed Swift
    /// properties) *and* pass every test above (which passes params in directly),
    /// while silently dropping the field on the wire.
    ///
    /// This is the exact dictionary `AutomationSet.params` produces with every
    /// flag passed — eleven booleans, no lists — kept in step with
    /// `AutomationCommandParsingTests.automationSetEmitsTheExpectedWireKeys`,
    /// which asserts the CLI emits precisely these keys and no others.
    @Test @MainActor func setAcceptsEveryWireKeyTheCLIEmits() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.excludeReviewRepos = ["old/one"]
        seed.defaults.ignoreReviewLabels = ["old-label"]
        seed.defaults.excludeTicketRepos = ["old/two"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("automation-set", [
            "remote_control_enabled": .bool(true),
            "manager_auto_permission_mode": .bool(false),
            "review_auto_permission_mode": .bool(false),
            "coder_view_auto_permission_mode": .bool(true),
            "jobs_auto_permission_mode": .bool(false),
            "attribution_trailers": .bool(false),
            "auto_create_watcher_enabled": .bool(true),
            "auto_merge_watcher_enabled": .bool(true),
            "respond_to_changes_requested": .bool(false),
            "respond_to_failed_checks": .bool(true),
            "auto_rebase_and_resolve_conflicts": .bool(true),
        ], devRoot: devRoot)

        #expect(resp.error == nil)

        // Every field moved off its default — a dropped key would leave one
        // there and fail here rather than silently succeeding.
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.remoteControlEnabled == true)
        #expect(onDisk.managerAutoPermissionMode == false)
        #expect(onDisk.reviewAutoPermissionMode == false)
        #expect(onDisk.coderViewAutoPermissionMode == true)
        #expect(onDisk.jobsAutoPermissionMode == false)
        #expect(onDisk.attributionTrailers == false)
        #expect(onDisk.autoCreateWatcherEnabled == true)
        #expect(onDisk.autoMergeWatcherEnabled == true)
        #expect(onDisk.autoRespond.respondToChangesRequested == false)
        #expect(onDisk.autoRespond.respondToFailedChecks == true)
        #expect(onDisk.autoRespond.autoRebaseAndResolveConflicts == true)
        // The board-filter lists are `crow defaults`' to write; a stray key here
        // must not touch them.
        #expect(onDisk.defaults.excludeReviewRepos == ["old/one"])
        #expect(onDisk.defaults.ignoreReviewLabels == ["old-label"])
        #expect(onDisk.defaults.excludeTicketRepos == ["old/two"])

        #expect(resp.result?["manager_restart_required"] == .bool(true))
        #expect(resp.result?["restart_required"] == .bool(false))
    }

    // MARK: - Rejections

    @Test @MainActor func setRejectsEmptyParams() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // A no-op write would still rewrite config.json and fire a spurious
        // "Config reloaded" notification in every open browser.
        let resp = await call("automation-set", devRoot: devRoot)
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
        #expect(!FileManager.default.fileExists(
            atPath: (devRoot as NSString).appendingPathComponent(".claude/config.json")))
    }

    /// `crow automation set` cannot emit these — they are `crow defaults`' flags —
    /// but a hand-rolled RPC call could. They must be inert rather than a second
    /// write path into `AppConfig.defaults` with different list semantics.
    @Test @MainActor func setIgnoresDefaultsListParams() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.defaults.excludeReviewRepos = ["keep/me"]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        // Alone they are not "something to set" — the request is rejected.
        let alone = await call("automation-set", [
            "add_exclude_review_repos": .array([.string("sneaky/*")]),
            "clear_ignore_review_labels": .bool(true),
        ], devRoot: devRoot)
        #expect(alone.error?.code == RPCErrorCode.invalidParams)

        // Alongside a real field they are ignored, not applied.
        let riding = await call("automation-set", [
            "auto_merge_watcher_enabled": .bool(true),
            "add_exclude_review_repos": .array([.string("sneaky/*")]),
            "clear_exclude_review_repos": .bool(true),
        ], devRoot: devRoot)
        #expect(riding.error == nil)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.autoMergeWatcherEnabled == true)
        #expect(onDisk.defaults.excludeReviewRepos == ["keep/me"])
    }

    /// A wrong-typed value must fail loudly rather than being read as "absent"
    /// and reported as a successful write that changed nothing.
    @Test @MainActor func setRejectsWrongTypesRatherThanIgnoringThem() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let cases: [[String: JSONValue]] = [
            ["remote_control_enabled": .string("true")],
            ["attribution_trailers": .int(1)],
            ["respond_to_failed_checks": .string("yes")],
            ["auto_create_watcher_enabled": .array([])],
            ["manager_auto_permission_mode": .double(1.0)],
        ]
        for params in cases {
            let resp = await call("automation-set", params, devRoot: devRoot)
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(params)")
        }
    }

    /// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed".
    /// Treating the latter as "missing" and falling back to `AppConfig()` would
    /// silently reset every workspace, job and credential on the next write.
    @Test @MainActor func writeRefusesToOverwriteAnUndecodableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let corrupt = try writeCorruptConfig(devRoot: devRoot)

        let resp = await call(
            "automation-set", ["auto_merge_watcher_enabled": .bool(true)], devRoot: devRoot)

        #expect(resp.error?.code == RPCErrorCode.applicationError)
        // The bad file is left exactly as it was, not replaced with defaults.
        #expect(try String(contentsOfFile: corrupt.path, encoding: .utf8) == corrupt.contents)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeCorruptConfig(devRoot: String) throws -> (path: String, contents: String) {
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            atPath: claudeDir, withIntermediateDirectories: true)
        let path = (claudeDir as NSString).appendingPathComponent("config.json")
        let contents = #"{"workspaces": "not-an-array"}"#
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, contents)
    }
}
