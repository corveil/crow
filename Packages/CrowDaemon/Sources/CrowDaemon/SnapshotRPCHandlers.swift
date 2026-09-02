import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// Live snapshot, scorecard, whole-blob config, and first-run setup.
///
/// Extracted from `makeCommandRouter`'s dictionary literal (CROW-1134).
func makeSnapshotHandlers(
    appState: AppState,
    rebuildScorecard: (@MainActor @Sendable () async -> Void)?,
    devRoot: String
) -> [String: CommandRouter.Handler] {
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134).
    let handlers: [String: CommandRouter.Handler] = [
        // Batched live per-session state (remote-control + PR + PR link).
        // Forwarded to the app when running; with the app down the daemon builds
        // the same map from its OWN appState — prStatus from the board poll, RC
        // flags from the runtime terminal set, and the (possibly memory-only) PR
        // link from `links(for:)`. Matches the app's makeEngineRouter shape so the
        // web shows PR badges wherever the desktop does (CROW-581, M-E).
        //
        // Copy on MainActor, encode off it (CROW-1180). The web polls this every
        // 4s; JSONValue / analytics DTO encoding used to sit inside the same
        // `MainActor.run` and pin the actor that every Unix-socket CLI RPC
        // shares. Same snapshot pattern as `get-state` and
        // `LaunchScaffold.repairStaleHooks` (#892): concurrent applies still
        // serialize on the actor; encoding an immutable copy cannot tear AppState.
        // Memory only — do not await GitHub or other I/O here.
        "list-sessions-live": { _ in
            let snapshots = await MainActor.run {
                snapshotLiveSessions(from: appState)
            }
            return encodeLiveSessions(snapshots)
        },

        // Full render-state snapshot so a rich client (the macOS app) can rebuild
        // its entire AppState in ONE call, then keep it fresh by re-fetching on
        // each EventHub `changed` push. Read-only and always local — the daemon's
        // own AppState is the live view whether or not the desktop app is up, and
        // there is nothing to forward (ADR 0007; CROW-581, Stage 2 / F). The
        // response object *is* a `DaemonStateSnapshot` — the client decodes the
        // whole result into that type.
        "get-state": { _ in
            let snapshot = await MainActor.run { () -> DaemonStateSnapshot in
                // Strip credentials (Jira token, gateway auth headers, web-password
                // hash+salt) before sending state to any authenticated /rpc client —
                // the same treatment get-config applies. Without this, get-state
                // shipped the raw AppConfig secrets over the wire (review: Red 1).
                let safeConfig = ConfigStore.loadConfig(devRoot: devRoot)
                    .map(SettingsSecrets.strippedForTransport)
                return DaemonStateSnapshot(appState: appState, config: safeConfig)
            }
            do {
                guard case .object(let dict) = try JSONValue(encoding: snapshot) else {
                    throw DaemonRPCError.applicationError("state snapshot did not encode to an object")
                }
                return dict
            } catch let error as DaemonRPCError {
                throw error
            } catch {
                throw DaemonRPCError.applicationError("Failed to encode state snapshot: \(error)")
            }
        },

        // Private efficiency scorecard (ADR 0008; web parity #721). The web has
        // no Swift value types, so we build the ONE Core `ScorecardModel.build(...)`
        // here — off `appState.analyticsSnapshots` + `appState.prAttributions` —
        // and ship its flattened `ScorecardDTO`. Building the model server-side is
        // the single source of truth for the grade/throughput/combined/baseline —
        // there is no JS re-implementation of the grading to keep in sync.
        // Read-only and always local (same posture as get-state).
        "get-scorecard": { _ in
            let dto = await MainActor.run { () -> ScorecardDTO in
                let model = ScorecardModel.build(
                    snapshots: Array(appState.analyticsSnapshots.values),
                    attributions: Array(appState.prAttributions.values),
                    now: Date(),
                    calendar: .current
                )
                let telemetryEnabled = ConfigStore.loadConfig(devRoot: devRoot)?.telemetry.enabled ?? false
                return ScorecardDTO(
                    model,
                    telemetryEnabled: telemetryEnabled,
                    snapshotCount: appState.analyticsSnapshots.count,
                    // Manager rollups ride alongside the model rather than
                    // through it (#767) — see `ScorecardDTO.managerWeeks`.
                    managerUsage: Array(appState.managerUsageWeekly.values),
                    // Names for the per-Manager breakdown (CROW-983). Only
                    // live sessions resolve; a deleted Manager's persisted
                    // weeks still render, just without a name.
                    managerNames: Dictionary(
                        appState.managerSessions.map { ($0.id, $0.name) },
                        uniquingKeysWith: { first, _ in first }),
                    captureStatus: appState.telemetryCaptureStatus
                )
            }
            do {
                guard case .object(let dict) = try JSONValue(encoding: dto) else {
                    throw DaemonRPCError.applicationError("scorecard did not encode to an object")
                }
                return dict
            } catch let error as DaemonRPCError {
                throw error
            } catch {
                throw DaemonRPCError.applicationError("Failed to encode scorecard: \(error)")
            }
        },

        // Manual scorecard rebuild (#745, #767) — backs the web Rebuild button,
        // the port of the desktop's `AppDelegate.rebuildScorecard()`. Backfills
        // snapshots for sessions recorded before snapshotting existed (without
        // re-running them), recomputes the ungraded Manager weekly rollups, and
        // refreshes the capture-status line. Idempotent, local-only, and a
        // no-op error when telemetry is off (there'd be no DB to read).
        "rebuild-scorecard": { _ in
            guard let rebuildScorecard else {
                throw DaemonRPCError.applicationError(
                    "Rebuilding the scorecard requires telemetry — enable it in Settings and restart crowd")
            }
            await rebuildScorecard()
            return ["rebuilt": .bool(true)]
        },

        // App config (the web Settings modal). Forward to the app when it's
        // running so its `saveSettings` side effects run (AppState mirror,
        // notification settings); read/write `{devRoot}/.claude/config.json`
        // directly when it's off so Settings still work headless (the app picks
        // up the change on next launch). Credential values are stripped on the
        // way out and preserved on the way in — never editable from the browser
        // (CROW-581, desktop-only creds). Only one writer at a time: forward when
        // reachable, else write locally.
        "get-config": { params in
            // Forward to the app when it's reachable AND recognizes the method;
            // otherwise read {devRoot}/.claude/config.json directly. The fallback
            // covers both the app being down (socket error) and an app too old to
            // know get-config (method-not-found) during a daemon-ahead rollout.
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let stripped = SettingsSecrets.strippedForTransport(config)
            guard let data = try? JSONEncoder().encode(stripped),
                  let json = String(data: data, encoding: .utf8) else {
                throw DaemonRPCError.applicationError("Failed to encode config")
            }
            // `configured` mirrors the desktop's first-run gate
            // (`ConfigStore.loadDevRoot() == nil`); `dev_root` itself is never
            // empty (cwd fallback), so it can't detect first-run. `default_dev_root`
            // lets the web wizard prefill step 1 without knowing $HOME (CROW-605).
            let defaultDevRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Dev").path
            return [
                "config": .string(json),
                "dev_root": .string(devRoot),
                "app_running": .bool(false),
                "configured": .bool(ConfigStore.loadDevRoot() != nil),
                "default_dev_root": .string(defaultDevRoot),
                // Host capability: is the VS Code `code` CLI installed? Gates the
                // web "Open in VS Code" button, mirroring native `vsCodeAvailable`.
                // Computed here (not off `sessionService`) so it's independent of
                // tmux presence (CROW-749).
                "vs_code_available": .bool(SessionService.findVSCodeBinary() != nil),
            ]
        },
        // Non-secret settings write. `defaults.binaries` is held to the same
        // local-direct bar as secret writes — the `/rpc` WebSocket handler rejects
        // that field change from non-local peers before this runs (review Yellow).
        // Scheduled `jobs` are NOT gated (CROW-665): an authenticated remote
        // session may edit them. Unix-socket / CLI callers are always local.
        "set-config": { params in
            guard let json = params["config"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let incoming = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                throw DaemonRPCError.invalidParams("config must be a valid AppConfig JSON string")
            }
            // The browser can't see or change credentials, so keep whatever is
            // already on disk (nil-current drops any credential shell — see
            // SettingsSecrets). Load+save under the shared lock so a concurrent
            // web-password-set / gateway-set / onJobRan can't clobber this
            // write (review #10).
            let merged: AppConfig
            do {
                merged = try ConfigStore.withConfigLock {
                    let current = ConfigStore.loadConfig(devRoot: devRoot)
                    var m = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
                    // CROW-2841: a workspace just added from the web arrives with no
                    // gateway (the web can't author one). On a managed / design-partner
                    // install, default each genuinely-new workspace to the org gateway
                    // + session log-sync so the audit plane is true by default — a
                    // no-op for self-hosted OSS, and never for a workspace that already
                    // existed (so a later opt-out sticks).
                    ManagedWorkspaceDefaults.applyToNewWorkspaces(
                        in: &m, previousWorkspaceIDs: Set((current?.workspaces ?? []).map(\.id)))
                    try ConfigStore.saveConfig(m, devRoot: devRoot)
                    return m
                }
            } catch {
                throw DaemonRPCError.applicationError("Failed to save config: \(error.localizedDescription)")
            }
            let stripped = SettingsSecrets.strippedForTransport(merged)
            guard let outData = try? JSONEncoder().encode(stripped),
                  let outJSON = String(data: outData, encoding: .utf8) else {
                throw DaemonRPCError.applicationError("Failed to encode config")
            }
            return ["config": .string(outJSON), "saved": .bool(true)]
        },

        // First-run setup wizard (CROW-605). Scaffolds the chosen dev root,
        // writes config.json + the App Support pointer, then asks the daemon to
        // re-exec so every subsystem that captured `devRoot` at startup adopts
        // the new path. Rejected once a pointer already exists.
        //
        // Local-direct only: the `/rpc` WebSocket handler rejects non-local
        // callers before this runs (review Yellow). Documented here so a future
        // Unix-socket / CLI path doesn't reintroduce a remote write+re-exec.
        "run-setup": { params in
            if ConfigStore.loadDevRoot() != nil {
                throw DaemonRPCError.invalidParams("Already configured — setup wizard is one-shot")
            }
            guard let rawRoot = params["dev_root"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawRoot.isEmpty else {
                throw DaemonRPCError.invalidParams("dev_root required")
            }
            let chosen = expandSetupDevRoot(rawRoot)
            guard !chosen.isEmpty else {
                throw DaemonRPCError.invalidParams("dev_root required")
            }
            guard let json = params["config"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                throw DaemonRPCError.invalidParams("config must be a valid AppConfig JSON string")
            }
            do {
                try ConfigStore.withConfigLock {
                    try Scaffolder(devRoot: chosen).scaffold(
                        workspaceNames: config.workspaces.map(\.name))
                    try ConfigStore.saveConfig(config, devRoot: chosen)
                    try ConfigStore.saveDevRoot(chosen)
                }
            } catch {
                throw DaemonRPCError.applicationError(
                    "Setup failed: \(error.localizedDescription)")
            }
            CrowDaemon.requestReexec()
            return ["ok": .bool(true), "dev_root": .string(chosen)]
        },
    ]
    return handlers
}

