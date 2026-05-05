import AppKit
import Foundation
import CrowCore
import CrowPersistence
import CrowTerminal

/// Simplified session service — CRUD only. Orchestration moved to Claude Code via crow CLI.
@MainActor
final class SessionService {
    private let store: JSONStore
    private let appState: AppState
    let telemetryPort: UInt16?

    init(store: JSONStore, appState: AppState, telemetryPort: UInt16? = nil) {
        self.store = store
        self.appState = appState
        self.telemetryPort = telemetryPort
    }

    // MARK: - Hydrate State from Store

    func hydrateState() {
        let data = store.data
        appState.sessions = data.sessions

        // Backfill provider from ticketURL for sessions that predate provider tracking
        for i in appState.sessions.indices {
            if appState.sessions[i].provider == nil, let url = appState.sessions[i].ticketURL {
                appState.sessions[i].provider = Validation.detectProviderFromURL(url)
            }
        }

        for session in appState.sessions {
            appState.worktrees[session.id] = data.worktrees.filter { $0.sessionID == session.id }
            appState.links[session.id] = data.links.filter { $0.sessionID == session.id }

            var terminals = data.terminals.filter { $0.sessionID == session.id }
            if session.id != AppState.managerSessionID {
                // Backward-compat migration: if no terminal is marked managed,
                // heuristically mark the first "Claude Code" terminal.
                let hasManagedTerminal = terminals.contains { $0.isManaged }
                if !hasManagedTerminal, let idx = terminals.firstIndex(where: {
                    $0.name == "Claude Code" || ($0.command?.contains("claude") ?? false)
                }) {
                    terminals[idx] = SessionTerminal(
                        id: terminals[idx].id, sessionID: terminals[idx].sessionID,
                        name: terminals[idx].name, cwd: terminals[idx].cwd,
                        command: terminals[idx].command, isManaged: true,
                        createdAt: terminals[idx].createdAt
                    )
                }

                // For managed terminals, clear the claude command so they start as plain shells.
                // We'll send `claude --continue` after the surfaces are created.
                for i in terminals.indices {
                    if terminals[i].isManaged,
                       let cmd = terminals[i].command, cmd.contains("claude") {
                        terminals[i] = SessionTerminal(
                            id: terminals[i].id, sessionID: terminals[i].sessionID,
                            name: terminals[i].name, cwd: terminals[i].cwd,
                            command: nil, isManaged: true,
                            createdAt: terminals[i].createdAt
                        )
                    }
                }
            } else {
                // Manager terminal: rebuild its claude command to match the
                // current remoteControlEnabled and managerAutoPermissionMode
                // preferences. Unlike worker sessions the Manager launches
                // claude directly as the shell command, so the stored string
                // needs to be correct before preInitialize runs.
                let claudePath = Self.findClaudeBinary() ?? "claude"
                let rcEnabled = appState.remoteControlEnabled
                let autoMode = appState.managerAutoPermissionMode
                let managerCommand = claudePath + ClaudeLaunchArgs.argsSuffix(
                    remoteControl: rcEnabled,
                    sessionName: "Manager",
                    autoPermissionMode: autoMode
                )
                for i in terminals.indices {
                    if let cmd = terminals[i].command, cmd.contains("claude") {
                        terminals[i] = SessionTerminal(
                            id: terminals[i].id, sessionID: terminals[i].sessionID,
                            name: terminals[i].name, cwd: terminals[i].cwd,
                            command: managerCommand, isManaged: terminals[i].isManaged,
                            createdAt: terminals[i].createdAt
                        )
                        if rcEnabled {
                            appState.remoteControlActiveTerminals.insert(terminals[i].id)
                        }
                    }
                }
            }
            appState.terminals[session.id] = terminals

            // Pre-create terminalReadiness slots for managed work session
            // terminals so the readiness callbacks (Ghostty's surfaceCreated
            // and tmux's onReadinessChanged) have something to update. The
            // actual trackReadiness/registerTerminal call happens in
            // rehydrateTerminalSurface below.
            if session.id != AppState.managerSessionID {
                for terminal in terminals where terminal.isManaged {
                    appState.terminalReadiness[terminal.id] = .uninitialized
                    appState.autoLaunchTerminals.insert(terminal.id)
                }
            }
        }

        // Hydrate global terminals (not tied to any session)
        let globalTerminals = data.terminals.filter { $0.sessionID == AppState.globalTerminalSessionID }
        if !globalTerminals.isEmpty {
            appState.terminals[AppState.globalTerminalSessionID] = globalTerminals
        }

        // Wire readiness callback BEFORE pre-initializing surfaces.
        // preInitialize() triggers viewDidMoveToWindow → createSurface() → surfaceDidCreate()
        // which fires onStateChanged synchronously. The callback must be wired first
        // so the .created and .shellReady events are not lost.
        wireTerminalReadiness()

        // Re-hydrate every persisted terminal — Ghostty rows go through the
        // offscreen-window pre-init path, .tmux rows re-register with a
        // freshly-started tmux server (v1 doesn't keep server alive across
        // launches; spec §12). If a .tmux row's re-registration fails (e.g.
        // tmux uninstalled), silently fall back to .ghostty so the user
        // can still use the app.
        var rehydrationOverwrites: [SessionTerminal] = []
        for session in appState.sessions {
            guard var terminals = appState.terminals[session.id] else { continue }
            let isManagerSession = session.id == AppState.managerSessionID
            for i in terminals.indices {
                let trackReadiness = !isManagerSession && terminals[i].isManaged
                let updated = rehydrateTerminalSurface(terminals[i], trackReadiness: trackReadiness)
                if updated.backend != terminals[i].backend || updated.tmuxBinding != terminals[i].tmuxBinding {
                    rehydrationOverwrites.append(updated)
                }
                terminals[i] = updated
            }
            appState.terminals[session.id] = terminals
        }

        if var globals = appState.terminals[AppState.globalTerminalSessionID] {
            for i in globals.indices {
                let updated = rehydrateTerminalSurface(globals[i], trackReadiness: false)
                if updated.backend != globals[i].backend || updated.tmuxBinding != globals[i].tmuxBinding {
                    rehydrationOverwrites.append(updated)
                }
                globals[i] = updated
            }
            appState.terminals[AppState.globalTerminalSessionID] = globals
        }

        // Persist any backend / windowIndex changes from re-hydration back
        // to the store so a subsequent crash doesn't try to re-register
        // terminals that are already on the fallback backend.
        if !rehydrationOverwrites.isEmpty {
            store.mutate { data in
                for updated in rehydrationOverwrites {
                    if let i = data.terminals.firstIndex(where: { $0.id == updated.id }) {
                        data.terminals[i] = updated
                    }
                }
            }
        }
    }

