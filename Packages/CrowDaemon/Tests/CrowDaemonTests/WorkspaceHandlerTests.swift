import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// End-to-end coverage of the `workspace-*` handlers behind `crow workspace`
/// (CROW-809): the real router, against a real `config.json` in a temp dev root.
///
/// `WorkspaceRPCSupportTests` pins the pure decode/encode; these pin the parts
/// only the handler can get wrong — that a write persists, that unrelated config
/// survives it, that the rename/remove guards see real sessions and jobs, and
/// that a no-op edit doesn't touch the file.
@Suite struct WorkspaceHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-workspace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func call(
        _ method: String, _ params: [String: JSONValue] = [:],
        devRoot: String, appState: AppState = AppState()
    ) async -> JSONRPCResponse {
        let router = makeCommandRouter(
            appState: appState, store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
        return await router.handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    private func workspaces(_ devRoot: String) -> [WorkspaceInfo] {
        ConfigStore.loadConfig(devRoot: devRoot)?.workspaces ?? []
    }

    /// A session whose primary worktree sits under `{devRoot}/{workspace}/` —
    /// the only thing that ties a session to a workspace.
    @MainActor
    private func seedSession(in appState: AppState, workspace: String, devRoot: String) {
        let session = Session(name: "__TEST__WorkspaceHandler", kind: .work, agentKind: .claudeCode)
        appState.sessions.append(session)
        appState.worktrees[session.id] = [SessionWorktree(
            sessionID: session.id,
            repoName: "api", repoPath: "\(devRoot)/\(workspace)/api",
            worktreePath: "\(devRoot)/\(workspace)/api-1-feature",
            branch: "feature/x", isPrimary: true)]
    }

    // MARK: - list / get

    @Test @MainActor func listReturnsEmptyWhenNoConfigExists() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("workspace-list", devRoot: devRoot)
        #expect(resp.result?["workspaces"] == .array([]))
        // No config is not the same as an unreadable one.
        #expect(resp.result?["config_readable"] == .bool(true))
    }

    @Test @MainActor func getResolvesByNameCaseInsensitivelyAndByUUID() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let acme = WorkspaceInfo(name: "Acme")
        try ConfigStore.saveConfig(AppConfig(workspaces: [acme]), devRoot: devRoot)

        for ref in ["Acme", "acme", acme.id.uuidString] {
            let resp = await call("workspace-get", ["workspace": .string(ref)], devRoot: devRoot)
            #expect(resp.result?["workspace"]?.objectValue?["name"] == .string("Acme"))
        }
        let missing = await call("workspace-get", ["workspace": .string("Nope")], devRoot: devRoot)
        #expect(missing.error?.message.contains("Unknown workspace") == true)
    }

    @Test @MainActor func getRequiresAWorkspaceSelector() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("workspace-get", ["workspace": .string("  ")], devRoot: devRoot)
        #expect(resp.error?.message.contains("workspace is required") == true)
    }

    // MARK: - add

    @Test @MainActor func addPersistsAWorkspaceWithEveryField() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("workspace-add", [
            "name": .string("Acme"),
            "provider": .string("gitlab"),
            "host": .string("gitlab.acme.io"),
            "task_provider": .string("jira"),
            "jira_site": .string("acme.atlassian.net"),
            "jira_project_key": .string("PROPS"),
            "jira_status_map": .object(["In Progress": .string("In Dev")]),
            "always_include": .array([.string("acme/api")]),
            "session_env": .object(["AWS_PROFILE": .string("dev")]),
        ], devRoot: devRoot)
        #expect(resp.error == nil)

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.name == "Acme")
        #expect(stored.provider == "gitlab")
        #expect(stored.cli == "glab")             // derived, never sent
        #expect(stored.host == "gitlab.acme.io")
        #expect(stored.jiraStatusMap == ["In Progress": "In Dev"])
        #expect(stored.alwaysInclude == ["acme/api"])
        #expect(stored.sessionEnv == ["AWS_PROFILE": "dev"])
    }

    /// The first production enforcement of `WorkspaceInfo.validateName` — the
    /// Settings form checks only "non-blank", so these have all been persistable.
    @Test @MainActor func addEnforcesTheModelNameRules() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)

        for bad in ["", "   ", "a/b", "a:b", ".", "..", "acme", "ACME"] {
            let resp = await call("workspace-add", ["name": .string(bad)], devRoot: devRoot)
            #expect(resp.error != nil, "expected '\(bad)' to be rejected")
        }
        #expect(workspaces(devRoot).count == 1)
    }

    @Test @MainActor func addTrimsTheName() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = await call("workspace-add", ["name": .string("  Acme  ")], devRoot: devRoot)
        #expect(workspaces(devRoot).first?.name == "Acme")
    }

    @Test @MainActor func addLeavesOtherConfigBlocksIntact() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.telemetry = TelemetryConfig(enabled: true, port: 4319, retentionDays: 30)
        seed.jobs = [JobConfig(name: "nightly", workspace: "Other", repo: "acme/api",
                               prompts: ["go"], schedule: .interval(seconds: 60))]
        seed.workspaces = [WorkspaceInfo(name: "Other")]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        _ = await call("workspace-add", ["name": .string("Acme")], devRoot: devRoot)

        let after = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(after.workspaces.count == 2)
        #expect(after.telemetry.port == 4319)
        #expect(after.jobs.count == 1)
    }

    // MARK: - edit

    @Test @MainActor func editPatchesOnlyProvidedFields() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let acme = WorkspaceInfo(name: "Acme", provider: "gitlab", cli: "glab",
                                 host: "old.io", alwaysInclude: ["acme/api"])
        try ConfigStore.saveConfig(AppConfig(workspaces: [acme]), devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "host": .string("new.io"),
        ], devRoot: devRoot)
        #expect(resp.result?["saved"] == .bool(true))

        let stored = try #require(workspaces(devRoot).first)
        #expect(stored.host == "new.io")
        #expect(stored.alwaysInclude == ["acme/api"])   // untouched
        #expect(stored.id == acme.id)                   // identity preserved
    }

    /// A workspace's AI gateway is authored only by `gateway-set` (local-only).
    /// An edit must carry it through untouched — `SettingsSecrets.preservingSecrets`
    /// matches it by workspace id, so losing either loses the credential.
    @Test @MainActor func editPreservesTheStoredGateway() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let gateway = WorkspaceGateway(baseURL: "https://gw.acme.io", customHeaders: ["X-Key": "sk-1"])
        let acme = WorkspaceInfo(name: "Acme", gateway: gateway)
        try ConfigStore.saveConfig(AppConfig(workspaces: [acme]), devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "always_include": .array([.string("acme/api")]),
        ], devRoot: devRoot)

        #expect(workspaces(devRoot).first?.gateway == gateway)
        // …but the response still never carries the header value.
        let object = try #require(resp.result?["workspace"]?.objectValue)
        #expect(object["gateway_set"] == .bool(true))
        #expect(object["gateway_base_url"] == .string("https://gw.acme.io"))
    }

    @Test @MainActor func editRejectsAnEmptyPatch() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)

        let resp = await call("workspace-edit", ["workspace": .string("Acme")], devRoot: devRoot)
        #expect(resp.error?.message.contains("Nothing to edit") == true)

        // `force` is a modifier, not a field.
        let forced = await call("workspace-edit", [
            "workspace": .string("Acme"), "force": .bool(true),
        ], devRoot: devRoot)
        #expect(forced.error?.message.contains("Nothing to edit") == true)
    }

    /// An edit whose values already hold must not rewrite the file: the mtime
    /// bump alone fires a "Config reloaded" notification in every open browser.
    @Test @MainActor func editSkipsTheWriteWhenNothingChanges() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let acme = WorkspaceInfo(name: "Acme", provider: "gitlab", cli: "glab", host: "gitlab.acme.io")
        try ConfigStore.saveConfig(AppConfig(workspaces: [acme]), devRoot: devRoot)
        let path = ConfigStore.configURL(devRoot: devRoot).path
        let before = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "host": .string("gitlab.acme.io"),
        ], devRoot: devRoot)

        #expect(resp.error == nil)
        #expect(resp.result?["saved"] == .bool(false))
        let after = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        #expect(before == after)
    }

    @Test @MainActor func editRejectsFieldsTheProviderNeverReads() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(
            AppConfig(workspaces: [WorkspaceInfo(name: "Acme", provider: "github")]), devRoot: devRoot)

        let host = await call("workspace-edit", [
            "workspace": .string("Acme"), "host": .string("gitlab.acme.io"),
        ], devRoot: devRoot)
        #expect(host.error?.message.contains("GitLab workspaces only") == true)

        let jira = await call("workspace-edit", [
            "workspace": .string("Acme"), "jira_jql": .string("assignee = currentUser()"),
        ], devRoot: devRoot)
        #expect(jira.error?.message.contains("Jira workspaces only") == true)

        // Neither wrote anything.
        #expect(workspaces(devRoot).first?.host == nil)
        #expect(workspaces(devRoot).first?.jiraJQL == nil)
    }

    /// The end-to-end form of the line-injection guard: `workspace-*` is
    /// remote-reachable, so this is the path a `/rpc` peer would actually take —
    /// no `ParsableCommand.validate()` anywhere in it. A newline in a
    /// `session_env` value would become a second `KEY=VALUE` line in
    /// `setup.sh`'s jq read and inject an extra variable into the session's
    /// `settings.local.json`.
    @Test @MainActor func sessionEnvNewlineIsRejectedOverRPC() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"),
            "session_env": .object(["FOO": .string("bar\nEVIL=injected")]),
        ], devRoot: devRoot)

        #expect(resp.error?.message.contains("newline") == true)
        #expect(workspaces(devRoot).first?.sessionEnv == nil)

        // Same guard on the create path.
        let added = await call("workspace-add", [
            "name": .string("Other"),
            "session_env": .object(["FOO": .string("bar\nEVIL=injected")]),
        ], devRoot: devRoot)
        #expect(added.error != nil)
        #expect(workspaces(devRoot).count == 1)
    }

    /// The `=` half of the same delimiter contract, over the same remote-reachable
    /// path. `setup.sh` splits each flattened entry at the first `=`, so a key
    /// carrying one is stored as `FOO=BAR` and read back as `FOO`.
    @Test @MainActor func sessionEnvKeyWithEqualsIsRejectedOverRPC() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"),
            "session_env": .object(["FOO=BAR": .string("baz")]),
        ], devRoot: devRoot)

        #expect(resp.error?.message.contains("'='") == true)
        #expect(workspaces(devRoot).first?.sessionEnv == nil)
    }

    /// `crow workspace edit --workspace X --jira-status-ready ""` on a workspace
    /// that has since left Jira. Clearing a stranded value must stay possible —
    /// the coherence check refuses *writes* to a field the workspace won't read,
    /// not the removal of one already there.
    @Test @MainActor func strandedJiraStatusEntryCanStillBeCleared() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let acme = WorkspaceInfo(
            name: "Acme", provider: "github",
            jiraStatusMap: ["Ready": "To Do", "Done": "Closed"])
        try ConfigStore.saveConfig(AppConfig(workspaces: [acme]), devRoot: devRoot)

        let cleared = await call("workspace-edit", [
            "workspace": .string("Acme"),
            "jira_status_map": .object(["Ready": .string("")]),
        ], devRoot: devRoot)
        #expect(cleared.error == nil)
        #expect(workspaces(devRoot).first?.jiraStatusMap == ["Done": "Closed"])

        // A real value in the same field is still refused.
        let written = await call("workspace-edit", [
            "workspace": .string("Acme"),
            "jira_status_map": .object(["Ready": .string("To Do")]),
        ], devRoot: devRoot)
        #expect(written.error?.message.contains("Jira workspaces only") == true)
    }

    // MARK: - rename guard

    @Test @MainActor func renameSucceedsWhenNothingReferencesTheWorkspace() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "name": .string("Acme2"),
        ], devRoot: devRoot)

        #expect(resp.error == nil)
        #expect(resp.result?["renamed_from"] == .string("Acme"))
        #expect(resp.result?["orphaned_sessions"] == .int(0))
        #expect(workspaces(devRoot).first?.name == "Acme2")
    }

    @Test @MainActor func renameRefusesWhenSessionsOrJobsReferenceTheWorkspace() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig(workspaces: [WorkspaceInfo(name: "Acme")])
        seed.jobs = [JobConfig(name: "nightly", workspace: "Acme", repo: "acme/api",
                               prompts: ["go"], schedule: .interval(seconds: 60))]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)
        let appState = AppState()
        seedSession(in: appState, workspace: "Acme", devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "name": .string("Acme2"),
        ], devRoot: devRoot, appState: appState)

        let message = try #require(resp.error?.message)
        #expect(message.contains("1 session"))
        #expect(message.contains("1 job"))
        #expect(message.contains("force"))
        #expect(workspaces(devRoot).first?.name == "Acme")   // unchanged
    }

    @Test @MainActor func renameProceedsWithForceAndReportsWhatItOrphaned() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig(workspaces: [WorkspaceInfo(name: "Acme")])
        seed.jobs = [JobConfig(name: "nightly", workspace: "Acme", repo: "acme/api",
                               prompts: ["go"], schedule: .interval(seconds: 60))]
        try ConfigStore.saveConfig(seed, devRoot: devRoot)
        let appState = AppState()
        seedSession(in: appState, workspace: "Acme", devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "name": .string("Acme2"), "force": .bool(true),
        ], devRoot: devRoot, appState: appState)

        #expect(resp.error == nil)
        #expect(resp.result?["orphaned_sessions"] == .int(1))
        #expect(resp.result?["orphaned_jobs"] == .int(1))
        #expect(workspaces(devRoot).first?.name == "Acme2")
    }

    /// A non-rename edit is never guarded — only the name is the link.
    @Test @MainActor func nonRenameEditIsNotGuarded() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(
            AppConfig(workspaces: [WorkspaceInfo(name: "Acme", provider: "gitlab", cli: "glab")]),
            devRoot: devRoot)
        let appState = AppState()
        seedSession(in: appState, workspace: "Acme", devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "host": .string("gitlab.acme.io"),
        ], devRoot: devRoot, appState: appState)
        #expect(resp.error == nil)
        #expect(resp.result?["renamed_from"] == nil)
    }

    /// Re-stating the workspace's own name is not a rename, so it must not trip
    /// the guard.
    @Test @MainActor func restatingTheSameNameIsNotARename() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)
        let appState = AppState()
        seedSession(in: appState, workspace: "Acme", devRoot: devRoot)

        let resp = await call("workspace-edit", [
            "workspace": .string("Acme"), "name": .string("Acme"),
        ], devRoot: devRoot, appState: appState)
        #expect(resp.error == nil)
        #expect(resp.result?["saved"] == .bool(false))
    }

    // MARK: - remove

    @Test @MainActor func removeDeletesTheEntryAndReportsWhatItKept() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let acme = WorkspaceInfo(
            name: "Acme",
            gateway: WorkspaceGateway(baseURL: "https://gw.acme.io", customHeaders: ["X-Key": "sk-1"]))
        try ConfigStore.saveConfig(
            AppConfig(workspaces: [acme, WorkspaceInfo(name: "Other")]), devRoot: devRoot)

        let resp = await call("workspace-remove", ["workspace": .string("Acme")], devRoot: devRoot)

        #expect(resp.result?["removed"] == .bool(true))
        #expect(resp.result?["name"] == .string("Acme"))
        // The credential goes with it, and the directory does not.
        #expect(resp.result?["gateway_discarded"] == .bool(true))
        #expect(resp.result?["worktree_dir_kept"] == .string("\(devRoot)/Acme"))
        #expect(workspaces(devRoot).map(\.name) == ["Other"])
    }

    @Test @MainActor func removeRefusesWhenReferencedAndProceedsWithForce() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(workspaces: [WorkspaceInfo(name: "Acme")]), devRoot: devRoot)
        let appState = AppState()
        seedSession(in: appState, workspace: "Acme", devRoot: devRoot)

        let refused = await call(
            "workspace-remove", ["workspace": .string("Acme")], devRoot: devRoot, appState: appState)
        #expect(refused.error?.message.contains("1 session") == true)
        #expect(workspaces(devRoot).count == 1)

        let forced = await call(
            "workspace-remove", ["workspace": .string("Acme"), "force": .bool(true)],
            devRoot: devRoot, appState: appState)
        #expect(forced.result?["removed"] == .bool(true))
        #expect(forced.result?["orphaned_sessions"] == .int(1))
        #expect(workspaces(devRoot).isEmpty)
    }

    /// A session in a *different* workspace must not block the removal.
    @Test @MainActor func removeIgnoresSessionsInOtherWorkspaces() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(
            AppConfig(workspaces: [WorkspaceInfo(name: "Acme"), WorkspaceInfo(name: "Other")]),
            devRoot: devRoot)
        let appState = AppState()
        seedSession(in: appState, workspace: "Other", devRoot: devRoot)

        let resp = await call(
            "workspace-remove", ["workspace": .string("Acme")], devRoot: devRoot, appState: appState)
        #expect(resp.result?["removed"] == .bool(true))
    }

    // MARK: - Malformed config

    /// A `config.json` that exists but won't decode must never be replaced with
    /// defaults — that would destroy every workspace, job and credential.
    @Test @MainActor func writesRefuseToOverwriteAnUndecodableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let url = ConfigStore.configURL(devRoot: devRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        for method in ["workspace-add", "workspace-edit", "workspace-remove"] {
            let resp = await call(method, [
                "name": .string("Acme"), "workspace": .string("Acme"), "host": .string("h"),
            ], devRoot: devRoot)
            #expect(resp.error != nil, "\(method) should refuse")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }
}