/// Expand a wizard-supplied `dev_root`: leading `~` → home; relative paths
/// resolve under home. Absolute paths pass through unchanged (CROW-605).
private func expandSetupDevRoot(_ raw: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if raw == "~" { return home }
    if raw.hasPrefix("~/") {
        return (home as NSString).appendingPathComponent(String(raw.dropFirst(2)))
    }
    if (raw as NSString).isAbsolutePath { return raw }
    return (home as NSString).appendingPathComponent(raw)
}

// MARK: - list-sessions-live snapshot (CROW-1180)

/// Immutable per-session copy of the fields `list-sessions-live` ships.
/// Copied on MainActor so JSON encode can run off it without tearing AppState.
struct LiveSessionSnapshot: Sendable {
    struct PRLink: Sendable {
        let label: String
        let url: String
    }

    let id: UUID
    let remoteControlActive: Bool
    let remoteControlAvailable: Bool
    let canDispatch: Bool
    let prStatus: PRStatus?
    let prLink: PRLink?
    let autoMerge: AutoMergeState?
    let autoRebase: AutoRebaseState?
    /// Nil for Managers and for sessions with no live/snapshot aggregate —
    /// absence of the wire key is the empty state (CROW-722).
    let analytics: SessionAnalyticsDTO?
}

/// Walk `appState.sessions` and copy every field the live payload needs.
/// Must stay on MainActor: `SessionHookState` is actor-isolated, and readers
/// need a consistent copy of RC / PR / watcher / analytics inputs.
@MainActor
func snapshotLiveSessions(from appState: AppState) -> [LiveSessionSnapshot] {
    appState.sessions.map { session in
        let id = session.id
        let terminals = appState.terminals(for: id)
        let prLink = appState.links(for: id).first(where: { $0.linkType == .pr })
            .map { LiveSessionSnapshot.PRLink(label: $0.label, url: $0.url) }

        // Per-session analytics strip (CROW-722). Prefer the live in-memory
        // hook aggregate (open sessions); fall back to the durable end-of-session
        // snapshot (terminal sessions). Mirrors `writeAnalyticsSnapshot`'s own
        // source preference. Never for the Manager, and never an all-zeros
        // aggregate — the web renders the strip only when this key is present.
        let analytics: SessionAnalyticsDTO?
        if !appState.isManagerSession(id) {
            if let live = appState.existingHookState(for: id)?.analytics, !live.isEmpty {
                analytics = SessionAnalyticsDTO(live: live, wallClockDuration: session.wallClockDuration)
            } else if let snapshot = appState.analyticsSnapshots[id.uuidString] {
                analytics = SessionAnalyticsDTO(snapshot: snapshot)
            } else {
                analytics = nil
            }
        } else {
            analytics = nil
        }

        return LiveSessionSnapshot(
            id: id,
            remoteControlActive: terminals.contains { appState.remoteControlActiveTerminals.contains($0.id) },
            remoteControlAvailable: AgentRegistry.shared.agent(for: session.agentKind)?.supportsRemoteControl ?? false,
            // PR quick-actions need a managed terminal to dispatch into —
            // mirrors native `canDispatchQuickAction`. The web disables the
            // quick-action buttons when false (CROW-749).
            canDispatch: terminals.contains { $0.isManaged },
            prStatus: appState.prStatus[id],
            prLink: prLink,
            autoMerge: appState.autoMergeState[id],
            autoRebase: appState.autoRebaseState[id],
            analytics: analytics
        )
    }
}