    /// Re-hydrate one persisted terminal's surface or tmux window on app
    /// launch. Returns the (possibly-modified) row — `.tmux` rows get their
    /// `tmuxBinding.windowIndex` updated to the freshly-registered window;
    /// rows that fail to re-register fall back to `.ghostty` silently.
    @MainActor
    private func rehydrateTerminalSurface(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        switch terminal.backend {
        case .ghostty:
            if trackReadiness {
                TerminalManager.shared.trackReadiness(for: terminal.id)
            }
            TerminalManager.shared.preInitialize(
                id: terminal.id,
                workingDirectory: terminal.cwd,
                command: terminal.command
            )
            return terminal
        case .tmux:
            // Backend not configured this run (flag off, or tmux gone). Pre-
            // initialize a Ghostty surface so the UI can still render the
            // tab — but DO NOT mutate the persisted row. The user may have
            // simply toggled the experimental flag off; if they toggle it
            // back on we want the .tmux marking (and the visual T badge)
            // to come back, not be permanently lost. The visible surface
            // for this run goes through TerminalSurfaceView's
            // cockpitSurface() catch path, which calls
            // TerminalManager.shared.surface(for: id) — which finds the
            // surface we're pre-initializing here.
            guard !TmuxBackend.shared.tmuxBinary.isEmpty else {
                NSLog("[SessionService] persisted .tmux row \(terminal.id) but tmux backend not configured this run — rendering as Ghostty (persisted row unchanged)")
                if trackReadiness {
                    TerminalManager.shared.trackReadiness(for: terminal.id)
                }
                TerminalManager.shared.preInitialize(
                    id: terminal.id,
                    workingDirectory: terminal.cwd,
                    command: terminal.command
                )
                return terminal
            }
            do {
                let binding = try TmuxBackend.shared.registerTerminal(
                    id: terminal.id,
                    name: terminal.name,
                    cwd: terminal.cwd,
                    command: terminal.command,
                    trackReadiness: trackReadiness
                )
                var updated = terminal
                updated.tmuxBinding = binding
                return updated
            } catch {
                // Real registration failure (registerTerminal threw despite
                // a configured backend). This IS a permanent fallback — the
                // tmux server is configured but can't host this row, so
                // persist as .ghostty to avoid retrying every launch.
                NSLog("[SessionService] tmux re-register failed on hydrate (\(error)); silently falling back to .ghostty for \(terminal.id)")
                return rehydrateAsGhosttyFallback(terminal, trackReadiness: trackReadiness)
            }
        }
    }

    @MainActor
    private func rehydrateAsGhosttyFallback(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        var t = terminal
        t.backend = .ghostty
        t.tmuxBinding = nil
        if trackReadiness {
            TerminalManager.shared.trackReadiness(for: t.id)
        }
        TerminalManager.shared.preInitialize(
            id: t.id,
            workingDirectory: t.cwd,
            command: t.command
        )
        return t
    }

