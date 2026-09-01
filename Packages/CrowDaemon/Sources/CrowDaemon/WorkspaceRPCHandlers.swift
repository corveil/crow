import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// The `workspace-*` methods (CROW-809). Own file (CROW-1134) so
/// `makeCommandRouter` stays a thin assembler; `scripts/check-cli-parity.sh`
/// globs every `*RPCHandlers.swift` file.
///
/// Workspace management for `crow workspace` — the same
/// `AppConfig.workspaces` array the web Settings → Workspaces tab edits, but
/// per-workspace rather than whole-blob: `set-config` ships every workspace,
/// job, gateway URL and credential shell over the wire to change one field, and
/// CrowCLI can't author an `AppConfig` anyway.
///
/// These are the first production callers of `WorkspaceInfo.validateName` — the
/// Settings form checks only "non-blank", so duplicate and path-unsafe names
/// have been persistable all along.
///
/// Deliberately NOT gated in `RPCWebSocketHandler.localOnlyDenial`; the gateway
/// credential is excluded from every payload here. See the ledger there.
func makeWorkspaceHandlers(
    appState: AppState, devRoot: String
) -> [String: CommandRouter.Handler] {
    [
        "workspace-list": { _ in
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return [
                "workspaces": .array(config.workspaces.map(WorkspaceRPC.workspaceJSON)),
                "config_readable": .bool(readable),
            ]
        },
        "workspace-get": { params in
            try await mapRPCError {
                let ref = try workspaceRefParam(params)
                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                return ["workspace": WorkspaceRPC.workspaceJSON(config.workspaces[index])]
            }
        },
        "workspace-add": { params in
            try await mapRPCError {
                guard let rawName = try WorkspaceRPC.patchString(params, "name") else {
                    throw RPCError.invalidParams("name is required")
                }
                let workspace = try mutateConfig(devRoot: devRoot) { config -> WorkspaceInfo in
                    let name = try WorkspaceRPC.validateName(rawName, in: config)
                    // Built from the memberwise init so a new workspace starts at
                    // the model's documented defaults, then patched — rather than
                    // assembling it field by field here, which would silently miss
                    // any field added to `WorkspaceInfo` later.
                    var workspace = WorkspaceInfo(name: name)
                    try WorkspaceRPC.applyPatch(params, to: &workspace, name: name)
                    // CROW-2841: on a managed / design-partner install (connected to
                    // Corveil with a single provisioned org), a new workspace defaults
                    // to that org's gateway + session log-sync so the audit plane is
                    // true by default. Self-hosted OSS has no connection, so this is a
                    // no-op there. An explicit `--upload-session-logs` is honored; the
                    // gateway (a distinct audit item) is always bound.
                    if let managedGateway = config.managedWorkspaceGateway() {
                        let explicitUpload = (params["upload_session_logs"] ?? .null) != .null
                        ManagedWorkspaceDefaults.apply(
                            to: &workspace, gateway: managedGateway, enableUpload: !explicitUpload)
                    }
                    config.workspaces.append(workspace)
                    return workspace
                }
                return ["workspace": WorkspaceRPC.workspaceJSON(workspace), "saved": .bool(true)]
            }
        },
        "workspace-edit": { params in
            try await mapRPCError {
                let ref = try workspaceRefParam(params)
                guard WorkspaceRPC.hasAnyField(params) else {
                    throw RPCError.invalidParams("Nothing to edit — provide at least one field")
                }
                let force = try WorkspaceRPC.flag(params, "force")

                // The rename guard needs AppState (session worktrees), which is
                // main-actor; resolve and count before taking the config lock so
                // no hop happens inside it. This pre-flight read decides whether
                // to guard and gives fast rejection — the authoritative name
                // check runs again under the lock below.
                let rawName = try WorkspaceRPC.patchString(params, "name")
                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                let current = config.workspaces[index]
                let newName = try rawName
                    .map { try WorkspaceRPC.validateName($0, in: config, excludingID: current.id) }
                let renaming = newName.map { $0 != current.name } ?? false

                var references = (sessions: 0, jobs: 0)
                if renaming {
                    references = await MainActor.run {
                        workspaceReferences(
                            to: current.name, appState: appState, config: config, devRoot: devRoot)
                    }
                    if !force, let denial = workspaceReferenceDenial(
                        references, verb: "Renaming", name: current.name, devRoot: devRoot) {
                        throw RPCError.invalidParams(denial)
                    }
                }

                let (changed, workspace) = try mutateConfigIfChanged(devRoot: devRoot) {
                    config -> (changed: Bool, value: WorkspaceInfo) in
                    // Re-resolve *and* re-validate under the lock: another writer
                    // may have reordered the array or claimed the new name since
                    // the pre-flight read above, and name uniqueness is only
                    // meaningful against the config actually being written.
                    let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                    let name = try rawName.map {
                        try WorkspaceRPC.validateName(
                            $0, in: config, excludingID: config.workspaces[index].id)
                    }
                    let changed = try WorkspaceRPC.applyPatch(
                        params, to: &config.workspaces[index], name: name)
                    return (changed, config.workspaces[index])
                }

                var result: [String: JSONValue] = [
                    "workspace": WorkspaceRPC.workspaceJSON(workspace),
                    "saved": .bool(changed),
                ]
                if renaming {
                    result["renamed_from"] = .string(current.name)
                    result["orphaned_sessions"] = .int(references.sessions)
                    result["orphaned_jobs"] = .int(references.jobs)
                }
                return result
            }
        },
        "workspace-remove": { params in
            try await mapRPCError {
                let ref = try workspaceRefParam(params)
                let force = try WorkspaceRPC.flag(params, "force")

                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                let current = config.workspaces[index]
                let references = await MainActor.run {
                    workspaceReferences(
                        to: current.name, appState: appState, config: config, devRoot: devRoot)
                }
                if !force, let denial = workspaceReferenceDenial(
                    references, verb: "Removing", name: current.name, devRoot: devRoot) {
                    throw RPCError.invalidParams(denial)
                }

                let removed = try mutateConfig(devRoot: devRoot) { config -> WorkspaceInfo in
                    let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                    return config.workspaces.remove(at: index)
                }
                return [
                    "removed": .bool(true),
                    "id": .string(removed.id.uuidString),
                    "name": .string(removed.name),
                    // Removal drops the config entry only — `{devRoot}/{name}/`
                    // and its worktrees stay on disk, same as the web UI.
                    "worktree_dir_kept": .string("\(devRoot)/\(removed.name)"),
                    // The workspace's AI-gateway credential goes with it; there is
                    // no undo, so say so rather than letting it vanish quietly.
                    "gateway_discarded": .bool(!(removed.gateway?.isEmpty ?? true)),
                    "orphaned_sessions": .int(references.sessions),
                    "orphaned_jobs": .int(references.jobs),
                ]
            }
        },
    ]
}

