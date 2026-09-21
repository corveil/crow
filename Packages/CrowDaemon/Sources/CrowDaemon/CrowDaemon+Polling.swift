import CrowCore
import CrowEngine
import CrowPersistence
import Foundation

/// Explicit async poll loops extracted from `CrowDaemon` (CROW-1279). The headless
/// daemon has no `RunLoop.main`, so these replace the collaborators' own Timers.
extension CrowDaemon {
    /// Drive `IssueTracker.refresh()` on an explicit async tick. The tracker's
    /// own `start()` schedules a `Timer` on `RunLoop.main`, which the headless
    /// daemon never runs (`app.runService()` drives NIO event loops, not an
    /// AppKit run loop) — so the Timer would never fire. This does the initial
    /// fetch immediately, then polls on the app's 60s cadence (CROW-581, M-C).
    /// Broadcasts a `changed` nudge after each poll so clients re-fetch the
    /// boards reactively (M-D).
    ///
    /// Also performs the terminal TAKEOVER: on the first tick it restores every
    /// persisted tmux window into this process (so `TerminalRouter.send` /
    /// `isRegistered` works) and ensures the Manager. On a warm crowd restart
    /// the windows are still alive and it adopts them; on a cold start (reboot /
    /// `tmux kill-server`) it recreates them and relaunches each session's agent
    /// (CROW-747). Runs before `refresh()` so automation dispatches have a live,
    /// registered Manager to reach.
    static func startBoardPoll(
        tracker: IssueTracker,
        eventHub: EventHub,
        sessionService: SessionService?,
        appState: AppState,
        devRoot: String
    ) {
        Task {
            var didTakeOver = false
            while !Task.isCancelled {
                // Re-apply config-derived AppState each tick so settings edits
                // (exclude repos, auto-permission modes, remote control) take
                // effect within one poll — before the Manager rebuild and the
                // board refresh below read them (CROW-581).
                await MainActor.run { applyConfigToAppState(appState, devRoot: devRoot) }
                if let sessionService {
                    if !didTakeOver {
                        await MainActor.run {
                            // CROW-747: on a genuine cold start (machine reboot
                            // or `tmux kill-server`) the cockpit session and
                            // every agent are gone; recreate each persisted
                            // terminal's window and relaunch its session's agent
                            // (Claude `--continue`, Cursor/Codex/OpenCode
                            // equivalents). On a warm crowd restart the windows
                            // are still live and this adopts them in place —
                            // gated on the cockpit-alive probe so a live pane is
                            // never re-registered or double-launched.
                            sessionService.takeOverTerminalSurfaces()
                            sessionService.ensureManagerSession(devRoot: devRoot)
                        }
                        didTakeOver = true
                        // Skip reconcile on the takeover tick: the per-terminal
                        // window recreate above is dispatched as async @MainActor
                        // tasks whose fresh bindings haven't landed yet, so
                        // pruning now would drop the very records we're about to
                        // resurrect (CROW-747). Reconcile runs on every
                        // subsequent tick, once those tasks have settled.
                    } else {
                        // Reconcile terminals ↔ tmux windows each tick: prune
                        // terminal records whose window is gone and reap orphaned
                        // windows (targeted-auto, Manager-safe).
                        await MainActor.run { sessionService.reconcileTerminalSurfaces() }
                    }
                }
                // The in-flight half of the refresh is announced by
                // `tracker.onLoadingIssuesChanged` (wired at startup), which
                // fires *after* `isLoadingIssues` is set — nudging from here
                // beforehand would race the flag and fire on skipped polls
                // (CROW-771).
                await tracker.refresh()
                await eventHub.broadcast()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    /// Drive `JobScheduler.tick()` on an explicit async loop (its own Timer needs
    /// a `RunLoop.main` the daemon lacks), on the scheduler's 30s cadence
    /// (CROW-581).
    static func startJobPoll(scheduler: JobScheduler) {
        Task {
            while !Task.isCancelled {
                await MainActor.run { scheduler.tick() }
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    /// Keep the ungraded Manager rollups and the capture-status line moving
    /// while the daemon runs (#767). The desktop app refreshed these only at
    /// launch and on the manual Rebuild — fine for a process restarted daily,
    /// but `crowd` runs for weeks, so without this the current week's Manager
    /// usage would freeze at whatever it was when the daemon started. Hourly:
    /// these are week-grain numbers and the backfill touches the DB.
    static func startScorecardPoll(rebuild: @escaping @MainActor @Sendable () async -> Void) {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                await rebuild()
            }
        }
    }

    /// Drive the multi-harness session-log collector on a 5-minute cadence
    /// (CROW-1056). Delay-first so boot isn't slowed; config is read fresh each
    /// tick (via `ConfigStore` inside `sweep`), so enabling `logSync` in Settings
    /// takes effect within one tick. The whole pass is a cheap no-op while the
    /// feature is off (the default), and every upload is best-effort — a failure
    /// never touches session state.
    static func startLogSyncPoll(appState: AppState, devRoot: String) {
        let collector = LogSyncCollector(devRoot: devRoot)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                await collector.sweep(appState: appState)
            }
        }
    }

    /// Poll `store.json`'s mtime and reload when the desktop app writes it, so
    /// the web UI reflects new sessions/status/terminals/links without a daemon
    /// restart. Cheap (a stat every 2s) and robust against the atomic renames
    /// that break fd-based watching. Broadcasts a `changed` nudge on the hub so
    /// connected clients re-fetch immediately instead of waiting for their own
    /// interval poll (CROW-581, M-D).
    ///
    /// The same tick stats `{devRoot}/.claude/config.json` and pushes a
    /// `configReloaded` notification when it moves — the daemon re-reads config
    /// lazily rather than holding a snapshot, so an mtime change *is* the reload.
    /// One event per real change, covering Settings saves, CLI writes and hand
    /// edits alike (CROW-768).
    static func startStoreReloadPoll(
        store: JSONStore, appState: AppState, eventHub: EventHub, devRoot: String
    ) {
        let configPath = URL(fileURLWithPath: devRoot)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("config.json").path
        func configModified() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
        }
        Task {
            var lastModified = store.storeModificationDate
            // Seeded before the loop so startup never fires a spurious reload.
            var lastConfigModified = configModified()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = store.storeModificationDate
                if now != lastModified {
                    lastModified = now
                    store.reload()
                    await reseed(appState, from: store)
                    await eventHub.broadcast()
                }
                let configNow = configModified()
                if configNow != lastConfigModified {
                    lastConfigModified = configNow
                    await eventHub.broadcastNotification(
                        event: .configReloaded, key: "config",
                        title: "Config reloaded",
                        body: "Settings were reloaded from config.json.")
                }
            }
        }
    }
}
