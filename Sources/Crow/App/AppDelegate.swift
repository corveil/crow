import AppKit
import SwiftUI
import CrowClaude
import CrowCodex
import CrowCore
import CrowEngine
import CrowCursor
import CrowGit
import CrowOpenCode
import CrowProvider
import CrowUI
import CrowPersistence
import CrowTerminal
import CrowIPC
import CrowTelemetry

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsWindowCloseObserver: NSObjectProtocol?
    private var aboutWindow: NSWindow?
    private let appState = AppState()
    private var store: JSONStore?
    private var sessionService: SessionService?
    private var socketServer: SocketServer?
    private var issueTracker: IssueTracker?
    private var jobScheduler: JobScheduler?
    /// Connection to a running `crowd` when the app runs in client mode
    /// (env `CROW_CLIENT_MODE`); nil in the default local-engine mode (CROW-581, F).
    private var crowdClient: CrowdClient?
    private var notificationManager: NotificationManager?
    private var autoRespondCoordinator: AutoRespondCoordinator?
    private var allowListService: AllowListService?
    private var appHostBridge: AppHostBridge?
    private var telemetryService: TelemetryService?
    private var devRoot: String?
    private var appConfig: AppConfig?

    /// File descriptor holding the single-instance advisory lock
    /// (`$TMPDIR/crow-instance.lock`). Held open for the whole process so the
    /// `flock` is released only on exit/crash. -1 until acquired. See #330:
    /// the tmux backend now uses a stable socket and outlives the app, so the
    /// sole running instance must be the unambiguous owner of that server.
    private var instanceLockFD: Int32 = -1

    /// Reused for the Jobs repo picker (avoids a fresh instance per form open).
    private let providerManager = ProviderManager()
    /// Cache of expanded `alwaysInclude` repo lists, keyed by workspace name +
    /// its specs, with a short TTL so repeated form opens don't re-hit the
    /// provider CLI.
    private var workspaceRepoCache: [String: (fetchedAt: Date, listing: WorkspaceRepoListing)] = [:]
    private let workspaceRepoCacheTTL: TimeInterval = 300

    /// Tail of the serial review-kickoff queue. Each call to
    /// `enqueueReviewKickoff` awaits the previous tail before doing any work,
    /// so all `createReviewSession` runs are strictly sequential across both
    /// manual batches and auto-review refreshes. See #266 for the race this
    /// replaced.
    private var reviewKickoffTail: Task<Void, Never>?

    /// Tail of the serial corveil-skill-install queue. Settings picker
    /// commits (`SettingsView.onCorveilReinstall`) chain new installs onto
    /// this tail so two rapid picks don't race on `query-corveil.md`
    /// (concurrent `corveil skill install` subprocesses writing the same
    /// `--path`) or on `corveilSkillInstallWarning` (out-of-order
    /// completion clobbering a fresher banner with a stale one). The last
    /// committed path is also the last to write the banner. See the
    /// CROW-490 review for the race this replaced.
    private var corveilInstallTail: Task<String?, Never>?

    /// True when launched as a pure `crowd` client (env `CROW_CLIENT_MODE`): the
    /// app renders state pushed by `crowd` and routes actions to it over RPC
    /// instead of running its own engine, socket-server, tracker, and scheduler.
    /// The strangler flag for Stage F — off by default (local engine) (CROW-581).
    private var isCrowdClientMode: Bool {
        ProcessInfo.processInfo.environment["CROW_CLIENT_MODE"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must be the very first call so the next exit (graceful or not)
        // lands somewhere readable. Also redirects stderr so Swift runtime
        // traps (`fatalError`, `precondition`) and `print` to stderr show up
        // in the crash log instead of being silently dropped when the app is
        // launched from Finder.
        CrashReporter.install()

        // Enforce a single Crow instance per user (#330). The tmux backend now
        // uses a stable socket that outlives the app, so a second instance
        // would otherwise attach to (and fight over) the same persistent
        // server. Bail out with an alert before touching any shared state.
        guard acquireSingleInstanceLock() else {
            presentAlreadyRunningAlert()
            NSApp.terminate(nil)
            return
        }

        // Surface the prior launch's crash (if any) once the app is up.
        // Deferred via async so it doesn't block first-paint.
        if let priorCrashLog = CrashReporter.unseenPriorCrashLog() {
            DispatchQueue.main.async { [weak self] in
                self?.presentPriorCrashAlert(logURL: priorCrashLog)
            }
        }

        // Check for devRoot pointer
        if let root = ConfigStore.loadDevRoot() {
            devRoot = root
            launchMainApp()
        } else {
            showSetupWizard()
        }
    }

    /// Acquire the process-lifetime single-instance lock (#330). Returns true
    /// if we got it (we're the only / owning instance), false if another live
    /// Crow already holds it. The fd is stored in `instanceLockFD` and kept
    /// open for the life of the process; `flock` releases automatically on
    /// exit or crash, so a relaunch always reclaims it.
    private func acquireSingleInstanceLock() -> Bool {
        let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        let lockPath = (tmpdir as NSString).appendingPathComponent("crow-instance.lock")
        // O_CLOEXEC so the lock fd is NOT inherited across exec by the
        // subprocesses Crow spawns (Process/posix_spawn defaults to inheriting
        // fds). A `flock` is released only when *every* descriptor on its
        // open-file-description is closed across all processes — if the
        // persistent tmux daemon (#330) inherited and held this fd, a relaunch
        // would fail to re-acquire the lock even with no Crow alive. Don't rely
        // on the child's own fd cleanup; close on exec unconditionally.
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            // Can't create the lock file — fail open rather than blocking launch.
            NSLog("[CrowTelemetry instance_lock:open_failed errno=\(errno)] proceeding without single-instance guard")
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    /// Native alert shown when a second Crow instance is launched. Crow only
    /// supports one instance per user because the persistent tmux backend is a
    /// single shared server (#330).
    private func presentAlreadyRunningAlert() {
        let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        let lockPath = (tmpdir as NSString).appendingPathComponent("crow-instance.lock")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Crow is already running"
        alert.informativeText = """
            Another Crow instance is already connected to the terminal backend. \
            Only one Crow instance can run at a time — switch to the existing \
            window instead.

            If no Crow is actually running, remove the stale lock file:
            \(lockPath)
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    /// Show an alert pointing the user at the prior launch's crash log.
    /// Dismissing acknowledges the prompt; "Reveal in Finder" opens the
    /// containing directory.
    private func presentPriorCrashAlert(logURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Crow exited unexpectedly last time"
        alert.informativeText = """
            A crash log was written to:
            \(logURL.path)
            """
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
        CrashReporter.acknowledgePriorCrash()
    }

    // MARK: - Review kickoff queue

    /// Enqueue one or more PR URLs for review-session creation, processed
    /// strictly in order on the main actor. Each batch awaits the prior tail
    /// before starting, so a user clicking "Start Review" mid-batch (or an
    /// auto-review refresh landing while a manual batch is in flight) does not
    /// race the previous batch's `appState` writes.
    ///
    /// `selectAfterCreate` is hard-coded false: a kickoff should never yank
    /// the user's detail-pane focus. New review sessions appear in the sidebar
    /// and the user clicks in when they're ready. This is the selection policy
    /// chosen for #266.
    @MainActor
    private func enqueueReviewKickoff(_ urls: [String]) {
        guard !urls.isEmpty, let service = sessionService else { return }
        let previous = reviewKickoffTail
        reviewKickoffTail = Task { @MainActor in
            await previous?.value
            // Yield between kickoffs so a burst of pending PRs spreads
            // across run-loop turns and SwiftUI/AppKit can render between
            // each `createReviewSession` (#293). The first iteration runs
            // immediately so the single-PR case has no added latency.
            for (i, url) in urls.enumerated() {
                if i > 0 { await Task.yield() }
                _ = await service.createReviewSession(prURL: url, selectAfterCreate: false)
            }
        }
    }

    /// Hot-trigger a single `corveil skill install` run for a path the user
    /// just committed in Settings (CROW-490) or clicked Reinstall on
    /// (CROW-491). Mirrors the `reviewKickoffTail` pattern: writes to
    /// `corveilInstallTail` happen on the main actor, and each task awaits
    /// its predecessor before running, so the last-committed path is also
    /// the last to update the banner. The blocking subprocess runs in a
    /// nested `Task.detached` (bounded by `Scaffolder.corveilInstallTimeout`)
    /// so it can't freeze the Settings window, then the result is assigned
    /// back on main. `nil` path is a deliberate no-op for the subprocess
    /// but still clears any stale warning, matching the launch-time
    /// scaffolder's "always assign" semantics at the `onRescaffold` call site.
    ///
    /// Returns the warning produced by this specific call (not whichever
    /// task happens to be tail). Picker-change callers may ignore it;
    /// the Reinstall button awaits it to show inline `✓ / ✗` feedback.
    @MainActor
    @discardableResult
    private func enqueueCorveilInstall(path: String?, devRoot: String) async -> String? {
        let previous = corveilInstallTail
        let myTask = Task<String?, Never> { @MainActor [weak self] in
            // Serialize behind any in-flight install. We don't care about the
            // predecessor's warning — each task reports its own result.
            _ = await previous?.value
            let warning = await Task.detached {
                let scaffolder = Scaffolder(devRoot: devRoot)
                return scaffolder.installCorveilSkill(path)
            }.value
            self?.appState.corveilSkillInstallWarning = warning
            return warning
        }
        corveilInstallTail = myTask
        return await myTask.value
    }

    // MARK: - tmux watchdog alert

    /// Suppress repeated alerts while one is already on screen. Each alert
    /// is modal, so concurrent presentations would stack and feel like a
    /// nag-loop.
    private var tmuxUnresponsiveAlertShowing = false

    /// Called when `TmuxBackend` reports a watchdog timeout. Surface a
    /// modal alert (spec §10.1) offering "Restart tmux server" — confirm
    /// triggers a clean `shutdown()` so the next backend call respawns the
    /// server fresh.
    @MainActor
    private func handleTmuxUnresponsive(error: TmuxError) {
        guard !tmuxUnresponsiveAlertShowing else { return }
        // Crash auto-recovery is already killing + rebuilding the server; a
        // transient timeout during that rebuild must not stack a modal alert
        // on top of it (#588).
        guard !appState.tmuxCrashRecovering else { return }
        tmuxUnresponsiveAlertShowing = true
        defer { tmuxUnresponsiveAlertShowing = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "tmux server is not responding"
        alert.informativeText = """
            A tmux command exceeded the 2-second watchdog and was killed to \
            keep Crow responsive. Your terminals may behave incorrectly until \
            the server is restarted.

            Details: \(error)
            """
        alert.addButton(withTitle: "Restart tmux server")
        alert.addButton(withTitle: "Continue without restart")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            TmuxBackend.shared.shutdown()
            NSLog("[CrowTelemetry tmux:server_restart_by_user]")
        }
    }

    // MARK: - tmux first-run onboarding

    /// Surface a native alert when the required tmux backend can't find a
    /// usable tmux on the host. Spec §11 / PROD #4. The user can:
    ///   - Copy the brew-install command to their clipboard.
    ///   - Open the upstream tmux installation guide.
    ///   - Continue (managed terminals stay unavailable until tmux is installed).
    private func showTmuxNotFoundOnboardingSheet() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "tmux ≥ 3.3 not found"
        alert.informativeText = """
            Crow uses tmux for managed terminals, but no tmux binary ≥ 3.3 was \
            found in /opt/homebrew/bin, /usr/local/bin, or /usr/bin.

            On Macs with Homebrew, install with:

                brew install tmux

            Crow won't change your dotfiles — it runs your usual shell config \
            inside the tmux session.

            Managed terminals won't render until tmux is installed. Restart \
            Crow after installing tmux.
            """
        alert.addButton(withTitle: "Copy `brew install tmux`")
        alert.addButton(withTitle: "Open tmux install guide")
        alert.addButton(withTitle: "Continue")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install tmux", forType: .string)
            // Pasteboard set is silent; alert dismisses on click which is the
            // visible feedback.
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://github.com/tmux/tmux/wiki/Installing") {
                NSWorkspace.shared.open(url)
            }
        default:
            break // Continue without tmux
        }
    }

    // MARK: - Setup Wizard

    private func showSetupWizard() {
        var wizardView = SetupWizardView()
        wizardView.onComplete = { [weak self] devRoot, config in
            self?.completeSetup(devRoot: devRoot, config: config)
        }
        wizardView.onImportCMUX = {
            ConfigStore.importFromCMUX()
        }

        let hostingView = NSHostingView(rootView: wizardView)
        let window = NoTouchBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crow Setup"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeSetup(devRoot: String, config: AppConfig) -> String? {
        do {
            // Save devRoot pointer
            try ConfigStore.saveDevRoot(devRoot)

            // Scaffold directory structure. Don't run the corveil skill install
            // here — `launchMainApp()` runs `scaffold(...)` again immediately
            // below, so doing it twice on first-time setup just fires the
            // subprocess twice with the second result winning.
            let scaffolder = Scaffolder(devRoot: devRoot)
            _ = try scaffolder.scaffold(
                workspaceNames: config.workspaces.map(\.name),
                managerAgentKind: config.agentKind(for: .manager),
                corveilBinaryPath: nil,
                binaryOverrides: config.defaults.binaries
            )

            // Save config
            try ConfigStore.saveConfig(config, devRoot: devRoot)

            // Now launch normally
            self.devRoot = devRoot
            self.appConfig = config
            launchMainApp()
            return nil
        } catch {
            NSLog("[Crow] Setup failed: %@", error.localizedDescription)
            return "Setup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Main App Launch

    private func launchMainApp() {
        guard let devRoot else { return }

        // Load config first so per-agent binary overrides
        // (`defaults.binaries.<kind>`) are visible to the registration gates
        // below — `CodingAgent.findBinary()` consults `BinaryOverrides.shared`
        // before walking PATH (CROW-484).
        let config = appConfig ?? ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
        self.appConfig = config
        BinaryOverrides.shared.set(config.defaults.binaries)

        // Register the Claude Code agent in the shared registry — always
        // present, since the Manager terminal and the default-agent picker
        // both rely on it.
        AgentRegistry.shared.register(ClaudeCodeAgent())

        // Conditionally register the OpenAI Codex agent — only when its
        // binary resolves on PATH (or via an explicit `defaults.binaries.codex`
        // override). Keeps the per-session picker clean for users who haven't
        // installed Codex (CROW-484).
        let codexAgent = OpenAICodexAgent()
        if let codexPath = codexAgent.findBinary() {
            AgentRegistry.shared.register(codexAgent)
            NSLog("[Crow] OpenAI Codex agent registered at %@", codexPath)
        }

        // Conditionally register the Cursor agent on the same gate. The
        // Cursor CLI installs the binary as `agent` (not `cursor`); when
        // it's absent the picker silently stays at the two prior agents.
        let cursorAgent = CursorAgent()
        if let cursorPath = cursorAgent.findBinary() {
            AgentRegistry.shared.register(cursorAgent)
            NSLog("[Crow] Cursor agent registered at %@", cursorPath)
        }

        // Conditionally register the OpenCode agent on the same gate. The
        // OpenCode CLI installs the binary as `opencode`; when it's absent the
        // picker silently stays at the prior agents (CROW-545).
        let openCodeAgent = OpenCodeAgent()
        if let openCodePath = openCodeAgent.findBinary() {
            AgentRegistry.shared.register(openCodeAgent)
            NSLog("[Crow] OpenCode agent registered at %@", openCodePath)
        }

        // Initialize terminal backend (xterm.js + tmux attach).
        // Manager process-exit detection is wired via TmuxBackend's exit
        // monitor, armed by SessionService.ensureManagerSession (#558).
        NSLog("[Crow] Terminal backend ready (xterm.js + tmux)")

        NSLog("[Crow] Config loaded (workspaces: %d)", config.workspaces.count)

        // Configure the tmux backend (#198 → defaulted-on in #301 → the only
        // backend since #303). tmux ≥ 3.3 is required for managed terminals;
        // if none is found we log a warning and surface the first-run
        // onboarding sheet — terminals won't render until tmux is installed.
        //
        // First reap any *legacy* per-PID tmux sockets left by pre-#330 builds
        // (`$TMPDIR/crow-tmux-<pid>.sock` whose owning CrowApp is gone). The
        // reaper deliberately does NOT match the stable socket below, so a
        // healthy persistent server is preserved across this launch. Costs
        // ~50ms when there's nothing to do; idempotent.
        let discoveredTmuxBinary = TmuxDiscovery.discover()
        if let tmuxBinary = discoveredTmuxBinary {
            TmuxOrphanReaper.reap(
                tmuxBinary: tmuxBinary,
                currentPID: ProcessInfo.processInfo.processIdentifier
            )
            // Stable, non-PID socket in $TMPDIR (#330). The tmux server now
            // outlives the app: a clean quit leaves it running (see
            // `applicationWillTerminate`) and this launch re-attaches to it,
            // rebinding the existing sessions via `adoptTerminal`. Keeping the
            // socket under $TMPDIR preserves the "reboot clears everything"
            // property (macOS wipes /var/folders on reboot) — surviving a
            // reboot is an explicit non-goal. The single-instance lock acquired
            // in applicationDidFinishLaunching guarantees we're the sole owner.
            let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
            let socketPath = (tmpdir as NSString)
                .appendingPathComponent("crow-tmux.sock")
            TmuxBackend.shared.configure(
                tmuxBinary: tmuxBinary,
                socketPath: socketPath,
                crowBinDir: (devRoot as NSString).appendingPathComponent(".claude/bin")
            )
            TmuxBackend.shared.onUnresponsive = { [weak self] error in
                Task { @MainActor in self?.handleTmuxUnresponsive(error: error) }
            }
            // Crash auto-recovery (#588). `sessionService` is looked up at
            // fire time, so wiring before the service exists is fine (same
            // pattern as onUnresponsive above).
            TmuxBackend.shared.onCockpitExit = { [weak self] _ in
                Task { @MainActor in self?.sessionService?.handleCockpitClientExit() }
            }
            TmuxBackend.shared.onServerLost = { [weak self] in
                Task { @MainActor in self?.sessionService?.handleTmuxServerCrash() }
            }
            NSLog("[Crow] tmux backend configured: binary=\(tmuxBinary) socket=\(socketPath)")
        } else {
            NSLog("[Crow] no tmux ≥ 3.3 found — managed terminals are unavailable until tmux is installed")
            showTmuxNotFoundOnboardingSheet()
        }

        // Update skills and CLAUDE.md on every launch
        let scaffolder = Scaffolder(devRoot: devRoot)
        do {
            let result = try scaffolder.scaffold(
                workspaceNames: config.workspaces.map(\.name),
                managerAgentKind: config.agentKind(for: .manager),
                corveilBinaryPath: config.defaults.binaries["corveil"],
                binaryOverrides: config.defaults.binaries
            )
            appState.corveilSkillInstallWarning = result.warning
        } catch {
            NSLog("[Crow] Scaffold update failed: %@", error.localizedDescription)
        }

        // Settings → Corveil CLI → "Reinstall skill" (issue #491) reuses
        // the existing `onCorveilReinstall` hook wired in `showSettings`,
        // which already routes through `enqueueCorveilInstall` so the
        // button click serializes correctly against any in-flight picker
        // commit (CROW-490). No separate AppState callback needed.


        // Codex-specific dev-root and global config — only when Codex is
        // registered. AGENTS.md goes into devRoot; hooks.json + config.toml
        // go into ~/.codex (or $CODEX_HOME). All idempotent; safe to re-run.
        if AgentRegistry.shared.agent(for: .codex) != nil {
            do {
                try CodexScaffolder.scaffold(devRoot: devRoot)
            } catch {
                NSLog("[Crow] Codex scaffold failed: %@", error.localizedDescription)
            }
            if let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: devRoot) {
                let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                    ?? NSString(string: "~/.codex").expandingTildeInPath
                do {
                    try CodexHookConfigWriter.installGlobalConfig(codexHome: codexHome, crowPath: crowPath)
                    try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome, crowPath: crowPath)
                } catch {
                    NSLog("[Crow] Codex global config install failed: %@", error.localizedDescription)
                }
            }
        }

        // Cursor-specific dev-root and global config — only when Cursor
        // is registered. AGENTS.md is the same file Codex writes; both
        // scaffolders are idempotent and preserve the user-edited
        // `## Known Issues / Corrections` section, so co-existence is
        // safe. hooks.json goes into ~/.cursor (or $CURSOR_CONFIG_DIR).
        if AgentRegistry.shared.agent(for: .cursor) != nil {
            do {
                try CursorScaffolder.scaffold(devRoot: devRoot)
            } catch {
                NSLog("[Crow] Cursor scaffold failed: %@", error.localizedDescription)
            }
            if let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: devRoot) {
                let cursorHome = ProcessInfo.processInfo.environment["CURSOR_CONFIG_DIR"]
                    ?? NSString(string: "~/.cursor").expandingTildeInPath
                do {
                    try CursorHookConfigWriter.installGlobalConfig(cursorHome: cursorHome, crowPath: crowPath)
                } catch {
                    NSLog("[Crow] Cursor global config install failed: %@", error.localizedDescription)
                }
            }
        }

        // OpenCode-specific dev-root and global config — only when OpenCode is
        // registered. AGENTS.md is the same file Codex/Cursor write (idempotent,
        // preserves the user-edited `## Known Issues / Corrections` section).
        // OpenCode has no command-based hook file; instead we install a JS
        // plugin into ~/.config/opencode/plugins/ (honoring XDG_CONFIG_HOME)
        // that bridges OpenCode's event bus to `crow hook-event` (CROW-545).
        if AgentRegistry.shared.agent(for: .openCode) != nil {
            do {
                try OpenCodeScaffolder.scaffold(devRoot: devRoot)
            } catch {
                NSLog("[Crow] OpenCode scaffold failed: %@", error.localizedDescription)
            }
            if let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: devRoot) {
                // XDG spec: an empty `XDG_CONFIG_HOME` is treated as unset, so
                // fall through to ~/.config/opencode rather than a relative path.
                let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                let configHome = (xdgConfig?.isEmpty == false ? xdgConfig : nil)
                    .map { ($0 as NSString).appendingPathComponent("opencode") }
                    ?? NSString(string: "~/.config/opencode").expandingTildeInPath
                do {
                    try OpenCodeHookConfigWriter.installGlobalConfig(configHome: configHome, crowPath: crowPath)
                } catch {
                    NSLog("[Crow] OpenCode global config install failed: %@", error.localizedDescription)
                }
            }
        }

        // Initialize persistence
        let store = JSONStore()
        self.store = store

        // Mirror the remote-control preference to AppState so hydrate + launch
        // paths can read the current value without a config round-trip. Must be
        // set before hydrateState so the Manager terminal's stored command can
        // be rebuilt to include (or drop) `--rc` before its surface is pre-initialized.
        appState.remoteControlEnabled = config.remoteControlEnabled
        appState.managerAutoPermissionMode = config.managerAutoPermissionMode
        appState.jobsAutoPermissionMode = config.jobsAutoPermissionMode
        appState.coderViewAutoPermissionMode = config.coderViewAutoPermissionMode
        appState.excludeReviewRepos = config.effectiveExcludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels
        appState.defaultAgentKind = config.defaultAgentKind
        appState.agentsByKind = config.agentsByKind

        // Create session service and hydrate state
        let hostBridge = AppHostBridge()
        self.appHostBridge = hostBridge
        let service = SessionService(store: store, appState: appState, telemetryPort: config.telemetry.enabled ? config.telemetry.port : nil, providerManager: providerManager, hostBridge: hostBridge)
        service.hydrateState()
        self.sessionService = service
        NSLog("[Crow] Session state hydrated (%d sessions)", appState.sessions.count)

        // Detect orphaned worktrees (runs async, updates UI when done)
        Task { await service.detectOrphanedWorktrees() }

        // Reap leaked orphan cockpit windows (bare shells that no terminal
        // references) once rehydration's async adoptions have settled (#408).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            service.reapOrphanedCockpitWindows()
        }

        // Check for runtime dependencies (non-blocking)
        Task {
            let missing = await Task.detached {
                let tools = ["gh", "git", "claude", "codex", "agent", "glab", "code"]
                return tools.filter { !ShellEnvironment.shared.hasCommand($0) }
            }.value
            if !missing.isEmpty {
                for tool in missing {
                    NSLog("[Crow] Runtime dependency not found: %@", tool)
                }
                appState.missingDependencies = missing
            }
        }

        // Ensure manager session exists
        service.ensureManagerSession(devRoot: devRoot)

        // ensureManagerSession also arms the TmuxBackend Manager exit monitor
        // that drives the "Manager process exited" banner (#558).

        // Wire closures for UI actions
        appState.onDeleteSession = { [weak self, weak service] id in
            self?.notificationManager?.clearSession(id)
            if let telemetry = self?.telemetryService {
                await telemetry.deleteSessionData(for: id)
            }
            await service?.deleteSession(id: id)
        }
        appState.onCompleteSession = { [weak service] id in
            service?.completeSession(id: id)
        }
        appState.onSetSessionInReview = { [weak service] id in
            service?.setSessionInReview(id: id)
        }
        appState.onSetSessionActive = { [weak service] id in
            service?.setSessionActive(id: id)
        }
        appState.onSetLocked = { [weak service] id, locked in
            service?.setLocked(id: id, locked: locked)
        }

        appState.onLaunchAgent = { [weak service] terminalID in
            service?.launchAgent(terminalID: terminalID)
        }

        appState.onRestartManager = { [weak service] in
            service?.restartManager(devRoot: devRoot)
        }

        appState.onRestartTmuxServer = { [weak service] in
            service?.restartTmuxServer()
        }

        appState.onRetryReadiness = { [weak service] terminalID in
            service?.retryReadiness(terminalID: terminalID)
        }

        appState.onCopyDiagnostics = { [weak service] terminalID in
            service?.copyDiagnostics(terminalID: terminalID)
        }

        // Wire terminal tab management
        appState.onAddTerminal = { [weak service] sessionID in
            service?.addTerminal(sessionID: sessionID)
        }
        appState.onCloseTerminal = { [weak service] sessionID, terminalID in
            service?.closeTerminal(sessionID: sessionID, terminalID: terminalID)
        }
        appState.onRenameTerminal = { [weak service] sessionID, terminalID, name in
            service?.renameTerminal(sessionID: sessionID, terminalID: terminalID, name: name)
        }
        appState.onRenameSession = { [weak service] sessionID, name in
            service?.renameSession(sessionID: sessionID, name: name)
        }

        // Detect VS Code CLI and wire open action
        service.detectVSCode()
        appState.onOpenInVSCode = { [weak service] sessionID in
            service?.openInVSCode(sessionID: sessionID)
        }

        // Wire open terminal action
        appState.onOpenTerminal = { [weak service] sessionID in
            service?.openTerminal(sessionID: sessionID)
        }

        // Wire create-manager action — spawns an additional Manager session
        // (auto-named "Manager N") with its own terminal in the devRoot. The
        // optional `agentKind` is a one-shot pick from the "+" picker (#582);
        // nil defers to the configured Manager-agent default.
        appState.onCreateManager = { [weak self, weak service] agentKind in
            guard let self, let service else { return }
            // Pick the lowest unused "Manager N" so a delete-in-the-middle
            // doesn't produce a duplicate name.
            let existingNames = Set(self.appState.managerSessions.map(\.name))
            var n = 2
            while existingNames.contains("Manager \(n)") { n += 1 }
            let id = service.createManagerSession(name: "Manager \(n)", cwd: devRoot, agentKind: agentKind)
            self.appState.selectedSessionID = id
        }

        // Wire "Work on" issue action — sends issue URL to Manager terminal
        appState.onWorkOnIssue = { [weak self] issueURL in
            guard let self, let managerTerminals = self.appState.terminals[AppState.managerSessionID],
                  let managerTerminal = managerTerminals.first else { return }
            // Type the /crow-workspace command into the Manager terminal.
            // Route through TerminalRouter (#314).
            TerminalRouter.send(managerTerminal, text: "/crow-workspace \(issueURL)\n")
            // Switch to Manager tab
            self.appState.selectedSessionID = AppState.managerSessionID
        }

        // Wire batch "Work on" issues action — sends multiple URLs to Manager terminal
        appState.onBatchWorkOnIssues = { [weak self] issueURLs in
            guard let self, let managerTerminals = self.appState.terminals[AppState.managerSessionID],
                  let managerTerminal = managerTerminals.first else { return }
            let urls = issueURLs.joined(separator: " ")
            // Route through TerminalRouter (#314).
            TerminalRouter.send(managerTerminal, text: "/crow-batch-workspace \(urls)\n")
            self.appState.selectedSessionID = AppState.managerSessionID
        }

        // Wire "Start Review" action — creates review session for a PR.
        // Single-PR kickoffs route through the same serial queue as batches so
        // a rapid double-click can never race two `createReviewSession` calls.
        appState.onStartReview = { [weak self] prURL in
            self?.enqueueReviewKickoff([prURL])
        }

        // Wire batch "Start Review" action — N PRs at once.
        // Previously this spawned one Task per PR (no serialization), which
        // produced the SwiftUI "reentrant layout" / silent-exit crash in #266
        // when N concurrent `createReviewSession` calls all reached the final
        // `appState.selectedSessionID =` write within the same render frame.
        appState.onBatchStartReview = { [weak self] prURLs in
            self?.enqueueReviewKickoff(prURLs)
        }

        // Start issue tracker
        let tracker = IssueTracker(appState: appState, providerManager: providerManager)
        tracker.onNewReviewRequests = { [weak self] newRequests in
            for request in newRequests {
                self?.notificationManager?.notifyReviewRequest(request)
            }
        }

        // Auto-review: fire on every refresh (including the first) so review
        // requests already pending at app launch are picked up. Idempotent
        // via a (request.id, headRefOid) fingerprint cache + the persistent
        // `reviewSessionID` cross-ref. The fingerprint keys SHA so that a
        // PR's next push after a completed review is treated as a fresh
        // round (CROW-290) instead of being blocked by a stale entry.
        var autoReviewedFingerprints: Set<String> = []
        tracker.onReviewRequestsRefreshed = { [weak self] requests in
            guard let self else { return }
            let enabledPatterns = (self.appConfig?.workspaces ?? [])
                .flatMap(\.autoReviewRepos)
            guard !enabledPatterns.isEmpty else { return }

            var pendingURLs: [String] = []
            for request in requests {
                guard repoMatchesPatterns(request.repo, patterns: enabledPatterns) else { continue }
                let fingerprint = "\(request.id)@\(request.headRefOid ?? "")"
                guard !autoReviewedFingerprints.contains(fingerprint) else { continue }

                // Two kickoff conditions:
                //   1. No linked session — fresh request, or A's
                //      viewer-submitted-review path just completed the prior
                //      session so the cross-ref dropped to nil.
                //   2. Linked session is still active but its
                //      `lastReviewedHeadSha` is stale relative to the PR's
                //      current head — fallback re-kick (force-push, or
                //      round-2 commits landed before signal A was observed).
                let linkedSession = request.reviewSessionID.flatMap { id in
                    self.appState.sessions.first(where: { $0.id == id })
                }
                let shaAdvanced = linkedSession != nil
                    && request.headRefOid != nil
                    && linkedSession?.lastReviewedHeadSha != request.headRefOid
                // Authoritative `appState`-side check: a prior tick during an
                // in-flight kickoff may have already created a session even
                // though `request.reviewSessionID` hasn't been repopulated by
                // the next IssueTracker refresh yet (CROW-406). Without this,
                // a watcher tick during the ~10s clone window enqueues a
                // duplicate kickoff for the same PR.
                let existingByPR = self.appState.existingReviewSession(forPRURL: request.url)
                guard (request.reviewSessionID == nil && existingByPR == nil) || shaAdvanced else { continue }

                // B-fallback: tear down the stale round-1 session so the new
                // session doesn't double up in `reviewSessions` for the same
                // PR. The A path doesn't need this — `decideReviewCompletions`
                // already completed the prior session before this point.
                if shaAdvanced, let staleID = request.reviewSessionID {
                    self.appState.onCompleteSession?(staleID)
                }

                autoReviewedFingerprints.insert(fingerprint)
                pendingURLs.append(request.url)
            }
            if !pendingURLs.isEmpty {
                self.enqueueReviewKickoff(pendingURLs)
            }
        }
        tracker.onAutoCreateRequest = { [weak self] issue in
            guard let self else { return }
            // Send `/crow-workspace <url>` to the Manager terminal WITHOUT
            // switching the selected session. The manual "Start Working"
            // button routes through `onWorkOnIssue` (which does select
            // Manager) because the user explicitly asked for that
            // workspace; an auto-pickup is background work and must not
            // yank the user out of their current session (#429). The
            // sidebar still updates and `notifyAutoWorkspaceCreated`
            // already surfaces the event.
            if let managerTerminals = self.appState.terminals[AppState.managerSessionID],
               let managerTerminal = managerTerminals.first {
                TerminalRouter.send(managerTerminal, text: "/crow-workspace \(issue.url)\n")
            }
            self.notificationManager?.notifyAutoWorkspaceCreated(issue)
        }
        tracker.onPRStatusTransitions = { [weak self] transitions in
            guard let self else { return }
            for transition in transitions {
                // Skip the macOS banner on cooldown re-fires: the dispatch
                // re-prompts the agent (the useful part), but a fresh
                // banner every 7 min for the same reviewer submission is
                // pure noise the user already saw the first time.
                if transition.isCooldownReFire { continue }
                if let session = self.appState.sessions.first(where: { $0.id == transition.sessionID }) {
                    self.notificationManager?.notifyPRTransition(transition, session: session)
                }
            }
            self.autoRespondCoordinator?.handle(transitions)
        }
        tracker.onDeleteSession = { [weak self] id in
            do {
                try await self?.appState.onDeleteSession?(id)
            } catch {
                print("[IssueTracker] auto-cleanup delete failed for \(id): \(error)")
            }
        }
        tracker.autoMergeWatcherEnabledProvider = { [weak self] in
            self?.appConfig?.autoMergeWatcherEnabled ?? false
        }
        tracker.autoCreateWatcherEnabledProvider = { [weak self] in
            self?.appConfig?.autoCreateWatcherEnabled ?? false
        }
        tracker.onAutoMergeEnabled = { [weak self] sessionID, prURL, number in
            self?.notificationManager?.notifyAutoMergeEnabled(prURL: prURL, number: number, sessionID: sessionID)
        }
        tracker.autoRebaseAndResolveConflictsProvider = { [weak self] in
            self?.appConfig?.autoRespond.autoRebaseAndResolveConflicts ?? false
        }
        tracker.respondToChangesRequestedProvider = { [weak self] in
            self?.appConfig?.autoRespond.respondToChangesRequested ?? false
        }
        tracker.onAutoRebasePushed = { [weak self] sessionID, _, number in
            self?.notificationManager?.notifyAutoRebasePushed(number: number, sessionID: sessionID)
        }
        tracker.onAutoRebaseConflicts = { [weak self] sessionID, _, number in
            guard let self else { return }
            // Hand conflict resolution to the session's Claude terminal via the
            // existing fixConflicts quick action (rebase + resolve + force-push
            // prompt). Notify regardless so the user knows even if there's no
            // live managed terminal to receive it.
            self.autoRespondCoordinator?.dispatchManual(action: .fixConflicts, sessionID: sessionID)
            self.notificationManager?.notifyAutoRebaseConflicts(number: number, sessionID: sessionID)
        }
        // In client mode crowd runs the tracker + its automations; the app must
        // not also poll or drive them.
        if !isCrowdClientMode { tracker.start() }
        self.issueTracker = tracker

        // Scheduled jobs (CROW-317): fire repo-scoped prompt sets on a schedule.
        let scheduler = JobScheduler(appState: appState, sessionService: service)
        scheduler.jobsProvider = { [weak self] in self?.appConfig?.jobs ?? [] }
        scheduler.devRootProvider = { [weak self] in self?.devRoot }
        scheduler.onJobRan = { [weak self] jobID, ranAt in
            self?.recordJobRun(jobID: jobID, ranAt: ranAt)
        }
        if !isCrowdClientMode { scheduler.start() }
        self.jobScheduler = scheduler

        // Manual "Run now" — fire a job immediately, regardless of enabled/schedule.
        appState.onRunJob = { [weak self] jobID in
            self?.jobScheduler?.runNow(jobID)
        }

        appState.canSetProjectStatusResolver = { [providerManager] session in
            guard let provider = session.provider else { return false }
            return providerManager
                .taskBackend(for: provider)
                .capabilities
                .contains(.projectBoardStatus)
        }

        appState.onMarkInReview = { [weak tracker] id in
            Task { await tracker?.markInReview(sessionID: id) }
        }

        appState.onMarkIssueDone = { [weak tracker] id in
            Task { await tracker?.markIssueDone(sessionID: id) }
        }

        appState.canAddMergeLabelResolver = { [providerManager] session in
            IssueTracker.canAddMergeLabel(session: session, providerManager: providerManager)
        }

        appState.onAddMergeLabel = { [weak tracker] id in
            Task { await tracker?.addMergeLabel(sessionID: id) }
        }

        appState.onManualRefresh = { [weak tracker] in
            Task { await tracker?.refresh() }
        }

        // Initialize notification manager
        let notifManager = NotificationManager(appState: appState, settings: config.notifications)
        self.notificationManager = notifManager
        appHostBridge?.notificationManager = notifManager

        // Initialize auto-respond coordinator. Reads `autoRespond` lazily from
        // `self.appConfig` so toggles take effect on the next transition.
        self.autoRespondCoordinator = AutoRespondCoordinator(
            appState: appState,
            providerManager: providerManager,
            settingsProvider: { [weak self] in
                self?.appConfig?.autoRespond ?? AutoRespondSettings()
            }
        )

        // Wire session-card quick action buttons through the same coordinator.
        appState.onQuickAction = { [weak self] sessionID, action in
            self?.autoRespondCoordinator?.dispatchManual(action: action, sessionID: sessionID)
        }

        // Initialize allow list service
        let allowList = AllowListService(appState: appState, devRoot: devRoot)
        self.allowListService = allowList
        appState.onLoadAllowList = { [weak allowList] in
            allowList?.scan()
        }
        appState.onPromoteToGlobal = { [weak allowList] patterns in
            allowList?.promoteToGlobal(patterns: patterns)
        }

        // Jobs repo picker: expand a workspace's alwaysInclude specs (owner/*,
        // owner/repo) into the repos available from its provider. Results are
        // cached per (workspace, specs) with a short TTL.
        appState.onListWorkspaceRepos = { [weak self] ws in
            guard let self else { return .empty }
            let provider: Provider
            if let p = Provider(rawValue: ws.provider) {
                provider = p
            } else {
                NSLog("[AppDelegate] Workspace '\(ws.name)': unknown provider '\(ws.provider)', defaulting to GitHub")
                provider = .github
            }
            // Key includes provider + host so flipping a workspace's provider
            // (or GitLab host) without changing its specs doesn't return stale,
            // wrong-provider slugs within the TTL window.
            let key = [
                ws.name, ws.provider, ws.host ?? "", ws.alwaysInclude.joined(separator: ","),
            ].joined(separator: "\u{1}")
            if let cached = self.workspaceRepoCache[key],
               Date().timeIntervalSince(cached.fetchedAt) < self.workspaceRepoCacheTTL {
                return cached.listing
            }
            let listing = await self.providerManager.reposForSpecs(
                ws.alwaysInclude, provider: provider, host: ws.host
            )
            self.workspaceRepoCache[key] = (Date(), listing)
            return listing
        }

        // Hydrate mute state from config and wire toggle
        appState.soundMuted = config.notifications.globalMute
        appState.hideSessionDetails = config.sidebar.hideSessionDetails
        appState.onShowSettings = { [weak self] in
            self?.showSettings()
        }
        appState.onSoundMutedChanged = { [weak self] muted in
            self?.appConfig?.notifications.globalMute = muted
            if let settings = self?.appConfig?.notifications {
                self?.notificationManager?.updateSettings(settings)
            }
            if let devRoot = self?.devRoot, let cfg = self?.appConfig {
                try? ConfigStore.saveConfig(cfg, devRoot: devRoot)
            }
        }

        // Client mode: connect to the running crowd and route actions to it,
        // overriding the local-engine callbacks wired above (crowd is the
        // authority; the app renders its pushed state). Terminal-surface ops and
        // host affordances keep their local wiring — terminal I/O stays host-side
        // and the rest lands in Stage 3b (CROW-581, Stage 3/F).
        if isCrowdClientMode {
            let client = CrowdClient(appState: appState)
            crowdClient = client
            wireCrowdClientActions(appState)
            client.connect()
        }

        // Start socket server — local-engine mode only. In client mode crowd owns
        // the socket; the app must not also bind crow.sock.
        if !isCrowdClientMode {
            startSocketServer(store: store, devRoot: devRoot, sessionService: service)
        }

        // Start telemetry receiver if enabled
        if config.telemetry.enabled {
            do {
                let telemetry = try TelemetryService(
                    port: config.telemetry.port,
                    onDataReceived: { [weak self] sessionID in
                        guard let self else { return }
                        Task {
                            guard let analytics = await self.telemetryService?.analytics(for: sessionID) else { return }
                            self.appState.hookState(for: sessionID).analytics = analytics
                        }
                    }
                )
                self.telemetryService = telemetry
                let retentionDays = config.telemetry.retentionDays
                Task {
                    do {
                        try await telemetry.start()
                        await telemetry.pruneOldData(retentionDays: retentionDays)
                    } catch {
                        NSLog("[Crow] Failed to start telemetry service: %@", error.localizedDescription)
                    }
                }
            } catch {
                NSLog("[Crow] Failed to create telemetry service: %@", error.localizedDescription)
            }
        }

        NSLog("[Crow] Main app launch complete — creating window")

        // Create main window
        let contentView = MainContentView(appState: appState)
        let hostingView = NSHostingView(rootView: contentView)

        // Close wizard window if it exists, create main window
        window?.close()

        let mainWindow = NoTouchBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "Crow"
        mainWindow.minSize = NSSize(width: 800, height: 500)
        mainWindow.contentView = hostingView
        // Hard cap window size to the visible screen (menu-bar and dock excluded).
        // This prevents SwiftUI content min-size propagation from growing the
        // window past the screen when tabs with .fixedSize content switch in.
        if let screen = mainWindow.screen ?? NSScreen.main {
            mainWindow.maxSize = screen.visibleFrame.size
        }
        mainWindow.center()
        // Set autosave name after center() so a saved frame takes precedence
        mainWindow.setFrameAutosaveName("MainWindow")
        mainWindow.makeKeyAndOrderFront(nil)
        self.window = mainWindow

        // Update maxSize when displays change (external monitor plug/unplug,
        // resolution change, etc.) so the cap matches the current screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let window = self?.window,
                      let screen = window.screen ?? NSScreen.main else { return }
                window.maxSize = screen.visibleFrame.size
            }
        }

        // Re-arm any tmux readiness watches that timed out while the app was
        // backgrounded. App Nap throttles Crow.app's child processes (tmux
        // server, shell wrapper, user shell) and Crow's own polling Task, so
        // a 30s first-prompt budget can expire even though the shell is fine
        // — it just hasn't run its first precmd yet. Once the app comes
        // forward, the throttle lifts and a fresh watch usually succeeds
        // within a second.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessionService?.reArmStuckReadinessWatches()
            }
        }

        // Set up Settings menu item
        setupMenu()

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Crow", action: #selector(showAbout), keyEquivalent: "")
        appMenu.items.last?.target = self
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        let restartManagerItem = NSMenuItem(title: "Restart Manager", action: #selector(restartManager), keyEquivalent: "")
        restartManagerItem.target = self
        appMenu.addItem(restartManagerItem)
        // No keyEquivalent — recycling the tmux server kills every pane's claude,
        // so keep it menu-only to avoid accidental fires (#375).
        let restartTmuxItem = NSMenuItem(title: "Restart tmux Server", action: #selector(restartTmuxServer), keyEquivalent: "")
        restartTmuxItem.target = self
        appMenu.addItem(restartTmuxItem)
        // Non-destructive — re-sources the bundled tmux conf against the live
        // server. No keyEquivalent for now (#475); can be added if asked.
        let reloadConfigItem = NSMenuItem(title: "Reload Terminal Config", action: #selector(reloadTerminalConfig), keyEquivalent: "")
        reloadConfigItem.target = self
        appMenu.addItem(reloadConfigItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Crow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Crow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // The terminal uses xterm.js in WKWebView; copy/paste is handled by
        // WebKit/tmux mouse bindings. ⌘F is intercepted in XTermSurfaceView.
        // Edit menu selectors below apply to SwiftUI text fields (Settings). (#512)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func restartManager() {
        appState.onRestartManager?()
    }

    @objc private func restartTmuxServer() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restart tmux server?"
        alert.informativeText = """
            This kills the tmux server and every terminal it hosts — including \
            all running Claude sessions — then rebuilds a fresh window for each \
            and relaunches Claude. Use it to recover a stuck or corrupted cockpit.

            Unsaved work in any terminal will be lost.
            """
        alert.addButton(withTitle: "Restart tmux Server")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.onRestartTmuxServer?()
        }
    }

    @objc private func reloadTerminalConfig() {
        NSLog("[CrowTelemetry tmux:config_reload_by_user]")
        let errorText = TmuxBackend.shared.reloadBundledConfig()
        notificationManager?.notifyConfigReloaded(errorText: errorText)
    }

    @objc private func showAbout() {
        if let existing = aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: AboutView())
        let win = NoTouchBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About Crow"
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.contentView = hostingView
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.aboutWindow = win
    }

    @objc private func showSettings() {
        guard let devRoot, let appConfig else { return }

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(
            appState: appState,
            devRoot: devRoot,
            config: appConfig,
            onSave: { [weak self] newDevRoot, newConfig in
                self?.saveSettings(devRoot: newDevRoot, config: newConfig)
            },
            onRescaffold: { [weak self] devRoot in
                let scaffolder = Scaffolder(devRoot: devRoot)
                let cfg = self?.appConfig
                do {
                    let result = try scaffolder.scaffold(
                        workspaceNames: cfg?.workspaces.map(\.name) ?? [],
                        managerAgentKind: cfg?.agentKind(for: .manager) ?? .claudeCode,
                        corveilBinaryPath: cfg?.defaults.binaries["corveil"],
                        binaryOverrides: cfg?.defaults.binaries ?? [:]
                    )
                    // Always assign — clears a stale warning from a prior
                    // launch when the install now succeeds (`result.warning`
                    // is `nil` on success or no-op).
                    self?.appState.corveilSkillInstallWarning = result.warning
                } catch {
                    NSLog("[Crow] Re-scaffold failed: %@", error.localizedDescription)
                    // Replace any existing corveil-install banner with a
                    // fresh "rescaffold failed" message so the user isn't
                    // looking at a stale message from a prior launch.
                    self?.appState.corveilSkillInstallWarning =
                        "Re-scaffold failed: \(error.localizedDescription)"
                }
            },
            onCorveilReinstall: { [weak self] newPath in
                // Hot-trigger a single `corveil skill install` run, serialized
                // through `corveilInstallTail` against any in-flight install
                // (mirrors the `reviewKickoffTail` pattern). Two paths reach
                // this closure: the user committing a new path in the picker
                // (CROW-490) and the user clicking "Reinstall skill" (CROW-491).
                //
                // Read `self.devRoot` live, not the launch-time / show-time
                // capture: `saveSettings(devRoot:config:)` mutates it in the
                // same Settings window, and the stale capture would silently
                // install into the previous devRoot while reporting success.
                guard let self, let currentDevRoot = self.devRoot else { return nil }
                return await self.enqueueCorveilInstall(path: newPath, devRoot: currentDevRoot)
            }
        )

        let hostingView = NSHostingView(rootView: settingsView)
        let win = NoTouchBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.contentView = hostingView
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.settingsWindow = win

        settingsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            // .main queue dispatches on the main thread, but Swift 6 doesn't
            // statically know that's the MainActor's executor. AppDelegate is
            // MainActor-isolated; assume isolation explicitly.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsWindow = nil
                if let token = self.settingsWindowCloseObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.settingsWindowCloseObserver = nil
                }
            }
        }
    }

    private func saveSettings(devRoot: String, config: AppConfig) {
        self.devRoot = devRoot
        self.appConfig = config
        do {
            try ConfigStore.saveDevRoot(devRoot)
        } catch {
            NSLog("[Crow] Failed to save devRoot: %@", error.localizedDescription)
        }
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            NSLog("[Crow] Failed to save config: %@", error.localizedDescription)
        }
        notificationManager?.updateSettings(config.notifications)
        appState.hideSessionDetails = config.sidebar.hideSessionDetails
        appState.remoteControlEnabled = config.remoteControlEnabled
        appState.managerAutoPermissionMode = config.managerAutoPermissionMode
        appState.jobsAutoPermissionMode = config.jobsAutoPermissionMode
        appState.coderViewAutoPermissionMode = config.coderViewAutoPermissionMode
        appState.excludeReviewRepos = config.effectiveExcludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels
        appState.defaultAgentKind = config.defaultAgentKind
        appState.agentsByKind = config.agentsByKind
    }

    /// Record a job's run time in the canonical `appConfig` and persist it, so
    /// the scheduler doesn't replay the job after a restart (CROW-317). Called
    /// by `JobScheduler.onJobRan`.
    private func recordJobRun(jobID: UUID, ranAt: Date) {
        guard var config = appConfig, let devRoot,
              let idx = config.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        config.jobs[idx].lastRunAt = ranAt
        self.appConfig = config
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            NSLog("[Crow] Failed to persist job run time: %@", error.localizedDescription)
        }
    }

    // MARK: - Socket Server

    /// Maximum allowed length for session names.
    private nonisolated static let maxSessionNameLength = Validation.maxSessionNameLength

    /// Validate that a path is within the configured devRoot to prevent path traversal.
    private nonisolated static func isPathWithinDevRoot(_ path: String, devRoot: String) -> Bool {
        Validation.isPathWithinRoot(path, root: devRoot)
    }

    /// Validate a session name contains no control characters and is within length limits.
    private nonisolated static func isValidSessionName(_ name: String) -> Bool {
        Validation.isValidSessionName(name)
    }

    /// Route session/board actions to `crowd` over the client connection instead
    /// of the local engine (client mode). Each maps 1:1 to a daemon RPC. Terminal-
    /// surface ops (add/close/rename terminal, launch/retry agent, restart) and
    /// host affordances (open-in-editor, settings, clipboard, sound) keep their
    /// local wiring — they're host-side or land in Stage 3b (CROW-581, Stage 3/F).
    @MainActor
    private func wireCrowdClientActions(_ appState: AppState) {
        func session(_ id: UUID) -> [String: JSONValue] { ["session_id": .string(id.uuidString)] }

        appState.onCompleteSession = { [weak self] in self?.crowdClient?.send("complete-session", session($0)) }
        appState.onSetSessionActive = { [weak self] in self?.crowdClient?.send("set-session-active", session($0)) }
        appState.onSetSessionInReview = { [weak self] in self?.crowdClient?.send("mark-in-review", session($0)) }
        appState.onMarkInReview = { [weak self] in self?.crowdClient?.send("mark-in-review", session($0)) }
        appState.onMarkIssueDone = { [weak self] in self?.crowdClient?.send("mark-issue-done", session($0)) }
        appState.onAddMergeLabel = { [weak self] in self?.crowdClient?.send("add-merge-label", session($0)) }
        appState.onDeleteSession = { [weak self] id in
            _ = try await self?.crowdClient?.rpc("delete-session", session(id))
        }
        appState.onSetLocked = { [weak self] id, locked in
            self?.crowdClient?.send("set-locked", ["session_id": .string(id.uuidString), "locked": .bool(locked)])
        }
        appState.onRenameSession = { [weak self] id, name in
            self?.crowdClient?.send("rename-session", ["session_id": .string(id.uuidString), "name": .string(name)])
        }
        appState.onCreateManager = { [weak self] kind in
            var params: [String: JSONValue] = [:]
            if let kind { params["agent_kind"] = .string(kind.rawValue) }
            self?.crowdClient?.send("create-manager", params)
        }
        appState.onWorkOnIssue = { [weak self] in self?.crowdClient?.send("work-on-issue", ["url": .string($0)]) }
        appState.onBatchWorkOnIssues = { [weak self] urls in
            for url in urls { self?.crowdClient?.send("work-on-issue", ["url": .string(url)]) }
        }
        appState.onStartReview = { [weak self] in self?.crowdClient?.send("start-review", ["url": .string($0)]) }
        appState.onBatchStartReview = { [weak self] urls in
            for url in urls { self?.crowdClient?.send("start-review", ["url": .string(url)]) }
        }
        appState.onQuickAction = { [weak self] id, action in
            self?.crowdClient?.send("quick-action",
                ["session_id": .string(id.uuidString), "action": .string(action.rawValue)])
        }
        appState.onRunJob = { [weak self] in self?.crowdClient?.send("run-job", ["job_id": .string($0.uuidString)]) }
        appState.onPromoteToGlobal = { [weak self] patterns in
            self?.crowdClient?.send("promote-allowlist", ["patterns": .array(patterns.map { .string($0) })])
        }
        appState.onManualRefresh = { [weak self] in self?.crowdClient?.send("refresh-tickets") }
        appState.onLoadAllowList = { [weak self] in self?.crowdClient?.send("refresh-allowlist") }
    }

    private func startSocketServer(store: JSONStore, devRoot: String, sessionService: SessionService) {
        let capturedAppState = appState
        let capturedStore = store
        let capturedService = sessionService
        let capturedTelemetryPort = sessionService.telemetryPort
        // Set in applicationDidFinishLaunching before this runs (CROW-529: the
        // `transition-ticket` / `resync-jira` verbs drive Jira status moves).
        let capturedTracker = issueTracker

        // Config read/write for the web Settings modal (CROW-581). Captured as
        // @Sendable closures so the handlers can reach `self.appConfig`/`devRoot`/
        // `saveSettings` without a non-Sendable `self` capture in the dict. A web
        // write funnels through `saveSettings` — the exact same path the desktop
        // Settings window uses — so the AppState mirror + notification settings
        // sync identically. Credentials are stripped on read and preserved on
        // write (the browser can't see or change them; see `SettingsSecrets`).
        let loadConfigForRPC: @Sendable () async -> (String, AppConfig)? = { [weak self] in
            await MainActor.run {
                guard let self, let devRoot = self.devRoot, let config = self.appConfig else { return nil }
                return (devRoot, config)
            }
        }
        let applyConfigForRPC: @Sendable (AppConfig) async -> AppConfig? = { [weak self] incoming in
            await MainActor.run {
                guard let self, let devRoot = self.devRoot, let current = self.appConfig else { return nil }
                let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
                self.saveSettings(devRoot: devRoot, config: merged)
                return SettingsSecrets.strippedForTransport(merged)
            }
        }

        let ctx = EngineContext(
            appState: capturedAppState,
            store: capturedStore,
            sessionService: capturedService,
            issueTracker: capturedTracker,
            telemetryPort: capturedTelemetryPort,
            devRoot: devRoot,
            hostBridge: appHostBridge ?? NoopHostBridge(),
            loadConfig: loadConfigForRPC,
            applyConfig: applyConfigForRPC
        )
        let router = makeEngineRouter(ctx)

        let server = SocketServer(router: router)
        do {
            try server.start()
            self.socketServer = server
            NSLog("crow socket server started at: \(server.path)")
        } catch {
            NSLog("Failed to start socket server: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[Crow] Application terminating — beginning cleanup")
        issueTracker?.stop()
        jobScheduler?.stop()
        sessionService?.persistState()
        // Persist config in case settings changed during this session
        if let devRoot, let appConfig {
            try? ConfigStore.saveConfig(appConfig, devRoot: devRoot)
        }
        if let telemetry = telemetryService {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await telemetry.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        socketServer?.stop()
        // Release the single-instance lock as early as possible so a fast
        // quit→relaunch doesn't hit a spurious "Crow is already running" while
        // the slower tmux teardown below finishes (flock would release
        // on exit anyway; explicit + early is best).
        if instanceLockFD >= 0 {
            close(instanceLockFD)
            instanceLockFD = -1
        }
        // Leave the tmux server running so the next launch re-attaches to the
        // existing sessions (#330). The crash-watchdog's "Restart tmux server"
        // path still tears it down via the default `shutdown()`.
        TmuxBackend.shared.shutdown(killServer: false)
        NSLog("[Crow] Cleanup complete")
    }

}

