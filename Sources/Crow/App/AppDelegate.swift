import AppKit
import SwiftUI
import CrowCore
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

    /// Tail of the serial review-kickoff queue. Each call to
    /// `enqueueReviewKickoff` awaits the previous tail before doing any work,
    /// so all `createReviewSession` runs are strictly sequential across both
    /// manual batches and auto-review refreshes. See #266 for the race this
    /// replaced.
    private var reviewKickoffTail: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must be the very first call so the next exit (graceful or not)
        // lands somewhere readable. Also redirects stderr so Swift runtime
        // traps (`fatalError`, `precondition`) and `print` to stderr show up
        // in the crash log instead of being silently dropped when the app is
        // launched from Finder.
        CrashReporter.install()

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

    /// Surface a native alert when the tmux backend (the default since #301)
    /// can't find a usable tmux on the host. Spec §11 / PROD #4. The user
    /// can:
    ///   - Copy the brew-install command to their clipboard.
    ///   - Open the upstream tmux installation guide.
    ///   - Continue without the tmux backend (we fall through to Ghostty).
    private func showTmuxNotFoundOnboardingSheet() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "tmux ≥ 3.3 not found"
        alert.informativeText = """
            Crow now uses tmux for managed terminals by default, but no \
            tmux binary ≥ 3.3 was found in /opt/homebrew/bin, /usr/local/bin, \
            or /usr/bin.

            On Macs with Homebrew, install with:

                brew install tmux

            Crow won't change your dotfiles — it runs your usual shell config \
            inside the tmux session.

            Falling back to the legacy per-terminal Ghostty backend for this \
            launch. Restart Crow after installing tmux to enable the default.
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

            // Scaffold directory structure
            let scaffolder = Scaffolder(devRoot: devRoot)
            try scaffolder.scaffold(workspaceNames: config.workspaces.map(\.name))

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

        // Initialize libghostty
        NSLog("[Crow] Initializing Ghostty")
        GhosttyApp.shared.initialize()

        // Load config before initializing the terminal backend so any future
        // backend selection knobs can read it.
        let config = appConfig ?? ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
        self.appConfig = config
        NSLog("[Crow] Config loaded (workspaces: %d)", config.workspaces.count)

        // Configure the tmux backend (#198 → defaulted-on in #301). The
        // legacy per-terminal Ghostty path is still reachable for this
        // release via `CROW_TMUX_BACKEND=0` as an escape hatch; it will be
        // removed once one release of soak passes without regressions. If
        // tmux is missing or < 3.3 we log a warning, surface the first-run
        // onboarding sheet, and fall back to Ghostty for this launch.
        //
        // Independently of the flag, reap any orphan tmux servers from past
        // Crow runs that exited ungracefully (Force Quit / crash bypasses
        // applicationWillTerminate and therefore the shutdown fix). Reaping
        // is keyed on $TMPDIR/crow-tmux-<pid>.sock files whose PID is no
        // longer a live CrowApp process. Costs ~50ms when there's nothing
        // to do; idempotent.
        let discoveredTmuxBinary = TmuxDiscovery.discover()
        if let tmuxBinary = discoveredTmuxBinary {
            TmuxOrphanReaper.reap(
                tmuxBinary: tmuxBinary,
                currentPID: ProcessInfo.processInfo.processIdentifier
            )
        }
        if FeatureFlags.tmuxBackend {
            if let tmuxBinary = discoveredTmuxBinary {
                // Per-app socket in $TMPDIR. v1 of the rollout kills the
                // tmux server on app quit, so restart-survival isn't a
                // requirement; ~/Library/Application Support is reserved
                // for that future work (spec §12).
                let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
                let socketPath = (tmpdir as NSString)
                    .appendingPathComponent("crow-tmux-\(ProcessInfo.processInfo.processIdentifier).sock")
                TmuxBackend.shared.configure(tmuxBinary: tmuxBinary, socketPath: socketPath)
                TmuxBackend.shared.onUnresponsive = { [weak self] error in
                    Task { @MainActor in self?.handleTmuxUnresponsive(error: error) }
                }
                NSLog("[Crow] tmux backend configured: binary=\(tmuxBinary) socket=\(socketPath)")
            } else {
                NSLog("[Crow] tmux backend is the default but no tmux ≥ 3.3 found — falling back to Ghostty for this launch")
                showTmuxNotFoundOnboardingSheet()
            }
        }

        // Update skills and CLAUDE.md on every launch
        let scaffolder = Scaffolder(devRoot: devRoot)
        do {
            try scaffolder.scaffold(workspaceNames: config.workspaces.map(\.name))
        } catch {
            NSLog("[Crow] Scaffold update failed: %@", error.localizedDescription)
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
        appState.excludeReviewRepos = config.defaults.excludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels

        // Create session service and hydrate state
        let service = SessionService(store: store, appState: appState, telemetryPort: config.telemetry.enabled ? config.telemetry.port : nil)
        service.hydrateState()
        self.sessionService = service
        NSLog("[Crow] Session state hydrated (%d sessions)", appState.sessions.count)

        // Detect orphaned worktrees (runs async, updates UI when done)
        Task { await service.detectOrphanedWorktrees() }

        // Check for runtime dependencies (non-blocking)
        Task {
            let missing = await Task.detached {
                let tools = ["gh", "git", "claude", "glab", "code"]
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

        appState.onLaunchClaude = { [weak service] terminalID in
            service?.launchClaude(terminalID: terminalID)
        }

        appState.onRetryTerminal = { [weak service] terminalID in
            service?.retryTerminal(terminalID: terminalID)
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
        appState.onAddGlobalTerminal = { [weak service] in
            service?.addGlobalTerminal()
        }
        appState.onCloseGlobalTerminal = { [weak service] terminalID in
            service?.closeGlobalTerminal(terminalID: terminalID)
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
        let tracker = IssueTracker(appState: appState)
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
            let enabledRepos = Set((self.appConfig?.workspaces ?? [])
                .flatMap(\.autoReviewRepos)
                .map { $0.lowercased() })
            guard !enabledRepos.isEmpty else { return }

            var pendingURLs: [String] = []
            for request in requests {
                guard enabledRepos.contains(request.repo.lowercased()) else { continue }
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
                guard request.reviewSessionID == nil || shaAdvanced else { continue }

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
            self.appState.onWorkOnIssue?(issue.url)
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

        appState.onMarkInReview = { [weak tracker] id in
            Task { await tracker?.markInReview(sessionID: id) }
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
                try? scaffolder.scaffold(workspaceNames: self?.appConfig?.workspaces.map(\.name) ?? [])
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
        appState.excludeReviewRepos = config.defaults.excludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels
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
                return await MainActor.run {
                    let session = Session(name: name)
                    capturedAppState.sessions.append(session)
                    capturedStore.mutate { $0.sessions.append(session) }
                    return ["session_id": .string(session.id.uuidString), "name": .string(session.name)]
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
                            capturedAppState.sessions[idx].provider = Validation.detectProviderFromURL(url)
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
                let defaultName = isManaged ? "Claude Code" : "Shell"
                let terminalName = params["name"]?.stringValue ?? defaultName
                return await MainActor.run {
                    // Resolve claude binary path if command references claude; also
                    // inject --rc --name when remote control is enabled so the session
                    // appears in claude.ai's Remote Control panel under the Crow
                    // session name.
                    var command = rawCommand
                    var rcInjected = false
                    if let cmd = rawCommand, cmd.contains("claude") {
                        let rcEnabled = capturedAppState.remoteControlEnabled
                        let sessionName = capturedAppState.sessions.first(where: { $0.id == sessionID })?.name
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
                    // Decide backend at terminal-create time. Every session,
                    // including the Manager (#314), honors the flag.
                    let useTmux = FeatureFlags.tmuxBackend
                        && !TmuxBackend.shared.tmuxBinary.isEmpty
                    var terminal = SessionTerminal(
                        sessionID: sessionID,
                        name: terminalName,
                        cwd: cwd,
                        command: command,
                        isManaged: isManaged,
                        backend: useTmux ? .tmux : .ghostty
                    )
                    if useTmux {
                        do {
                            let binding = try TmuxBackend.shared.registerTerminal(
                                id: terminal.id,
                                name: terminalName,
                                cwd: cwd,
                                command: command,
                                trackReadiness: trackReadiness
                            )
                            terminal.tmuxBinding = binding
                        } catch {
                            NSLog("[Crow] tmux registerTerminal failed (\(error)); falling back to Ghostty")
                            terminal.backend = .ghostty
                            terminal.tmuxBinding = nil
                        }
                    }
                    capturedAppState.terminals[sessionID, default: []].append(terminal)
                    capturedStore.mutate { $0.terminals.append(terminal) }
                    if trackReadiness {
                        capturedAppState.terminalReadiness[terminal.id] = .uninitialized
                        TerminalRouter.trackReadiness(for: terminal)
                    }
                    if rcInjected {
                        capturedAppState.remoteControlActiveTerminals.insert(terminal.id)
                    }
                    // For Ghostty terminals, pre-initialize the offscreen
                    // surface so the shell starts in the background. For
                    // tmux, the window already exists from registerTerminal.
                    if terminal.backend == .ghostty {
                        TerminalManager.shared.preInitialize(id: terminal.id, workingDirectory: cwd, command: command)
                    }
                    return ["terminal_id": .string(terminal.id.uuidString), "session_id": .string(idStr)]
                }
            },
            "list-terminals": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                // Global terminals are not exposed via the session CLI
                if id == AppState.globalTerminalSessionID {
                    return ["terminals": .array([])]
                }
                let terms = await MainActor.run { capturedAppState.terminals(for: id) }
                let items: [JSONValue] = terms.map { t in
                    .object(["id": .string(t.id.uuidString), "name": .string(t.name), "session_id": .string(t.sessionID.uuidString), "managed": .bool(t.isManaged)])
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
                    // If a Ghostty surface doesn't exist yet, pre-initialize it
                    // so the shell starts. tmux-backed terminals already have
                    // their window from registerTerminal — no recovery needed.
                    if let routedTerminal,
                       routedTerminal.backend == .ghostty,
                       TerminalManager.shared.existingSurface(for: terminalID) == nil {
                        TerminalManager.shared.preInitialize(
                            id: terminalID,
                            workingDirectory: routedTerminal.cwd,
                            command: routedTerminal.command
                        )
                    }

                    // For managed terminals receiving a claude command, write hook config
                    // before sending so Claude picks up the hooks on startup.
                    if let terminals = capturedAppState.terminals[sessionID],
                       let terminal = terminals.first(where: { $0.id == terminalID }),
                       terminal.isManaged,
                       text.contains("claude") {
                        if let worktree = capturedAppState.primaryWorktree(for: sessionID),
                           let crowPath = HookConfigGenerator.findCrowBinary() {
                            do {
                                try HookConfigGenerator.writeHookConfig(
                                    worktreePath: worktree.worktreePath,
                                    sessionID: sessionID,
                                    crowPath: crowPath
                                )
                            } catch {
                                NSLog("[AppDelegate] Failed to write hook config for session %@: %@",
                                      sessionID.uuidString, error.localizedDescription)
                            }
                        }
                        // Inject OTEL telemetry env vars so analytics flow back to Crow
                        if let port = capturedTelemetryPort {
                            let vars = [
                                "CLAUDE_CODE_ENABLE_TELEMETRY=1",
                                "OTEL_METRICS_EXPORTER=otlp",
                                "OTEL_LOGS_EXPORTER=otlp",
                                "OTEL_EXPORTER_OTLP_PROTOCOL=http/json",
                                "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(port)",
                                "OTEL_RESOURCE_ATTRIBUTES=crow.session.id=\(sessionID.uuidString)",
                            ].joined(separator: " ")
                            text = "export \(vars) && \(text)"
                        }
                        capturedAppState.terminalReadiness[terminalID] = .claudeLaunched
                    }

                    if let routedTerminal {
                        TerminalRouter.send(routedTerminal, text: text)
                    } else {
                        // No SessionTerminal row known — fall back to legacy
                        // path for backward-compat with anything that calls
                        // `crow send` for an id we haven't seen.
                        TerminalManager.shared.send(id: terminalID, text: text)
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
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let eventName = params["event_name"]?.stringValue else {
                    throw RPCError.invalidParams("session_id and event_name required")
                }
                let payload = params["payload"]?.objectValue ?? [:]

                if hookDebug {
                    let shortID = String(sessionIDStr.prefix(8))
                    let keys = payload.keys.sorted().joined(separator: ",")
                    NSLog("[hook-event] session=\(shortID) event=\(eventName) payload-keys=[\(keys)]")
                }

                // Build a human-readable summary from the event
                let summary: String = {
                    switch eventName {
                    case "PreToolUse", "PostToolUse", "PostToolUseFailure":
                        let tool = payload["tool_name"]?.stringValue ?? "unknown"
                        return "\(eventName): \(tool)"
                    case "Notification":
                        let msg = payload["message"]?.stringValue ?? ""
                        return "Notification: \(msg.prefix(80))"
                    case "Stop":
                        return "Claude finished responding"
                    case "StopFailure":
                        return "Claude stopped with error"
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

                let event = HookEvent(
                    sessionID: sessionID,
                    eventName: eventName,
                    summary: summary
                )

                return await MainActor.run {
                    let state = capturedAppState.hookState(for: sessionID)
                    let stateBefore = state.claudeState

                    // Append to ring buffer (keep last 50 events per session)
                    state.hookEvents.append(event)
                    if state.hookEvents.count > 50 { state.hookEvents.removeFirst(state.hookEvents.count - 50) }

                    // Update derived state based on event type.
                    // Clear pending notification on ANY event that indicates
                    // Claude moved past the waiting state (except Notification
                    // itself, which may SET the pending state).
                    if eventName != "Notification" && eventName != "PermissionRequest" {
                        state.pendingNotification = nil
                    }

                    switch eventName {
                    case "PreToolUse":
                        let toolName = payload["tool_name"]?.stringValue ?? "unknown"
                        if toolName == "AskUserQuestion" {
                            // Question for the user — set attention state
                            state.pendingNotification = HookNotification(
                                message: "Claude has a question",
                                notificationType: "question"
                            )
                            state.claudeState = .waiting
                            state.lastToolActivity = nil
                        } else {
                            state.lastToolActivity = ToolActivity(
                                toolName: toolName, isActive: true
                            )
                            state.claudeState = .working
                        }

                    case "PostToolUse":
                        let toolName = payload["tool_name"]?.stringValue ?? "unknown"
                        state.lastToolActivity = ToolActivity(
                            toolName: toolName, isActive: false
                        )

                    case "PostToolUseFailure":
                        let toolName = payload["tool_name"]?.stringValue ?? "unknown"
                        state.lastToolActivity = ToolActivity(
                            toolName: toolName, isActive: false
                        )

                    case "Notification":
                        let message = payload["message"]?.stringValue ?? ""
                        let notifType = payload["notification_type"]?.stringValue ?? ""
                        if notifType == "permission_prompt" {
                            // Permission needed — show attention state
                            state.pendingNotification = HookNotification(
                                message: message, notificationType: notifType
                            )
                            state.claudeState = .waiting
                        } else if notifType == "idle_prompt" {
                            // Claude is at the prompt — clear any stale permission notification
                            // but don't change claudeState (Stop already set it to .done)
                            state.pendingNotification = nil
                        }

                    case "PermissionRequest":
                        // Don't override a "question" notification — AskUserQuestion
                        // triggers both PreToolUse and PermissionRequest, and the
                        // question badge is more specific than generic "Permission"
                        if state.pendingNotification?.notificationType != "question" {
                            state.pendingNotification = HookNotification(
                                message: "Permission requested",
                                notificationType: "permission_prompt"
                            )
                        }
                        state.claudeState = .waiting
                        state.lastToolActivity = nil

                    case "UserPromptSubmit":
                        state.claudeState = .working
                        // A new real turn has begun — clear the post-Stop guard so
                        // legitimate subagents in this turn can elevate state again.
                        state.lastTopLevelStopAt = nil

                    case "Stop":
                        state.claudeState = .done
                        state.lastToolActivity = nil
                        state.lastTopLevelStopAt = Date()

                    case "StopFailure":
                        state.claudeState = .waiting
                        state.lastTopLevelStopAt = Date()

                    case "SessionStart":
                        let source = payload["source"]?.stringValue ?? "startup"
                        if source == "resume" {
                            state.claudeState = .done
                        } else {
                            state.claudeState = .idle
                        }
                        state.lastTopLevelStopAt = nil

                    case "SessionEnd":
                        state.claudeState = .idle
                        state.lastToolActivity = nil
                        state.lastTopLevelStopAt = nil

                    case "SubagentStart":
                        // If a top-level Stop has already fired for this turn, the
                        // subagent is background work (e.g. the recap generator from
                        // Claude Code ≥ 2.1.108's awaySummaryEnabled feature). Don't
                        // elevate state — the user is genuinely done.
                        if state.lastTopLevelStopAt == nil {
                            state.claudeState = .working
                        }

                    case "TaskCreated", "TaskCompleted", "SubagentStop":
                        // Stay in working state, but only while the turn is still live.
                        // After a top-level Stop, treat these as background activity
                        // and leave claudeState alone.
                        if state.claudeState != .waiting && state.lastTopLevelStopAt == nil {
                            state.claudeState = .working
                        }

                    default:
                        // PermissionDenied, PreCompact, PostCompact — state change
                        // handled by blanket notification clear above
                        if eventName == "PermissionDenied" {
                            state.claudeState = .working
                            state.lastToolActivity = nil
                        }
                    }

                    // Trigger notification/sound for this event
                    capturedNotifManager?.handleEvent(
                        sessionID: sessionID,
                        eventName: eventName,
                        payload: payload,
                        summary: summary
                    )

                    if hookDebug && state.claudeState != stateBefore {
                        let shortID = String(sessionIDStr.prefix(8))
                        NSLog("[hook-event] session=\(shortID) event=\(eventName) state=\(stateBefore.rawValue)→\(state.claudeState.rawValue)")
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
        TmuxBackend.shared.shutdown()
        GhosttyApp.shared.shutdown()
        NSLog("[Crow] Cleanup complete")
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
