import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// JSON-RPC errors thrown by the daemon's handlers, carrying the right
/// JSON-RPC error code. Mirrors the app's `AppDelegate.RPCError` (which is not
/// reachable from the headless daemon — it lives in the AppKit target).
enum DaemonRPCError: Error, LocalizedError, RPCErrorCoded {
    case invalidParams(String)
    case applicationError(String)

    var rpcErrorCode: Int {
        switch self {
        case .invalidParams: return RPCErrorCode.invalidParams
        case .applicationError: return RPCErrorCode.applicationError
        }
    }

    var errorDescription: String? {
        switch self {
        case let .invalidParams(message), let .applicationError(message):
            return message
        }
    }
}

/// Forward a write RPC to the desktop app's Unix socket (the source of truth),
/// so the app applies the mutation with all its side effects (Jira transitions,
/// notifications) and the daemon never clobbers its state. Throws
/// `DaemonRPCError` on an app-level error; rethrows the underlying socket error
/// (connection refused → app not running) so callers can fall back to local
/// handling (CROW-581).
/// A ticket/PR URL is sent verbatim as Manager keystrokes, so accept only a
/// plain http(s) URL with no whitespace or control characters — otherwise a
/// crafted url could inject extra submitted lines into the agent (review #4).
/// Shared by `work-on-issue` and `batch-work-on-issues` so the two can't drift.
func isSafeIssueURL(_ url: String) -> Bool {
    guard !url.isEmpty,
          url.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil else { return false }
    return !url.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

/// The `session.status` transitions behind `mark-in-review` / `complete-session`
/// / `set-session-active` (and their `crow` verbs, CROW-816).
///
/// Prefers `SessionService.updateSessionStatus`, which also schedules the
/// analytics snapshot a `.completed` transition is supposed to record. The
/// direct `appState` + `store` write is the fallback for a daemon with no
/// `SessionService` at all — that's the no-tmux host (`CrowDaemon.run()`), not a
/// defensive branch. Must be called on the main actor (`appState` isolation).
@MainActor
func applySessionStatus(
    id: UUID, to status: SessionStatus,
    appState: AppState, store: JSONStore, sessionService: SessionService?
) throws -> [String: JSONValue] {
    guard appState.sessions.contains(where: { $0.id == id }) else {
        throw DaemonRPCError.applicationError("Session not found")
    }
    // `updateSessionStatus` silently skips managers. Surface that instead, so a
    // CLI caller never gets a success receipt for a write that didn't happen.
    guard !appState.isManagerSession(id) else {
        throw DaemonRPCError.applicationError("Manager sessions have no review/complete lifecycle")
    }

    if let sessionService {
        switch status {
        case .inReview: sessionService.setSessionInReview(id: id)
        case .completed: sessionService.completeSession(id: id)
        case .active: sessionService.setSessionActive(id: id)
        default: throw DaemonRPCError.invalidParams("Unsupported lifecycle status: \(status.rawValue)")
        }
    } else {
        let now = Date()
        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].status = status
            appState.sessions[idx].updatedAt = now
        }
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[i].status = status
                data.sessions[i].updatedAt = now
            }
        }
    }
    return SessionLifecycleRPC.statusResult(id: id, status: status)
}

/// The PR-status JSON the app's `makeEngineRouter` emits for a populated
/// `PRStatus` (the `get-pr-status` body and the per-session `pr` entry in
/// `list-sessions-live`). Kept in one place so both daemon handlers stay
/// byte-identical to the app's shape (CROW-581, M-E).
func prStatusJSON(_ pr: PRStatus) -> [String: JSONValue] {
    [
        "has_pr": .bool(true),
        "checks": .string(pr.checksPass.rawValue),
        "review": .string(pr.reviewStatus.rawValue),
        "merge": .string(pr.mergeable.rawValue),
        "is_open": .bool(pr.isOpen),
        "is_merged": .bool(pr.isMerged),
        "ready_to_merge": .bool(pr.isReadyToMerge),
        "has_blockers": .bool(pr.hasBlockers),
        "failed_checks": .array(pr.failedCheckNames.map { .string($0) }),
        // `crow:merge` label presence — the *request* for auto-merge, distinct
        // from `session.auto_merge` (Crow already enabled it). The web row
        // renders them as two indicators (CROW-773).
        "has_merge_label": .bool(pr.hasMergeLabel),
    ]
}

/// Launch a detached GUI process on the daemon host (open the worktree in VS
/// Code / a Terminal window). Fire-and-forget: we don't wait for the app to
/// exit, we only surface a launch failure. Backs the `open-in-vscode` /
/// `open-terminal` RPCs, which restore the retired native `SessionDetailView`'s
/// "Open in VS Code" / "Open Terminal" buttons now that the web UI is the sole
/// client (ADR 0007). The daemon uses a `NoopHostBridge`, so the old
/// `SessionService.openInVSCode/openTerminal` do nothing here — the handler
/// launches the process itself (CROW-749).
func launchHostProcess(_ executable: String, _ arguments: [String]) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    // Reap the child: `code` / `/usr/bin/open` exit almost immediately, and
    // Foundation only harvests the zombie once a `terminationHandler` or
    // `waitUntilExit()` is attached. Without this the long-lived `crowd`
    // daemon would accumulate defunct entries (matches the `terminationHandler`
    // pattern already used in TmuxController / SessionService — review Yellow).
    proc.terminationHandler = { _ in }
    try proc.run()
}

/// Load the config, reporting whether it was actually readable.
///
/// `ConfigStore.loadConfig` returns nil both for "no config yet" (defaults really
/// do apply) and for "present but undecodable" (the defaults are a fiction).
/// `notifications-get` passes the distinction through as `config_readable` so a
/// caller isn't shown invented settings as fact (CROW-813).
func loadConfigReportingReadability(devRoot: String) -> (AppConfig, Bool) {
    if let config = ConfigStore.loadConfig(devRoot: devRoot) { return (config, true) }
    return (AppConfig(), !ConfigStore.configExists(devRoot: devRoot))
}

/// Persist an `AppConfig` mutation under the shared lock. Disk write first so a
/// failed save leaves memory and disk consistent.
///
/// A `config.json` that exists but won't decode is NOT replaced with defaults:
/// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed", and
/// blindly falling back to `AppConfig()` would silently destroy every workspace,
/// job and credential on the next write (CROW-814, found independently by
/// CROW-813 — the notifications verbs are callers too).
@discardableResult
func mutateConfig<T>(devRoot: String, _ transform: (inout AppConfig) throws -> T) throws -> T {
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
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            throw RPCError.applicationError("Failed to persist config change: \(error.localizedDescription)")
        }
        return result
    }
}

/// The engine's pure RPC support (`JobRPC`, `AllowlistRPC`, `SettingsRPC`,
/// `SessionLifecycleRPC`, `NotificationRPC`) throws `RPCError`; map to
/// `DaemonRPCError` for the daemon router. Async so the lifecycle handlers can
/// `await` a main-actor hop inside the mapped body; a synchronous body satisfies
/// it unchanged.
func mapRPCError<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as RPCError {
        switch error {
        case .invalidParams(let msg): throw DaemonRPCError.invalidParams(msg)
        case .applicationError(let msg): throw DaemonRPCError.applicationError(msg)
        }
    } catch let error as DaemonRPCError {
        throw error
    } catch let error as SessionActionError {
        // Unmet precondition or a failed provider call — either way the action
        // did not happen, so the caller must see an error, not a receipt.
        throw DaemonRPCError.applicationError(error.localizedDescription)
    } catch {
        throw DaemonRPCError.applicationError(error.localizedDescription)
    }
}
