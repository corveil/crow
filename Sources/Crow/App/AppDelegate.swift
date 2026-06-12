import AppKit
import SwiftUI
import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowGit
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
    private var notificationManager: NotificationManager?
    private var autoRespondCoordinator: AutoRespondCoordinator?
    private var allowListService: AllowListService?
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
    private var workspaceRepoCache: [String: (fetchedAt: Date, repos: [String])] = [:]
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
            break // Continue with Ghostty
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
        let window = NSWindow(
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

        // Initialize libghostty
        NSLog("[Crow] Initializing Ghostty")
        GhosttyApp.shared.initialize()

        NSLog("[Crow] Config loaded (workspaces: %d)", config.workspaces.count)

        // Configure the tmux backend (#198 → defaulted-on in #301 → the only
        // backend since #303). tmux ≥ 3.3 is required for managed terminals;
        // if none is found we log a warning and surface the first-run
        // onboarding sheet — there is no longer a per-terminal Ghostty
        // fallback, so terminals won't render until tmux is installed.
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
            if let crowPath = ClaudeHookConfigWriter.findCrowBinary() {
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
            if let crowPath = ClaudeHookConfigWriter.findCrowBinary() {
                let cursorHome = ProcessInfo.processInfo.environment["CURSOR_CONFIG_DIR"]
                    ?? NSString(string: "~/.cursor").expandingTildeInPath
                do {
                    try CursorHookConfigWriter.installGlobalConfig(cursorHome: cursorHome, crowPath: crowPath)
                } catch {
                    NSLog("[Crow] Cursor global config install failed: %@", error.localizedDescription)
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
        appState.excludeReviewRepos = config.effectiveExcludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels
        appState.defaultAgentKind = config.defaultAgentKind
        appState.agentsByKind = config.agentsByKind

        // Create session service and hydrate state
        let service = SessionService(store: store, appState: appState, telemetryPort: config.telemetry.enabled ? config.telemetry.port : nil, providerManager: providerManager)
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

        // Detect a dead Manager process: Ghostty fires SHOW_CHILD_EXITED when a
        // surface's child exits. If it's the Manager terminal, surface the
        // "Manager process exited" banner so the user can restart it in place.
        GhosttyApp.shared.onChildExited = { [weak self] terminalID, _ in
            guard let self else { return }
            let managerID = AppState.managerSessionID
            if self.appState.terminals(for: managerID).contains(where: { $0.id == terminalID }) {
                NSLog("[Crow] Manager process exited (terminal %@)", terminalID.uuidString)
                self.appState.managerProcessExited = true
            }
        }

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
        // (auto-named "Manager N") with its own Claude-Code terminal in the devRoot.
        appState.onCreateManager = { [weak self, weak service] in
            guard let self, let service else { return }
            // Pick the lowest unused "Manager N" so a delete-in-the-middle
            // doesn't produce a duplicate name.
            let existingNames = Set(self.appState.managerSessions.map(\.name))
            var n = 2
            while existingNames.contains("Manager \(n)") { n += 1 }
            let id = service.createManagerSession(name: "Manager \(n)", cwd: devRoot)
            self.appState.selectedSessionID = id
        }

        // Wire "Work on" issue action — sends issue URL to Manager terminal
        appState.onWorkOnIssue = { [weak self] issueURL in
            guard let self, let managerTerminals = self.appState.terminals[AppState.managerSessionID],
                  let managerTerminal = managerTerminals.first else { return }
            // Type the /crow-workspace command into the Manager terminal.
            // Route through TerminalRouter so it reaches the Manager regardless
            // of backend (Ghostty or tmux, #314).
            TerminalRouter.send(managerTerminal, text: "/crow-workspace \(issueURL)\n")
            // Switch to Manager tab
            self.appState.selectedSessionID = AppState.managerSessionID
        }

        // Wire batch "Work on" issues action — sends multiple URLs to Manager terminal
        appState.onBatchWorkOnIssues = { [weak self] issueURLs in
            guard let self, let managerTerminals = self.appState.terminals[AppState.managerSessionID],
                  let managerTerminal = managerTerminals.first else { return }
            let urls = issueURLs.joined(separator: " ")
            // Route through TerminalRouter so it reaches the Manager regardless
            // of backend (Ghostty or tmux, #314).
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
        tracker.autoRebaseWatcherEnabledProvider = { [weak self] in
            self?.appConfig?.autoRebaseWatcherEnabled ?? false
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
        tracker.start()
        self.issueTracker = tracker

        // Scheduled jobs (CROW-317): fire repo-scoped prompt sets on a schedule.
        let scheduler = JobScheduler(appState: appState, sessionService: service)
        scheduler.jobsProvider = { [weak self] in self?.appConfig?.jobs ?? [] }
        scheduler.devRootProvider = { [weak self] in self?.devRoot }
        scheduler.onJobRan = { [weak self] jobID, ranAt in
            self?.recordJobRun(jobID: jobID, ranAt: ranAt)
        }
        scheduler.start()
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

        appState.canAddMergeLabelResolver = { [providerManager] session in
            guard let provider = session.provider else { return false }
            return providerManager
                .codeBackend(for: provider)?
                .capabilities
                .contains(.autoMergeLabel) ?? false
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
            guard let self else { return [] }
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
                return cached.repos
            }
            let repos = await self.providerManager.reposForSpecs(
                ws.alwaysInclude, provider: provider, host: ws.host
            )
            self.workspaceRepoCache[key] = (Date(), repos)
            return repos
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

        // Start socket server
        startSocketServer(store: store, devRoot: devRoot, sessionService: service)

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

        let mainWindow = NSWindow(
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
        let win = NSWindow(
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
        let win = NSWindow(
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

    private func startSocketServer(store: JSONStore, devRoot: String, sessionService: SessionService) {
        let capturedAppState = appState
        let capturedStore = store
        let capturedNotifManager = notificationManager
        let capturedService = sessionService
        let capturedTelemetryPort = sessionService.telemetryPort
        let hookDebug = ProcessInfo.processInfo.environment["CROW_HOOK_DEBUG"] == "1"

        let router = CommandRouter(handlers: [
            "new-session": { @Sendable params in
                let name = params["name"]?.stringValue ?? "untitled"
                guard AppDelegate.isValidSessionName(name) else {
                    throw RPCError.invalidParams("Invalid session name (max \(AppDelegate.maxSessionNameLength) chars, no control characters)")
                }
                // Only work and manager sessions can be created here. Review and
                // job sessions need their dedicated setup (worktree, prompt files,
                // scheduler) and would be malformed if created bare via this path.
                let kindStr = params["kind"]?.stringValue
                guard kindStr == nil || kindStr == "work" || kindStr == "manager" else {
                    throw RPCError.invalidParams("Invalid kind (expected work or manager)")
                }
                let isManagerKind = kindStr == "manager"
                // Optional `agent_kind` param (e.g. "claude-code"). Falls
                // back to the app-wide default when absent or empty.
                let requestedAgentKind = params["agent_kind"]?.stringValue
                    .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
                return await MainActor.run {
                    // Manager sessions get their own agent terminal in the
                    // devRoot, mirroring the primary Manager. The Manager
                    // agent is resolved from `appState.agentKind(for: .manager)`
                    // inside `createManagerSession`, so the request's
                    // `agent_kind` param is ignored for manager kind
                    // (CROW-433).
                    if isManagerKind {
                        let id = capturedService.createManagerSession(name: name, cwd: devRoot)
                        let createdName = capturedAppState.sessions.first(where: { $0.id == id })?.name ?? name
                        return ["session_id": .string(id.uuidString), "name": .string(createdName)]
                    }
                    let agentKind = requestedAgentKind ?? capturedAppState.agentKind(for: .work)
                    let session = Session(name: name, kind: .work, agentKind: agentKind)
                    capturedAppState.sessions.append(session)
                    capturedStore.mutate { $0.sessions.append(session) }
                    return [
                        "session_id": .string(session.id.uuidString),
                        "name": .string(session.name),
                        "agent_kind": .string(session.agentKind.rawValue),
                    ]
                }
            },
            "rename-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue,
                      let id = UUID(uuidString: idStr),
                      let name = params["name"]?.stringValue else {
                    throw RPCError.invalidParams("session_id and name required")
                }
                guard AppDelegate.isValidSessionName(name) else {
                    throw RPCError.invalidParams("Invalid session name (max \(AppDelegate.maxSessionNameLength) chars, no control characters)")
                }
                return try await MainActor.run {
                    guard let idx = capturedAppState.sessions.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    capturedAppState.sessions[idx].name = name
                    capturedStore.mutate { data in
                        if let i = data.sessions.firstIndex(where: { $0.id == id }) { data.sessions[i].name = name }
                    }
                    return ["session_id": .string(idStr), "name": .string(name)]
                }
            },
            "select-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue,
                      let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.selectedSessionID = id }
                return ["session_id": .string(idStr)]
            },
            "list-sessions": { @Sendable _ in
                let sessions = await MainActor.run { capturedAppState.sessions }
                let items: [JSONValue] = sessions.map { s in
                    .object(["id": .string(s.id.uuidString), "name": .string(s.name), "status": .string(s.status.rawValue)])
                }
                return ["sessions": .array(items)]
            },
            "get-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                return try await MainActor.run {
                    guard let s = capturedAppState.sessions.first(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    let fmt = ISO8601DateFormatter()
                    return [
                        "id": .string(s.id.uuidString),
                        "name": .string(s.name),
                        "status": .string(s.status.rawValue),
                        "ticket_url": s.ticketURL.map { .string($0) } ?? .null,
                        "ticket_title": s.ticketTitle.map { .string($0) } ?? .null,
                        "ticket_number": s.ticketNumber.map { .int($0) } ?? .null,
                        "provider": s.provider.map { .string($0.rawValue) } ?? .null,
                        "created_at": .string(fmt.string(from: s.createdAt)),
                        "updated_at": .string(fmt.string(from: s.updatedAt)),
                    ]
                }
            },
            "set-status": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                      let statusStr = params["status"]?.stringValue, let status = SessionStatus(rawValue: statusStr) else {
                    throw RPCError.invalidParams("session_id and status required")
                }
                return try await MainActor.run {
                    guard let idx = capturedAppState.sessions.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    capturedAppState.sessions[idx].status = status
                    capturedAppState.sessions[idx].updatedAt = Date()
                    capturedStore.mutate { data in
                        if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                            data.sessions[i].status = status
                            data.sessions[i].updatedAt = Date()
                        }
                    }
                    return ["session_id": .string(idStr), "status": .string(statusStr)]
                }
            },
            "delete-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                guard id != AppState.managerSessionID else { throw RPCError.applicationError("Cannot delete manager session") }
                await capturedService.deleteSession(id: id)
                return ["deleted": .bool(true)]
            },
            "set-ticket": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                return try await MainActor.run {
                    guard let idx = capturedAppState.sessions.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    if let url = params["url"]?.stringValue {
                        capturedAppState.sessions[idx].ticketURL = url
                        // Auto-detect provider from URL
                        if capturedAppState.sessions[idx].provider == nil {
                            let detected = Validation.detectProviderFromURL(url)
                            capturedAppState.sessions[idx].provider = detected
                            // Task-only trackers (Jira/Corveil) have no code
                            // backend — pair with the workspace's code provider.
                            if capturedAppState.sessions[idx].codeProvider == nil, detected?.isTaskOnly == true {
                                let wtPath = capturedAppState.worktrees[id]?
                                    .first(where: { $0.isPrimary })?.worktreePath
                                    ?? capturedAppState.worktrees[id]?.first?.worktreePath
                                capturedAppState.sessions[idx].codeProvider = SessionService.resolvedCodeProvider(forTask: detected, worktreePath: wtPath)
                            }
                        }
                    }
                    if let title = params["title"]?.stringValue { capturedAppState.sessions[idx].ticketTitle = title }
                    if let num = params["number"]?.intValue { capturedAppState.sessions[idx].ticketNumber = num }
                    capturedStore.mutate { data in
                        if let i = data.sessions.firstIndex(where: { $0.id == id }) { data.sessions[i] = capturedAppState.sessions[idx] }
                    }
                    return ["session_id": .string(idStr)]
                }
            },
            "add-worktree": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                      let repo = params["repo"]?.stringValue, !repo.isEmpty,
                      let path = params["path"]?.stringValue, !path.isEmpty,
                      let branch = params["branch"]?.stringValue, !branch.isEmpty else {
                    throw RPCError.invalidParams("session_id, repo, path, branch required (non-empty)")
                }
                // Validate path is within devRoot to prevent path traversal
                guard AppDelegate.isPathWithinDevRoot(path, devRoot: devRoot) else {
                    throw RPCError.invalidParams("Worktree path must be within the configured devRoot")
                }
                // repo_path is the main repo (for git commands). Defaults to path if not provided.
                let repoPath = params["repo_path"]?.stringValue ?? path
                guard AppDelegate.isPathWithinDevRoot(repoPath, devRoot: devRoot) else {
                    throw RPCError.invalidParams("repo_path must be within the configured devRoot")
                }
                let wt = SessionWorktree(sessionID: sessionID, repoName: repo, repoPath: repoPath, worktreePath: path,
                                         branch: branch, isPrimary: params["primary"]?.boolValue ?? false)
                return await MainActor.run {
                    capturedAppState.worktrees[sessionID, default: []].append(wt)
                    capturedStore.mutate { $0.worktrees.append(wt) }
                    return ["worktree_id": .string(wt.id.uuidString), "session_id": .string(idStr), "path": .string(path)]
                }
            },
            "list-worktrees": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let wts = await MainActor.run { capturedAppState.worktrees(for: id) }
                let items: [JSONValue] = wts.map { wt in
                    .object(["id": .string(wt.id.uuidString), "repo": .string(wt.repoName), "path": .string(wt.worktreePath),
                             "branch": .string(wt.branch), "primary": .bool(wt.isPrimary)])
                }
                return ["worktrees": .array(items)]
            },
            "new-terminal": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                      let cwd = params["cwd"]?.stringValue else {
                    throw RPCError.invalidParams("session_id and cwd required")
                }
                // Validate cwd is within devRoot to prevent path traversal
                guard AppDelegate.isPathWithinDevRoot(cwd, devRoot: devRoot) else {
                    throw RPCError.invalidParams("Terminal cwd must be within the configured devRoot")
                }
                let rawCommand = params["command"]?.stringValue
                let isManaged = params["managed"]?.boolValue ?? false
                return await MainActor.run {
                    // Resolve claude binary path if command references claude; also
                    // inject --rc --name when remote control is enabled so the session
                    // appears in claude.ai's Remote Control panel under the Crow
                    // session name.
                    var command = rawCommand
                    var rcInjected = false
                    let session = capturedAppState.sessions.first(where: { $0.id == sessionID })
                    let sessionName = session?.name
                    // The default managed-terminal name is the configured agent's
                    // displayName (CROW-427) — Cursor sessions read "Cursor",
                    // Codex sessions read "OpenAI Codex", etc. When the session
                    // can't be found yet, fall back to the AppState default kind.
                    let agentKind = session?.agentKind ?? capturedAppState.defaultAgentKind
                    let defaultName = isManaged ? agentKind.displayName : "Shell"
                    let terminalName = params["name"]?.stringValue ?? defaultName
                    if let cmd = rawCommand, cmd.contains("claude") {
                        let rcEnabled = capturedAppState.remoteControlEnabled
                        command = AppDelegate.resolveClaudeInCommand(
                            cmd,
                            remoteControl: rcEnabled,
                            sessionName: sessionName
                        )
                        rcInjected = rcEnabled
                            && !cmd.contains("--rc")
                            && !cmd.contains("--remote-control")
                    }
                    let trackReadiness = isManaged
                    // Brand-new managed terminals DEFER their agent launch until
                    // the shell signals readiness (issue #408). Pasting the launch
                    // command immediately races the shell's line editor (zle): if
                    // the prompt isn't live yet the keystrokes are dropped and the
                    // window is left at a bare zsh with no agent. Instead hold the
                    // command in `pendingLaunchCommands` and register the window
                    // with `command: nil`, so the deferred paste happens in
                    // `SessionService.wireTerminalReadiness` on `.shellReady`.
                    let hasCommand = !(command?.isEmpty ?? true)
                    let deferLaunch = trackReadiness && hasCommand
                    let registerCommand = deferLaunch ? nil : command
                    // Every session, including the Manager (#314), runs on
                    // tmux (#303). Register the tmux window now — its shell
                    // starts immediately, so there's no offscreen pre-init.
                    //
                    // Persist `registerCommand` (nil for a deferred launch), NOT
                    // the raw launch command: the launch lives in
                    // `pendingLaunchCommands` (in-memory) and the persisted row
                    // must not carry it, or the hydrate-fresh fallback would
                    // blind-paste it into a not-yet-ready shell on the recovery
                    // path — the very race this fixes (#408). A restored managed
                    // terminal relaunches via the autoLaunch/launchAgent path.
                    var terminal = SessionTerminal(
                        sessionID: sessionID,
                        name: terminalName,
                        cwd: cwd,
                        command: registerCommand,
                        isManaged: isManaged,
                        backend: .tmux
                    )
                    // Seed readiness + pending-launch state BEFORE registering so
                    // the sentinel's `.shellReady` (which can only fire on a later
                    // main-actor turn) always finds the pending command and the
                    // autoLaunch membership populated.
                    if trackReadiness {
                        capturedAppState.terminalReadiness[terminal.id] = .uninitialized
                    }
                    if deferLaunch, let command {
                        capturedAppState.pendingLaunchCommands[terminal.id] = command
                        // Membership lets the existing `.timedOut` re-arm machinery
                        // (`reArmStuckReadinessWatches`) recover a slow launch.
                        capturedAppState.autoLaunchTerminals.insert(terminal.id)
                    }
                    var launchFailed = false
                    do {
                        // Bounded retry with a modestly-longer per-call `new-window`
                        // budget: under load the tmux subprocess can exceed the 2s
                        // default and get SIGTERM'd, leaving a window-less terminal
                        // (#408). This runs inside `MainActor.run`, so the budget is
                        // kept tight (2 attempts × 3s) to cap worst-case main-actor
                        // stall at ~6s rather than beachballing concurrent RPCs.
                        let binding = try AppDelegate.registerWithRetry(attempts: 2) { _ in
                            try TmuxBackend.shared.registerTerminal(
                                id: terminal.id,
                                name: terminalName,
                                cwd: cwd,
                                command: registerCommand,
                                trackReadiness: trackReadiness,
                                agentKind: agentKind,
                                newWindowTimeout: 3.0
                            )
                        }
                        terminal.tmuxBinding = binding
                    } catch {
                        // The tmux window never materialized. Don't pretend the
                        // launch succeeded (#408): surface it so the UI shows a
                        // Retry affordance and the CLI caller reports honestly
                        // instead of leaving a silent window-less terminal.
                        NSLog("[Crow] tmux registerTerminal failed after retries (\(error)); surfacing launch failure")
                        launchFailed = true
                        if trackReadiness {
                            capturedAppState.terminalReadiness[terminal.id] = .failed
                        }
                        capturedAppState.pendingLaunchCommands.removeValue(forKey: terminal.id)
                        capturedAppState.autoLaunchTerminals.remove(terminal.id)
                    }
                    capturedAppState.terminals[sessionID, default: []].append(terminal)
                    capturedStore.mutate { $0.terminals.append(terminal) }
                    if trackReadiness {
                        TerminalRouter.trackReadiness(for: terminal)
                    }
                    if rcInjected {
                        capturedAppState.remoteControlActiveTerminals.insert(terminal.id)
                    }
                    var result: [String: JSONValue] = [
                        "terminal_id": .string(terminal.id.uuidString),
                        "session_id": .string(idStr),
                    ]
                    if launchFailed { result["launch_failed"] = .bool(true) }
                    return result
                }
            },
            "list-terminals": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let terms = await MainActor.run { capturedAppState.terminals(for: id) }
                let readiness = await MainActor.run { capturedAppState.terminalReadiness }
                let items: [JSONValue] = terms.map { t in
                    // `readiness` lets CLI callers (setup.sh) verify the agent
                    // actually started rather than assuming a launch succeeded
                    // (#408). Defaults to `uninitialized` for un-tracked shells.
                    .object([
                        "id": .string(t.id.uuidString),
                        "name": .string(t.name),
                        "session_id": .string(t.sessionID.uuidString),
                        "managed": .bool(t.isManaged),
                        "readiness": .string((readiness[t.id] ?? .uninitialized).rawValue),
                    ])
                }
                return ["terminals": .array(items)]
            },
            "close-terminal": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr) else {
                    throw RPCError.invalidParams("session_id and terminal_id required")
                }
                return try await MainActor.run {
                    guard let terminals = capturedAppState.terminals[sessionID],
                          let terminal = terminals.first(where: { $0.id == terminalID }) else {
                        throw RPCError.applicationError("Terminal not found")
                    }
                    guard !terminal.isManaged else {
                        throw RPCError.applicationError("Cannot close managed terminal")
                    }
                    TerminalRouter.destroy(terminal)
                    capturedAppState.terminals[sessionID]?.removeAll { $0.id == terminalID }
                    capturedAppState.terminalReadiness.removeValue(forKey: terminalID)
                    capturedAppState.autoLaunchTerminals.remove(terminalID)
                    capturedAppState.pendingLaunchCommands.removeValue(forKey: terminalID)
                    if capturedAppState.activeTerminalID[sessionID] == terminalID {
                        capturedAppState.activeTerminalID[sessionID] = capturedAppState.terminals[sessionID]?.first?.id
                    }
                    capturedStore.mutate { data in data.terminals.removeAll { $0.id == terminalID } }
                    return ["deleted": .bool(true)]
                }
            },
            "rename-terminal": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr),
                      let name = params["name"]?.stringValue else {
                    throw RPCError.invalidParams("session_id, terminal_id, and name required")
                }
                return try await MainActor.run {
                    guard capturedService.renameTerminal(sessionID: sessionID, terminalID: terminalID, name: name) else {
                        throw RPCError.applicationError("Terminal not found or invalid name")
                    }
                    return ["terminal_id": .string(terminalIDStr), "name": .string(name)]
                }
            },
            "send": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr),
                      var text = params["text"]?.stringValue else {
                    throw RPCError.invalidParams("session_id, terminal_id, and text required")
                }
                // Process escape sequences: literal \n in the text becomes a real newline
                text = text.replacingOccurrences(of: "\\n", with: "\n")
                text = text.replacingOccurrences(of: "\\t", with: "\t")
                NSLog("crow send: text length=\(text.count), ends_with_newline=\(text.hasSuffix("\n")), ends_with_cr=\(text.hasSuffix("\r"))")
                await MainActor.run {
                    let routedTerminal = capturedAppState.terminals[sessionID]?.first(where: { $0.id == terminalID })
                    // tmux-backed terminals already have their window from
                    // registerTerminal — no surface recovery needed before send.

                    // For managed terminals receiving an agent-launching
                    // command, write hook config (and inject OTEL env vars
                    // for Claude) before forwarding so the agent picks up
                    // hooks on startup. The agent dispatch is driven by the
                    // session's `agentKind` and the agent's
                    // `launchCommandToken` (e.g. "claude", "codex").
                    if let terminals = capturedAppState.terminals[sessionID],
                       let terminal = terminals.first(where: { $0.id == terminalID }),
                       terminal.isManaged,
                       let session = capturedAppState.sessions.first(where: { $0.id == sessionID }),
                       let agent = AgentRegistry.shared.agent(for: session.agentKind) {
                        let prepared = AppDelegate.prepareAgentLaunchText(
                            command: text,
                            agent: agent,
                            sessionID: sessionID,
                            worktreePath: capturedAppState.primaryWorktree(for: sessionID)?.worktreePath,
                            crowPath: ClaudeHookConfigWriter.findCrowBinary(),
                            telemetryPort: capturedTelemetryPort
                        )
                        text = prepared.text
                        if prepared.didLaunch {
                            capturedAppState.terminalReadiness[terminalID] = .agentLaunched
                        }
                    }

                    if let routedTerminal {
                        TerminalRouter.send(routedTerminal, text: text)
                    } else {
                        // No SessionTerminal row known — nothing to route to.
                        NSLog("[Crow] crow send for unknown terminal \(terminalID); ignoring")
                    }
                }
                return ["sent": .bool(true)]
            },
            "add-link": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                      let label = params["label"]?.stringValue, !label.isEmpty,
                      let url = params["url"]?.stringValue, !url.isEmpty else {
                    throw RPCError.invalidParams("session_id, label, url required (non-empty)")
                }
                let link = SessionLink(sessionID: sessionID, label: label, url: url,
                                       linkType: LinkType(rawValue: params["type"]?.stringValue ?? "custom") ?? .custom)
                return await MainActor.run {
                    capturedAppState.links[sessionID, default: []].append(link)
                    capturedStore.mutate { $0.links.append(link) }
                    return ["link_id": .string(link.id.uuidString)]
                }
            },
            "list-links": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let lnks = await MainActor.run { capturedAppState.links(for: id) }
                let items: [JSONValue] = lnks.map { l in
                    .object(["id": .string(l.id.uuidString), "label": .string(l.label), "url": .string(l.url), "type": .string(l.linkType.rawValue)])
                }
                return ["links": .array(items)]
            },
            "hook-event": { @Sendable params in
                guard let eventName = params["event_name"]?.stringValue else {
                    throw RPCError.invalidParams("event_name required")
                }
                let payload = params["payload"]?.objectValue ?? [:]

                // session_id is now optional — Codex's global hooks don't
                // know the Crow session UUID, so the server resolves it via
                // the `cwd` field in the payload.
                let providedSessionID = params["session_id"]?.stringValue
                    .flatMap(UUID.init(uuidString:))
                let requestedAgentKind = params["agent_kind"]?.stringValue
                    .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
                let cwd = payload["cwd"]?.stringValue

                // Build a human-readable summary from the event (independent
                // of session resolution).
                let summary: String = {
                    switch eventName {
                    case "PreToolUse", "PostToolUse", "PostToolUseFailure":
                        let tool = payload["tool_name"]?.stringValue ?? "unknown"
                        return "\(eventName): \(tool)"
                    case "Notification":
                        let msg = payload["message"]?.stringValue ?? ""
                        return "Notification: \(msg.prefix(80))"
                    case "Stop":
                        return "Agent finished responding"
                    case "StopFailure":
                        return "Agent stopped with error"
                    case "SessionStart":
                        return "Session started"
                    case "SessionEnd":
                        return "Session ended"
                    case "PermissionRequest":
                        return "Permission requested"
                    case "PermissionDenied":
                        return "Permission denied"
                    case "UserPromptSubmit":
                        return "User submitted prompt"
                    case "TaskCreated":
                        return "Task created"
                    case "TaskCompleted":
                        return "Task completed"
                    case "SubagentStart":
                        let agentType = payload["agent_type"]?.stringValue ?? "agent"
                        return "Subagent started: \(agentType)"
                    case "SubagentStop":
                        return "Subagent stopped"
                    case "PreCompact":
                        return "Context compaction starting"
                    case "PostCompact":
                        return "Context compaction finished"
                    default:
                        return eventName
                    }
                }()

                return try await MainActor.run {
                    // Resolve session — explicit param wins, else look up by
                    // worktree path matching `cwd`.
                    let sessionID: UUID
                    if let provided = providedSessionID {
                        sessionID = provided
                    } else if let cwd, let resolved = capturedAppState.sessionID(forWorktreePath: cwd) {
                        sessionID = resolved
                    } else {
                        throw RPCError.invalidParams("session_id required or resolvable from payload cwd")
                    }
                    let sessionIDStr = sessionID.uuidString

                    if hookDebug {
                        let shortID = String(sessionIDStr.prefix(8))
                        let keys = payload.keys.sorted().joined(separator: ",")
                        NSLog("[hook-event] session=\(shortID) event=\(eventName) payload-keys=[\(keys)]")
                    }

                    let event = HookEvent(
                        sessionID: sessionID,
                        eventName: eventName,
                        summary: summary
                    )

                    // Flatten the raw JSON payload into the typed AgentHookEvent
                    // that the state-machine signal source consumes. Keeps
                    // CrowCore free of JSONValue, and localizes the field
                    // extraction in one place.
                    let agentEvent = AgentHookEvent(
                        sessionID: sessionID,
                        eventName: eventName,
                        toolName: payload["tool_name"]?.stringValue,
                        source: payload["source"]?.stringValue,
                        message: payload["message"]?.stringValue,
                        notificationType: payload["notification_type"]?.stringValue,
                        agentType: payload["agent_type"]?.stringValue,
                        summary: summary
                    )

                    // Resolve the agent: explicit kind param > session's
                    // stored agentKind > app default.
                    let session = capturedAppState.sessions.first(where: { $0.id == sessionID })
                    let resolvedKind = requestedAgentKind
                        ?? session?.agentKind
                        ?? capturedAppState.defaultAgentKind
                    let signalSource = AgentRegistry.shared.agent(for: resolvedKind)?.stateSignalSource

                    let state = capturedAppState.hookState(for: sessionID)
                    let stateBefore = state.activityState
                    // Snapshot the color-driving subset so we can persist only on a
                    // real change (keeps sidebar colors correct after relaunch — #367).
                    let snapshotBefore = state.persistedSnapshot

                    // Append to ring buffer (keep last 50 events per session)
                    state.hookEvents.append(event)
                    if state.hookEvents.count > 50 { state.hookEvents.removeFirst(state.hookEvents.count - 50) }

                    // Ask the agent for the state transition and apply it.
                    // The signal source is pure — all side effects (persistence,
                    // notifications, etc.) stay here in the handler.
                    if let signalSource {
                        let transition = signalSource.transition(
                            for: agentEvent,
                            currentActivityState: state.activityState,
                            currentNotificationType: state.pendingNotification?.notificationType,
                            currentLastTopLevelStopAt: state.lastTopLevelStopAt
                        )
                        if let newActivityState = transition.newActivityState {
                            state.activityState = newActivityState
                        }
                        switch transition.notification {
                        case .leave:
                            break
                        case .clear:
                            state.pendingNotification = nil
                        case .set(let notification):
                            state.pendingNotification = notification
                        }
                        switch transition.toolActivity {
                        case .leave:
                            break
                        case .clear:
                            state.lastToolActivity = nil
                        case .set(let activity):
                            state.lastToolActivity = activity
                        }
                        switch transition.lastTopLevelStopAt {
                        case .leave:
                            break
                        case .clear:
                            state.lastTopLevelStopAt = nil
                        case .set(let date):
                            state.lastTopLevelStopAt = date
                        }
                    }

                    // Trigger notification/sound for this event
                    capturedNotifManager?.handleEvent(
                        sessionID: sessionID,
                        eventName: eventName,
                        payload: payload,
                        summary: summary
                    )

                    if hookDebug && state.activityState != stateBefore {
                        let shortID = String(sessionIDStr.prefix(8))
                        NSLog("[hook-event] session=\(shortID) event=\(eventName) state=\(stateBefore.rawValue)→\(state.activityState.rawValue)")
                    }

                    // Persist the color-driving state only when it actually changed,
                    // so sidebar colors survive a quit→relaunch (#367). Excluding
                    // lastToolActivity means frequent PostToolUse events don't write.
                    let snapshotAfter = state.persistedSnapshot
                    if snapshotAfter != snapshotBefore {
                        capturedStore.mutate { data in
                            var map = data.hookStates ?? [:]
                            map[sessionIDStr] = snapshotAfter
                            data.hookStates = map
                        }
                    }

                    return [
                        "received": .bool(true),
                        "session_id": .string(sessionIDStr),
                        "event_name": .string(eventName),
                    ]
                }
            },
        ])

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
        // the slower Ghostty/tmux teardown below finishes (flock would release
        // on exit anyway; explicit + early is best).
        if instanceLockFD >= 0 {
            close(instanceLockFD)
            instanceLockFD = -1
        }
        // Leave the tmux server running so the next launch re-attaches to the
        // existing sessions (#330). The crash-watchdog's "Restart tmux server"
        // path still tears it down via the default `shutdown()`.
        TmuxBackend.shared.shutdown(killServer: false)
        GhosttyApp.shared.shutdown()
        NSLog("[Crow] Cleanup complete")
    }

    // MARK: - Terminal Registration

    /// Run `create` up to `attempts` times, returning the first success or
    /// rethrowing the last error after exhausting all attempts. Window
    /// registration can transiently fail under load when `new-window` exceeds
    /// its subprocess timeout (issue #408); a couple of retries turn most of
    /// those into successes instead of silent window-less terminals. Pure over
    /// the `create` closure so the retry policy is unit-testable without tmux.
    nonisolated static func registerWithRetry<T>(
        attempts: Int,
        create: (_ attempt: Int) throws -> T
    ) throws -> T {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try create(attempt)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RPCError.applicationError("registerWithRetry: no attempts run")
    }

    /// Prepare an agent-launching command for a managed terminal: write the
    /// per-worktree hook config so the agent's hooks route back to `sessionID`,
    /// and (for Claude) prepend the OTEL telemetry exporter env vars. Returns
    /// the final text plus whether `command` actually launches the agent (its
    /// `launchCommandToken` is present). Single source of truth shared by the
    /// `send` RPC and the #408 deferred-launch paste so the two never drift.
    nonisolated static func prepareAgentLaunchText(
        command: String,
        agent: any CodingAgent,
        sessionID: UUID,
        worktreePath: String?,
        crowPath: String?,
        telemetryPort: UInt16?
    ) -> (text: String, didLaunch: Bool) {
        guard commandLaunchesToken(command, token: agent.launchCommandToken) else { return (command, false) }
        if let worktreePath, let crowPath {
            do {
                try agent.hookConfigWriter.writeHookConfig(
                    worktreePath: worktreePath,
                    sessionID: sessionID,
                    crowPath: crowPath
                )
            } catch {
                NSLog("[AppDelegate] Failed to write hook config for session %@: %@",
                      sessionID.uuidString, error.localizedDescription)
            }
        }
        // OTEL telemetry env vars are Claude-specific — Codex has no equivalent
        // OTLP exporter.
        guard agent.kind == .claudeCode, let port = telemetryPort else { return (command, true) }
        let vars = [
            "CLAUDE_CODE_ENABLE_TELEMETRY=1",
            "OTEL_METRICS_EXPORTER=otlp",
            "OTEL_LOGS_EXPORTER=otlp",
            "OTEL_EXPORTER_OTLP_PROTOCOL=http/json",
            "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(port)",
            "OTEL_RESOURCE_ATTRIBUTES=crow.session.id=\(sessionID.uuidString)",
        ].joined(separator: " ")
        return ("export \(vars) && \(command)", true)
    }

    /// Whether `command` invokes `token` as a shell command rather than an
    /// incidental substring. Anchored at start-of-string, after a shell
    /// command separator (`;`, `&&`, `||`, `|`, possibly with whitespace),
    /// or at a path separator (`/`) — the last covers binaries that have
    /// already been path-resolved (e.g. `resolveClaudeInCommand` rewrites
    /// bare `claude` to `/opt/homebrew/bin/claude` before this guard runs
    /// on the deferred-launch path, so without the `/` boundary the guard
    /// returns early and we'd silently skip per-worktree hook-config writes
    /// and Claude's OTEL env injection). Bounded on the right by whitespace,
    /// end-of-string, or a quote.
    ///
    /// Plain `command.contains(token)` was fine for Claude (`"claude"`) and
    /// Codex (`"codex"`), which rarely appear incidentally — but Cursor's
    /// token is `"agent"`, a common English word that can show up in any
    /// `crow send` text (e.g. *"refactor the agent registry"*). Without
    /// anchoring we would flip `terminalReadiness = .agentLaunched` on
    /// arbitrary prose and `list-terminals` would report the agent had
    /// started when it hadn't.
    nonisolated static func commandLaunchesToken(_ command: String, token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?:^|[;&|]\\s*|/)\(escaped)(?=\\s|$|[\"'])"
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Claude Binary Resolution

    /// Replace bare `claude` in a command string with the full path to the real binary,
    /// skipping the CMUX wrapper. When `remoteControl` is true and the command does not
    /// already request remote control, also inject `--rc --name '<sessionName>'` immediately
    /// after the claude path so it sits before any trailing prompt argument.
    nonisolated static func resolveClaudeInCommand(
        _ command: String,
        remoteControl: Bool = false,
        sessionName: String? = nil
    ) -> String {
        for path in SessionService.claudeBinaryCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                // Only touch commands that start with the bare `claude` token.
                let rest: String?
                if command == "claude" {
                    rest = ""
                } else if command.hasPrefix("claude ") {
                    rest = String(command.dropFirst("claude".count)) // " ..."
                } else {
                    rest = nil
                }
                guard let rest else { return command }

                let wantsRC = remoteControl
                    && !command.contains("--rc")
                    && !command.contains("--remote-control")
                let extra = wantsRC
                    ? ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: sessionName)
                    : ""
                return path + extra + rest
            }
        }
        return command
    }
}

enum RPCError: Error, LocalizedError, RPCErrorCoded {
    case invalidParams(String)
    case applicationError(String)
    var rpcErrorCode: Int {
        switch self {
        case .invalidParams: RPCErrorCode.invalidParams
        case .applicationError: RPCErrorCode.applicationError
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidParams(let msg): msg
        case .applicationError(let msg): msg
        }
    }
}