    /// Bridge `TerminalManager.SurfaceState` callbacks to `AppState.terminalReadiness`.
    ///
    /// Maps `SurfaceState.created` → `.surfaceCreated` and `.shellReady` → `.shellReady`,
    /// only for terminals already registered in `terminalReadiness` (managed work session terminals).
    /// `.failed` is forwarded unconditionally so the UI can render an error overlay with Retry.
    func wireTerminalReadiness() {
        NSLog("[SessionService] wireTerminalReadiness — setting onStateChanged callback")
        TerminalManager.shared.onStateChanged = { [weak self] terminalID, state in
            guard let self else { return }
            // Only update state for terminals we're tracking (work sessions, not Manager)
            guard let currentState = self.appState.terminalReadiness[terminalID] else { return }
            NSLog("[SessionService] onStateChanged: terminal=\(terminalID), state=\(state), current=\(currentState)")
            switch state {
            case .created:
                // Only advance forward — don't overwrite a later state
                if currentState < .surfaceCreated {
                    self.appState.terminalReadiness[terminalID] = .surfaceCreated
                }
            case .shellReady:
                // Only advance forward — the `send` handler may have already
                // set .claudeLaunched before this timer fires.
                if currentState < .shellReady {
                    self.appState.terminalReadiness[terminalID] = .shellReady
                }
                // Auto-launch Claude now that the shell is ready.
                // Previously this was triggered by the SwiftUI view's onChange,
                // but with offscreen pre-init the view may not be rendered yet.
                self.launchClaude(terminalID: terminalID)
            case .failed:
                NSLog("[SessionService] terminal \(terminalID) failed to launch surface")
                self.appState.terminalReadiness[terminalID] = .failed
                // Do not auto-launch Claude; the UI will surface a Retry button.
            }
        }
        // tmux-backed terminals report readiness via SentinelWaiter rather
        // than the 5s sleep. We funnel that into the same TerminalReadiness
        // state machine so downstream consumers (launchClaude) work without
        // backend-specific branches. Tmux backend skips the .surfaceCreated
        // intermediate state — its window is created synchronously by
        // registerTerminal — so we go straight to .shellReady.
        TmuxBackend.shared.onReadinessChanged = { [weak self] terminalID, readiness in
            guard let self else { return }
            guard let currentState = self.appState.terminalReadiness[terminalID] else { return }
            NSLog("[SessionService] tmux readiness: terminal=\(terminalID), state=\(readiness), current=\(currentState)")
            if readiness == .shellReady, currentState < .shellReady {
                self.appState.terminalReadiness[terminalID] = .shellReady
                self.launchClaude(terminalID: terminalID)
            }
        }
    }