/// Like ``mutateConfig(devRoot:_:)`` but skips the disk write when `transform`
/// reports that nothing changed.
///
/// `workspace-edit` takes ~20 optional field flags, so re-running the same
/// invocation (a script converging config, say) is the expected case rather than
/// an odd one. Writing anyway would bump `config.json`'s mtime and fire a
/// "Config reloaded" chime in every open browser for a change that isn't one —
/// the same spurious-notification hazard the settings verbs avoid by rejecting
/// an empty patch. Rejecting isn't right here: the user *did* pass flags, they
/// just already held.
private func mutateConfigIfChanged<T>(
    devRoot: String, _ transform: (inout AppConfig) throws -> (changed: Bool, value: T)
) throws -> (changed: Bool, value: T) {
    try ConfigStore.withConfigLock {
        var config: AppConfig
        if let loaded = ConfigStore.loadConfig(devRoot: devRoot) {
            config = loaded
        } else if ConfigStore.configExists(devRoot: devRoot) {
            throw RPCError.applicationError(
                "config.json exists but could not be decoded — refusing to overwrite it. Fix or move \(ConfigStore.configURL(devRoot: devRoot).path).")
        } else {
            config = AppConfig()
        }
        let result = try transform(&config)
        guard result.changed else { return result }
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            throw RPCError.applicationError("Failed to persist config change: \(error.localizedDescription)")
        }
        return result
    }
}

/// Parse the `workspace: "<name|uuid>"` selector shared by every `workspace-*`
/// method that addresses an existing workspace.
private func workspaceRefParam(_ params: [String: JSONValue]) throws -> String {
    let ref = params["workspace"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !ref.isEmpty else {
        throw RPCError.invalidParams("workspace is required (a workspace name or UUID)")
    }
    return ref
}

/// Count what renaming or removing workspace `name` would orphan.
///
/// Nothing holds a workspace *id*: a session is tied to its workspace only by
/// its worktree living at `{devRoot}/{workspace}/{repo}`, and a job only by the
/// `job.workspace` string. So a rename silently breaks gateway resolution
/// (`SessionService.workspaceGatewayResolved`), code-provider detection (which
/// falls back to GitHub), and job launches — while `Scaffolder` creates a fresh
/// empty directory beside the old populated one. Hence the `--force` gate on
/// both verbs (CROW-809).
///
/// Sessions compare case-insensitively because the on-disk folder's case is the
/// filesystem's to decide; jobs compare exactly, matching `validateJobWorkspace`
/// — a job whose case already differs is already orphaned, not orphaned by this.
///
/// **Best-effort, by design.** The count is taken *before* `withConfigLock`, so a
/// session or job created in the window between counting and writing is orphaned
/// without ever tripping the guard. Closing that would mean re-counting under the
/// lock, and the count reads `AppState` — a main-actor hop inside a held
/// `NSLock`, which is exactly the shape that wedges the daemon (#874). The guard
/// exists to stop a user renaming a workspace they can see is in use, not to be a
/// transactional invariant; a rename racing a session launch is not a case worth
/// deadlock risk to catch. The returned counts are likewise a snapshot.
@MainActor
private func workspaceReferences(
    to name: String, appState: AppState, config: AppConfig, devRoot: String
) -> (sessions: Int, jobs: Int) {
    let lowered = name.lowercased()
    let sessions = appState.worktrees.values.filter { worktrees in
        worktrees.contains {
            SessionService.workspaceName(forWorktreePath: $0.worktreePath, devRoot: devRoot)?
                .lowercased() == lowered
        }
    }.count
    return (sessions, config.jobs.filter { $0.workspace == name }.count)
}

/// Render the reference counts as a refusal, or nil when nothing is referenced.
private func workspaceReferenceDenial(
    _ references: (sessions: Int, jobs: Int), verb: String, name: String, devRoot: String
) -> String? {
    guard references.sessions > 0 || references.jobs > 0 else { return nil }
    var parts: [String] = []
    if references.sessions > 0 {
        parts.append("\(references.sessions) session\(references.sessions == 1 ? "" : "s") (worktrees stay under \(devRoot)/\(name)/)")
    }
    if references.jobs > 0 {
        parts.append("\(references.jobs) job\(references.jobs == 1 ? "" : "s")")
    }
    return "\(verb) '\(name)' orphans \(parts.joined(separator: " and ")). Re-run with force to proceed anyway."
}