/// Build the `sessions` JSON object from an already-copied snapshot.
///
/// `nonisolated` is load-bearing: this is the work `sample` used to catch on
/// `com.apple.main-thread` (analytics DTO `JSONValue` encode). Must not hop
/// back to MainActor. JSONValue of an immutable copy cannot tear AppState.
nonisolated func encodeLiveSessions(_ snapshots: [LiveSessionSnapshot]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    out.reserveCapacity(snapshots.count)
    for snap in snapshots {
        var entry: [String: JSONValue] = [
            "remote_control_active": .bool(snap.remoteControlActive),
            "remote_control_available": .bool(snap.remoteControlAvailable),
            "can_dispatch": .bool(snap.canDispatch),
        ]
        entry["pr"] = snap.prStatus.map { .object(prStatusJSON($0)) }
            ?? .object(["has_pr": .bool(false)])
        if let prLink = snap.prLink {
            entry["pr_link"] = .object(["label": .string(prLink.label), "url": .string(prLink.url)])
        }
        // Auto-merge / auto-rebase are siblings of `pr`, not members of it
        // (#888 / #944). Absent key means "nothing to report".
        if let autoMerge = snap.autoMerge {
            entry["auto_merge_state"] = watcherStateJSON(autoMerge)
        }
        if let autoRebase = snap.autoRebase {
            entry["auto_rebase_state"] = watcherStateJSON(autoRebase)
        }
        if let dto = snap.analytics, let encoded = try? JSONValue(encoding: dto) {
            entry["analytics"] = encoded
        }
        out[snap.id.uuidString] = .object(entry)
    }
    return ["sessions": .object(out)]
}

/// Shared `{phase, reason, message, permanent}` wire shape for both watchers.
private func watcherStateJSON(phase: String, reason: String, message: String, permanent: Bool) -> JSONValue {
    .object([
        "phase": .string(phase),
        "reason": .string(reason),
        "message": .string(message),
        "permanent": .bool(permanent),
    ])
}

private func watcherStateJSON(_ state: AutoMergeState) -> JSONValue {
    watcherStateJSON(
        phase: state.phase.rawValue, reason: state.reason,
        message: state.message, permanent: state.permanent)
}

private func watcherStateJSON(_ state: AutoRebaseState) -> JSONValue {
    watcherStateJSON(
        phase: state.phase.rawValue, reason: state.reason,
        message: state.message, permanent: state.permanent)
}