    /// Send `claude --continue` (or a review prompt for review sessions) to a terminal and mark it as launched.
    ///
    /// Writes hook configuration to the session's worktree first so that
    /// Claude Code picks up the hooks on startup.
    func launchClaude(terminalID: UUID) {
        guard appState.terminalReadiness[terminalID] == .shellReady else { return }
        // Only auto-launch for restored/recovered terminals, not brand-new ones
        guard appState.autoLaunchTerminals.remove(terminalID) != nil else { return }

        // Find the session this terminal belongs to
        let sessionID = appState.terminals.first(where: { _, terminals in
            terminals.contains(where: { $0.id == terminalID })
        })?.key

        // Write/refresh hook config for the session's worktree
        if let sessionID,
           let worktree = appState.primaryWorktree(for: sessionID),
           let crowPath = HookConfigGenerator.findCrowBinary() {
            do {
                try HookConfigGenerator.writeHookConfig(
                    worktreePath: worktree.worktreePath,
                    sessionID: sessionID,
                    crowPath: crowPath
                )
            } catch {
                NSLog("[SessionService] Failed to write hook config for session %@: %@",
                      sessionID.uuidString, error.localizedDescription)
            }
        }

        let claudePath = Self.findClaudeBinary() ?? "claude"
        let sessionName = sessionID.flatMap { id in appState.sessions.first(where: { $0.id == id })?.name }
        let rcEnabled = appState.remoteControlEnabled
        let rcArgs = ClaudeLaunchArgs.argsSuffix(remoteControl: rcEnabled, sessionName: sessionName)

        // Build OTEL telemetry env var prefix if enabled
        let envPrefix: String
        if let port = telemetryPort, let sessionID {
            let vars = [
                "CLAUDE_CODE_ENABLE_TELEMETRY=1",
                "OTEL_METRICS_EXPORTER=otlp",
                "OTEL_LOGS_EXPORTER=otlp",
                "OTEL_EXPORTER_OTLP_PROTOCOL=http/json",
                "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(port)",
                "OTEL_RESOURCE_ATTRIBUTES=crow.session.id=\(sessionID.uuidString)",
            ].joined(separator: " ")
            envPrefix = "export \(vars) && "
        } else {
            envPrefix = ""
        }

        // Look up the SessionTerminal so we can route through TerminalRouter
        // (works for both .ghostty and .tmux backends). Falls back to the
        // legacy direct-send path if the terminal is unknown.
        let routedTerminal: SessionTerminal? = sessionID.flatMap { sid in
            appState.terminals[sid]?.first(where: { $0.id == terminalID })
        }
        // Review-kind sessions dispatch their `/crow-review-pr` prompt on first
        // launch only — on subsequent app restarts, fall through to
        // `claude --continue` so the existing conversation resumes instead of
        // re-running the entire review (CROW-224).
        var reviewPromptJustDispatched = false
        let claudeText: String = {
            if let sessionID,
               let session = appState.sessions.first(where: { $0.id == sessionID }),
               session.kind == .review,
               !session.reviewPromptDispatched,
               let worktree = appState.primaryWorktree(for: sessionID) {
                let promptPath = (worktree.worktreePath as NSString).appendingPathComponent(".crow-review-prompt.md")
                reviewPromptJustDispatched = true
                return "\(envPrefix)\(claudePath)\(rcArgs) \"$(cat \(promptPath))\"\n"
            } else {
                return "\(envPrefix)\(claudePath)\(rcArgs) --continue\n"
            }
        }()
        if let routedTerminal {
            TerminalRouter.send(routedTerminal, text: claudeText)
        } else {
            TerminalManager.shared.send(id: terminalID, text: claudeText)
        }

        appState.terminalReadiness[terminalID] = .claudeLaunched
        if rcEnabled {
            appState.remoteControlActiveTerminals.insert(terminalID)
        }

        if reviewPromptJustDispatched, let sessionID {
            if let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) {
                appState.sessions[idx].reviewPromptDispatched = true
            }
            store.mutate { data in
                if let idx = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                    data.sessions[idx].reviewPromptDispatched = true
                }
            }
        }
    }

    /// Discard a failed terminal surface and re-attempt creation.
    ///
    /// Called when the user clicks "Retry" on a terminal whose readiness is `.failed`.
    /// Resets readiness back to `.uninitialized`, re-arms auto-launch (so Claude relaunches
    /// on success), and asks `TerminalManager` to destroy the broken view and re-preInitialize.
    func retryTerminal(terminalID: UUID) {
        let terminal = appState.terminals.values.flatMap { $0 }.first(where: { $0.id == terminalID })
        guard let terminal else {
            NSLog("[SessionService] retryTerminal: no terminal record for \(terminalID)")
            return
        }
        NSLog("[SessionService] retryTerminal(\(terminalID))")
        appState.terminalReadiness[terminalID] = .uninitialized
        if terminal.isManaged {
            appState.autoLaunchTerminals.insert(terminalID)
        }
        TerminalManager.shared.retry(
            id: terminalID,
            workingDirectory: terminal.cwd,
            command: terminal.command
        )
    }

    // MARK: - Ensure Manager Session

    func ensureManagerSession(devRoot: String) {
        let managerID = AppState.managerSessionID
        if !appState.sessions.contains(where: { $0.id == managerID }) {
            let manager = Session(
                id: managerID,
                name: "Manager",
                status: .active
            )
            appState.sessions.insert(manager, at: 0)

            store.mutate { data in
                if !data.sessions.contains(where: { $0.id == managerID }) {
                    data.sessions.insert(manager, at: 0)
                }
            }
        }

        // Ensure manager has a terminal
        if appState.terminals(for: managerID).isEmpty {
            // Find the real claude binary (skip CMUX wrapper)
            let claudePath = Self.findClaudeBinary() ?? "claude"
            let rcEnabled = appState.remoteControlEnabled
            let autoMode = appState.managerAutoPermissionMode
            let managerCommand = claudePath + ClaudeLaunchArgs.argsSuffix(
                remoteControl: rcEnabled,
                sessionName: "Manager",
                autoPermissionMode: autoMode
            )
            let terminal = SessionTerminal(
                sessionID: managerID,
                name: "Manager",
                cwd: devRoot,
                command: managerCommand
            )
            appState.terminals[managerID] = [terminal]

            store.mutate { data in
                if !data.terminals.contains(where: { $0.sessionID == managerID }) {
                    data.terminals.append(terminal)
                }
            }

            if rcEnabled {
                appState.remoteControlActiveTerminals.insert(terminal.id)
            }

            // Pre-initialize in offscreen window so Manager terminal starts immediately
            TerminalManager.shared.preInitialize(id: terminal.id, workingDirectory: devRoot, command: managerCommand)
        }

        // Select Manager on launch (selectedSessionID isn't persisted)
        if appState.selectedSessionID == nil {
            appState.selectedSessionID = managerID
        }
    }

    // MARK: - Delete Session

    /// Delete a session and clean up all associated resources.
    ///
    /// Performs a full cascade: destroys terminal surfaces, removes worktrees from disk
    /// (with branch deletion for non-protected branches), removes hook configs, and cleans
    /// up all in-memory state (sessions, worktrees, links, terminals, hook state, PR status).
    /// The manager session cannot be deleted.
    func deleteSession(id: UUID) async {
        guard id != AppState.managerSessionID else { return }

        let session = appState.sessions.first(where: { $0.id == id })
        let wts = appState.worktrees(for: id)
        let terminals = appState.terminals(for: id)

        // Destroy live terminal surfaces (routes per-backend so .tmux windows are killed too)
        for terminal in terminals {
            TerminalRouter.destroy(terminal)
        }

        if session?.kind == .review {
            // For review sessions, clean up the clone directory
            for wt in wts {
                try? FileManager.default.removeItem(atPath: wt.worktreePath)
                NSLog("[SessionService] Cleaned up review clone: \(wt.worktreePath)")
            }
        } else {
            // Remove worktrees from disk: git worktree remove + branch delete
            // Skip cleanup for worktrees that point at the main repo checkout (not a real worktree)
            for wt in wts {
                let isMainCheckout = wt.isMainRepoCheckout

                if isMainCheckout {
                    NSLog("Skipping worktree cleanup for main checkout: \(wt.worktreePath) (branch: \(wt.branch))")
                    continue
                }

                // Remove our hook config from settings.local.json before deleting the worktree
                HookConfigGenerator.removeHookConfig(worktreePath: wt.worktreePath)

                do {
                    // Remove the worktree
                    let removeResult = try await shell("git", "-C", wt.repoPath, "worktree", "remove", "--force", wt.worktreePath)
                    NSLog("Removed worktree: \(wt.worktreePath) \(removeResult)")

                    // Delete the local branch (only if not a protected branch)
                    if !SessionWorktree.isProtectedBranch(wt.branch) {
                        do {
                            _ = try await shell("git", "-C", wt.repoPath, "branch", "-D", wt.branch)
                        } catch {
                            NSLog("[SessionService] Failed to delete branch \(wt.branch): \(error)")
                        }
                    }

                    // Prune worktree metadata
                    do {
                        _ = try await shell("git", "-C", wt.repoPath, "worktree", "prune")
                    } catch {
                        NSLog("[SessionService] Failed to prune worktree metadata: \(error)")
                    }

                    // Remove the directory if it still exists
                    if FileManager.default.fileExists(atPath: wt.worktreePath) {
                        do {
                            try FileManager.default.removeItem(atPath: wt.worktreePath)
                        } catch {
                            NSLog("[SessionService] Failed to remove directory \(wt.worktreePath): \(error)")
                        }
                    }
                } catch {
                    NSLog("[SessionService] Failed to remove worktree \(wt.worktreePath): \(error)")
                    // Still try to remove the directory (but not if it's the main repo)
                    if FileManager.default.fileExists(atPath: wt.worktreePath) {
                        do {
                            try FileManager.default.removeItem(atPath: wt.worktreePath)
                        } catch {
                            NSLog("[SessionService] Failed to remove directory \(wt.worktreePath): \(error)")
                        }
                    }
                }
            }
        }

        // Remove from state and persistence
        appState.sessions.removeAll { $0.id == id }
        appState.worktrees.removeValue(forKey: id)
        appState.links.removeValue(forKey: id)
        // Clean up auto-launch set for deleted session's terminals
        if let terms = appState.terminals[id] {
            for t in terms { appState.autoLaunchTerminals.remove(t.id) }
        }
        appState.terminals.removeValue(forKey: id)
        appState.activeTerminalID.removeValue(forKey: id)
        appState.removeHookState(for: id)
        appState.prStatus.removeValue(forKey: id)
        appState.isMarkingInReview.removeValue(forKey: id)

        store.mutate { data in
            data.sessions.removeAll { $0.id == id }
            data.worktrees.removeAll { $0.sessionID == id }
            data.links.removeAll { $0.sessionID == id }
            data.terminals.removeAll { $0.sessionID == id }
        }

        if appState.selectedSessionID == id {
            appState.selectedSessionID = appState.sessions.first?.id
        }
    }

    // MARK: - Worktree Safety Checks
    // Protected branch and main-checkout detection are centralized on SessionWorktree in CrowCore.

    private func shell(_ args: String...) async throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SessionService", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return stdout
    }

    /// Resolve org/repo slug from a repo's git remote URL.
    private func resolveRepoSlug(repoPath: String) -> String? {
        guard let output = try? shellSync("git", "-C", repoPath, "remote", "get-url", "origin") else { return nil }
        var url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
        if let match = url.range(of: #"[:/]([^/:]+/[^/:]+)$"#, options: .regularExpression) {
            return String(url[match]).trimmingCharacters(in: CharacterSet(charactersIn: "/:"))
        }
        return nil
    }

    private func shellSync(_ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SessionService", code: Int(process.terminationStatus))
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Orphan Worktree Detection

    /// Scan repos for worktrees that exist on disk but have no session in the store.
    /// Re-imports them as active sessions so they appear in the sidebar.
    /// Runs async and may invoke `gh` CLI for ticket/PR metadata (best-effort).
    func detectOrphanedWorktrees() async {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return }

        // Save current selection so orphan mutations don't reset it
        let savedSelection = appState.selectedSessionID

        // Collect all known worktree paths from the store
        let knownPaths = Set(
            appState.worktrees.values.flatMap { $0 }
                .map { ($0.worktreePath as NSString).standardizingPath }
        )

        let fm = FileManager.default

        // Scan each workspace for repos
        guard let workspaceDirs = try? fm.contentsOfDirectory(atPath: devRoot) else { return }

        for wsDir in workspaceDirs {
            let wsPath = (devRoot as NSString).appendingPathComponent(wsDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: wsPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !config.defaults.excludeDirs.contains(wsDir) else { continue }

            guard let repoDirs = try? fm.contentsOfDirectory(atPath: wsPath) else { continue }
            for repoDir in repoDirs {
                let repoPath = (wsPath as NSString).appendingPathComponent(repoDir)
                let gitPath = (repoPath as NSString).appendingPathComponent(".git")
                var gitIsDir: ObjCBool = false

                // Only process real repos (not worktrees — .git is a directory for repos, a file for worktrees)
                guard fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir), gitIsDir.boolValue else { continue }

                // Get worktrees for this repo
                guard let output = try? await shell("git", "-C", repoPath, "worktree", "list", "--porcelain") else { continue }
                let worktrees = parseWorktreeList(output)

                for wt in worktrees {
                    let standardPath = (wt.path as NSString).standardizingPath

                    // Skip the main checkout
                    if standardPath == (repoPath as NSString).standardizingPath { continue }

                    // Skip if already tracked
                    if knownPaths.contains(standardPath) { continue }

                    // Skip protected branches
                    if SessionWorktree.isProtectedBranch(wt.branch) { continue }

                    // This is an orphan — recover it
                    NSLog("[SessionService] Recovered orphan worktree: \(wt.path) branch=\(wt.branch)")
                    await recoverOrphan(worktreePath: wt.path, branch: wt.branch, repoName: repoDir, repoPath: repoPath)
                }
            }
        }

        // Restore selection if orphan mutations reset it
        if savedSelection != nil && appState.selectedSessionID != savedSelection {
            appState.selectedSessionID = savedSelection
        }
    }

    private struct WorktreeEntry {
        let path: String
        let branch: String
    }

    private func parseWorktreeList(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous entry
                if let path = currentPath, let branch = currentBranch {
                    entries.append(WorktreeEntry(path: path, branch: branch))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch ") {
                currentBranch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        // Don't forget the last entry
        if let path = currentPath, let branch = currentBranch {
            entries.append(WorktreeEntry(path: path, branch: branch))
        }
        return entries
    }

    private struct TicketInfo {
        var number: Int?
        var url: String?
        var title: String?
        var provider: Provider?
    }

    /// Parse ticket number from a directory name and resolve ticket metadata from GitHub.
    private func parseTicketInfo(dirName: String, repoPath: String) async -> TicketInfo {
        var info = TicketInfo()

        let parts = dirName.components(separatedBy: "-")
        // Look for a numeric part after the repo name prefix
        if !parts.isEmpty {
            for (i, part) in parts.enumerated() where i > 0 {
                if let num = Int(part) {
                    info.number = num
                    break
                }
            }
        }

        guard let num = info.number else { return info }

        // Try to construct ticket URL from git remote
        if let remoteURL = try? await shell("git", "-C", repoPath, "remote", "get-url", "origin") {
            var url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
            if url.hasPrefix("git@github.com:") {
                let slug = url.replacingOccurrences(of: "git@github.com:", with: "")
                info.url = "https://github.com/\(slug)/issues/\(num)"
                info.provider = .github
            } else if url.contains("github.com") {
                info.url = "\(url)/issues/\(num)"
                info.provider = .github
            }
        }

        // Try to fetch issue title
        if let issueURL = info.url {
            if let output = try? await shell("gh", "issue", "view", issueURL, "--json", "title"),
               let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String {
                info.title = title
            }
        }

        return info
    }

    /// Check for a pull request on a branch and return a link if found.
    private func findPRLink(branch: String, repoPath: String, sessionID: UUID) async -> SessionLink? {
        guard let repoSlug = resolveRepoSlug(repoPath: repoPath) else { return nil }
        guard let prOutput = try? await shell(
            "gh", "pr", "list", "--repo", repoSlug, "--head", branch,
            "--state", "all", "--json", "number,url,state", "--limit", "1"
        ), let prData = prOutput.data(using: .utf8),
           let prItems = try? JSONSerialization.jsonObject(with: prData) as? [[String: Any]],
           let pr = prItems.first,
           let prNum = pr["number"] as? Int,
           let prURL = pr["url"] as? String else { return nil }

        NSLog("[SessionService] Found PR #\(prNum) for branch '\(branch)'")
        return SessionLink(sessionID: sessionID, label: "PR #\(prNum)", url: prURL, linkType: .pr)
    }

    private func recoverOrphan(worktreePath: String, branch: String, repoName: String, repoPath: String) async {
        let dirName = (worktreePath as NSString).lastPathComponent
        let ticket = await parseTicketInfo(dirName: dirName, repoPath: repoPath)

        let session = Session(
            name: dirName,
            status: .active,
            ticketURL: ticket.url,
            ticketTitle: ticket.title,
            ticketNumber: ticket.number,
            provider: ticket.provider
        )

        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoName,
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            isPrimary: true
        )

        let rawTerminal = SessionTerminal(
            sessionID: session.id,
            name: "Claude Code",
            cwd: worktreePath,
            isManaged: true
        )

        // Collect links
        var links: [SessionLink] = []
        if let ticketURL = ticket.url {
            let label = ticket.number.map { "Issue #\($0)" } ?? "Issue"
            links.append(SessionLink(sessionID: session.id, label: label, url: ticketURL, linkType: .ticket))
        }
        if let prLink = await findPRLink(branch: branch, repoPath: repoPath, sessionID: session.id) {
            links.append(prLink)
        }

        // Backend dispatch — prepareTerminal returns the row with
        // backend/tmuxBinding set and starts the surface or tmux window.
        let terminal = prepareTerminal(rawTerminal, trackReadiness: true)

        // Update state
        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [terminal]
        appState.links[session.id] = links.isEmpty ? nil : links
        appState.terminalReadiness[terminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(terminal.id)

        // Single atomic store mutation
        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(terminal)
            data.links.append(contentsOf: links)
        }

        NSLog("[SessionService] Recovered session '\(dirName)' — ticket=#\(ticket.number.map(String.init) ?? "none") title=\(ticket.title ?? "unknown")")
    }

    // MARK: - Terminal Tab Management

    /// Add a new plain-shell (unmanaged) terminal tab to a session.
    func addTerminal(sessionID: UUID) {
        let cwd = appState.primaryWorktree(for: sessionID)?.worktreePath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let raw = SessionTerminal(sessionID: sessionID, name: "Shell", cwd: cwd, isManaged: false)
        let terminal = prepareTerminal(raw, trackReadiness: false)
        appState.terminals[sessionID, default: []].append(terminal)
        appState.activeTerminalID[sessionID] = terminal.id
        store.mutate { data in data.terminals.append(terminal) }
    }

    /// Close a non-managed terminal tab. Managed terminals cannot be closed individually.
    func closeTerminal(sessionID: UUID, terminalID: UUID) {
        guard let terminals = appState.terminals[sessionID],
              let terminal = terminals.first(where: { $0.id == terminalID }),
              !terminal.isManaged else { return }

        TerminalRouter.destroy(terminal)
        appState.terminals[sessionID]?.removeAll { $0.id == terminalID }
        appState.terminalReadiness.removeValue(forKey: terminalID)
        appState.autoLaunchTerminals.remove(terminalID)

        if appState.activeTerminalID[sessionID] == terminalID {
            appState.activeTerminalID[sessionID] = appState.terminals[sessionID]?.first?.id
        }

        store.mutate { data in data.terminals.removeAll { $0.id == terminalID } }
    }

    /// Rename a terminal tab. Returns `false` if the terminal was not found or the name is invalid.
    @discardableResult
    func renameTerminal(sessionID: UUID, terminalID: UUID, name: String) -> Bool {
        guard Validation.isValidSessionName(name),
              let idx = appState.terminals[sessionID]?.firstIndex(where: { $0.id == terminalID }) else { return false }
        appState.terminals[sessionID]![idx].name = name
        store.mutate { data in
            if let i = data.terminals.firstIndex(where: { $0.id == terminalID }) {
                data.terminals[i].name = name
            }
        }
        return true
    }

    // MARK: - Global Terminal Management

    /// Add a new global terminal tab (not tied to any session).
    func addGlobalTerminal() {
        let sessionID = AppState.globalTerminalSessionID
        let cwd = ConfigStore.loadDevRoot()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let count = appState.terminals(for: sessionID).count
        let raw = SessionTerminal(
            sessionID: sessionID,
            name: "Terminal \(count + 1)",
            cwd: cwd,
            isManaged: false
        )
        let terminal = prepareTerminal(raw, trackReadiness: false)
        appState.terminals[sessionID, default: []].append(terminal)
        appState.activeTerminalID[sessionID] = terminal.id
        store.mutate { data in data.terminals.append(terminal) }
    }

    /// Close a global terminal tab.
    func closeGlobalTerminal(terminalID: UUID) {
        let sessionID = AppState.globalTerminalSessionID
        let terminal = appState.terminals[sessionID]?.first(where: { $0.id == terminalID })
        if let terminal {
            TerminalRouter.destroy(terminal)
        } else {
            TerminalManager.shared.destroy(id: terminalID)
        }
        appState.terminals[sessionID]?.removeAll { $0.id == terminalID }

        if appState.activeTerminalID[sessionID] == terminalID {
            appState.activeTerminalID[sessionID] = appState.terminals[sessionID]?.first?.id
        }

        store.mutate { data in data.terminals.removeAll { $0.id == terminalID } }
    }

    // MARK: - Review Session

    /// Create a review session for an incoming PR review request.
    func createReviewSession(prURL: String) async {
        // Parse org/repo and PR number from URL like "https://github.com/org/repo/pull/123"
        let components = prURL.split(separator: "/")
        guard components.count >= 5,
              let prNumber = Int(components.last ?? "") else {
            NSLog("[SessionService] Could not parse PR URL: \(prURL)")
            return
        }
        let owner = String(components[components.count - 4])
        let repoName = String(components[components.count - 3])
        let repoSlug = "\(owner)/\(repoName)"

        // Fetch PR metadata
        guard let prOutput = try? await shell(
            "gh", "pr", "view", prURL,
            "--json", "title,headRefName,baseRefName,number"
        ) else {
            NSLog("[SessionService] Failed to fetch PR metadata for \(prURL)")
            return
        }

        guard let prData = prOutput.data(using: .utf8),
              let prJSON = try? JSONSerialization.jsonObject(with: prData) as? [String: Any],
              let prTitle = prJSON["title"] as? String,
              let headBranch = prJSON["headRefName"] as? String else {
            NSLog("[SessionService] Failed to parse PR metadata for \(prURL)")
            return
        }

        // Determine clone path
        guard let devRoot = ConfigStore.loadDevRoot() else {
            NSLog("[SessionService] No devRoot configured")
            return
        }
        let reviewsDir = (devRoot as NSString).appendingPathComponent("crow-reviews")
        let cloneDirName = "\(repoName)-pr-\(prNumber)"
        let clonePath = (reviewsDir as NSString).appendingPathComponent(cloneDirName)

        let fm = FileManager.default

        // Ensure reviews directory exists
        try? fm.createDirectory(atPath: reviewsDir, withIntermediateDirectories: true)

        // Clone or update the repo
        if !fm.fileExists(atPath: (clonePath as NSString).appendingPathComponent(".git")) {
            NSLog("[SessionService] Cloning \(repoSlug) into \(clonePath)")
            _ = try? await shell("gh", "repo", "clone", repoSlug, clonePath)
        }

        // Fetch and checkout the PR branch
        _ = try? await shell("git", "-C", clonePath, "fetch", "origin", headBranch)
        _ = try? await shell("git", "-C", clonePath, "checkout", headBranch)
        _ = try? await shell("git", "-C", clonePath, "pull", "origin", headBranch)

        // Write review prompt file into the clone directory
        let promptPath = (clonePath as NSString).appendingPathComponent(".crow-review-prompt.md")
        let reviewPrompt = Self.buildReviewPrompt(prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber)
        try? reviewPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)

        // Copy the crow-review-pr skill into the clone's .claude/skills/ so Claude Code can find it
        let cloneSkillsDir = (clonePath as NSString).appendingPathComponent(".claude/skills/crow-review-pr")
        try? fm.createDirectory(atPath: cloneSkillsDir, withIntermediateDirectories: true)
        let skillContent = Scaffolder.bundledReviewSkill()
        try? skillContent.write(
            toFile: (cloneSkillsDir as NSString).appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        // Copy settings.json into the clone's .claude/ for permissions
        let cloneSettingsDir = (clonePath as NSString).appendingPathComponent(".claude")
        let settingsContent = Scaffolder.bundledSettings()
        try? settingsContent.write(
            toFile: (cloneSettingsDir as NSString).appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8
        )

        // Create session
        let session = Session(
            name: "review-\(repoName)-\(prNumber)",
            kind: .review,
            ticketTitle: prTitle,
            provider: .github
        )

        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoName,
            repoPath: clonePath,
            worktreePath: clonePath,
            branch: headBranch,
            isPrimary: true
        )

        let terminal = SessionTerminal(
            sessionID: session.id,
            name: "Claude Code",
            cwd: clonePath,
            isManaged: true
        )

        let prLink = SessionLink(
            sessionID: session.id,
            label: "PR #\(prNumber)",
            url: prURL,
            linkType: .pr
        )

        // Backend dispatch — prepareTerminal returns the row with
        // backend/tmuxBinding set and starts the surface or tmux window.
        let preparedTerminal = prepareTerminal(terminal, trackReadiness: true)

        // Add to state
        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [preparedTerminal]
        appState.links[session.id] = [prLink]
        appState.terminalReadiness[preparedTerminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(preparedTerminal.id)

        // Persist
        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(preparedTerminal)
            data.links.append(prLink)
        }

        // Select the new session
        appState.selectedSessionID = session.id

        NSLog("[SessionService] Created review session '\(session.name)' for \(prURL)")
    }

    // MARK: - Review Prompt

    /// Build the initial prompt for a review session.
    private static func buildReviewPrompt(prURL: String, prTitle: String, repoSlug: String, prNumber: Int) -> String {
        """
        /crow-review-pr \(prURL)
        """
    }

    // MARK: - Session Status

    /// Update a session's status and persist the change.
    private func updateSessionStatus(_ id: UUID, to status: SessionStatus) {
        guard id != AppState.managerSessionID else { return }

        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].status = status
            appState.sessions[idx].updatedAt = Date()
        }

        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[idx].status = status
                data.sessions[idx].updatedAt = Date()
            }
        }
    }

    func completeSession(id: UUID) {
        updateSessionStatus(id, to: .completed)
    }

    func setSessionInReview(id: UUID) {
        updateSessionStatus(id, to: .inReview)
    }

    func setSessionActive(id: UUID) {
        updateSessionStatus(id, to: .active)
    }

    // MARK: - Persist Current State

    /// Sync all in-memory state back to the JSON store on disk.
    func persistState() {
        store.mutate { data in
            data.sessions = appState.sessions
            // Flatten worktrees, links, terminals from dicts
            data.worktrees = appState.worktrees.values.flatMap { $0 }
            data.links = appState.links.values.flatMap { $0 }
            data.terminals = appState.terminals.values.flatMap { $0 }
        }
    }

    // MARK: - Find Claude Binary

    /// Standard search paths for the Claude CLI binary, in priority order.
    nonisolated static let claudeBinaryCandidates = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ]

    /// Find the real claude binary, skipping CMUX wrapper.
    static func findClaudeBinary() -> String? {
        let candidates = claudeBinaryCandidates
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - VS Code Integration

    /// Find the VS Code `code` CLI binary.
    static func findVSCodeBinary() -> String? {
        let candidates = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/code").path,
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Check if VS Code CLI is available and cache the result in AppState.
    func detectVSCode() {
        appState.vsCodeAvailable = Self.findVSCodeBinary() != nil
    }

    /// Open the primary worktree for a session in VS Code.
    func openInVSCode(sessionID: UUID) {
        guard let codePath = Self.findVSCodeBinary() else { return }
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codePath)
        process.arguments = [wt.worktreePath]
        try? process.run()
    }

    /// Open a terminal window at the primary worktree path for a session.
    func openTerminal(sessionID: UUID) {
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", wt.worktreePath]
        try? process.run()
    }

    // MARK: - Backend dispatch helpers (#198 follow-up)

    /// Decide which backend hosts a brand-new SessionTerminal and prepare it
    /// (register a tmux window or pre-initialize a Ghostty surface). Returns
    /// the (possibly-modified) row with `backend`/`tmuxBinding` set so the
    /// caller can persist it. The Manager terminal is force-pinned to the
    /// Ghostty backend until that migration is done as its own follow-up.
    @MainActor
    private func prepareTerminal(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        var t = terminal
        let useTmux = FeatureFlags.tmuxBackend
            && !TmuxBackend.shared.tmuxBinary.isEmpty
            && t.sessionID != AppState.managerSessionID
        if useTmux {
            do {
                let binding = try TmuxBackend.shared.registerTerminal(
                    id: t.id,
                    name: t.name,
                    cwd: t.cwd,
                    command: t.command,
                    trackReadiness: trackReadiness
                )
                t.backend = .tmux
                t.tmuxBinding = binding
                return t
            } catch {
                NSLog("[SessionService] tmux registerTerminal failed (\(error)); falling back to Ghostty")
            }
        }
        if trackReadiness {
            TerminalManager.shared.trackReadiness(for: t.id)
        }
        TerminalManager.shared.preInitialize(id: t.id, workingDirectory: t.cwd, command: t.command)
        return t
    }
}
