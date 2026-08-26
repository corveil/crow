import Foundation
import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowGit
import CrowGrok
import CrowPersistence
import CrowProvider
import CrowTerminal

/// Thin session orchestrator. Owns session CRUD + persist/hydrate wiring and the
/// shared shell/terminal primitives, and delegates each larger concern to a
/// focused, single-file collaborator (CROW-1113, mirroring the CROW-1094
/// `IssueTracker` split): surfaces/crash recovery, agent launch, Manager
/// lifecycle, agent handoff, review-clone prep, session deletion, scheduled
/// jobs, and analytics. Each collaborator is a `@MainActor` type holding an
/// `unowned` back-reference to this service, reaching the shared **injected**
/// `JSONStore` / `AppState` / `HostBridge` through it (ADR 0012 / #728 — never a
/// throwaway `JSONStore()`), and re-exposes the statics/APIs other modules call
/// through an `extension SessionService { … }` facade so callers don't churn.
@MainActor
public final class SessionService {
    let store: JSONStore
    let appState: AppState
    public let telemetryPort: UInt16?
    /// Backend factory for ticket/PR lookups during recovery. Optional so unit-tests
    /// that don't exercise recovery paths needn't construct one. See ADR 0005.
    let providerManager: ProviderManager?
    /// Fresh session aggregate from telemetry.db, used when persisting the
    /// end-of-session analytics snapshot (#690). Optional so unit tests and
    /// telemetry-off launches fall back to the in-memory aggregate.
    let analyticsProvider: (@Sendable (UUID) async -> SessionAnalytics?)?
    /// Crow session IDs with telemetry rows in telemetry.db, driving the
    /// snapshot backfill (#745). Optional so unit tests and telemetry-off
    /// launches make the backfill a no-op.
    let telemetrySessionIDsProvider: (@Sendable () async -> [UUID])?
    /// Windowed per-Manager aggregate from telemetry.db for the weekly usage
    /// bucket (#745; the session id became a parameter in CROW-983, when the
    /// rollup stopped assuming a single Manager). Optional for the same reason.
    let managerUsageProvider: (@Sendable (UUID, Date, Date) async -> SessionAnalytics)?
    /// Drops a session's rows from telemetry.db as part of `deleteSession`
    /// (#772). Injected here rather than at each call site so all three delete
    /// paths — the daemon's `delete-session` handler, the engine-router
    /// fallback, and the auto-cleanup reaper — clean up through one choke
    /// point. Optional: telemetry-off hosts and unit tests pass nil.
    let telemetryDeleteProvider: (@Sendable (UUID) async -> Void)?
    /// Host-only affordances (clipboard, editor/terminal launching, hook
    /// notifications). Defaults to a headless no-op so tests and the daemon
    /// need not supply one; the macOS app injects a real `AppHostBridge`.
    let hostBridge: HostBridge

    public init(
        store: JSONStore,
        appState: AppState,
        telemetryPort: UInt16? = nil,
        providerManager: ProviderManager? = nil,
        analyticsProvider: (@Sendable (UUID) async -> SessionAnalytics?)? = nil,
        telemetrySessionIDsProvider: (@Sendable () async -> [UUID])? = nil,
        managerUsageProvider: (@Sendable (UUID, Date, Date) async -> SessionAnalytics)? = nil,
        telemetryDeleteProvider: (@Sendable (UUID) async -> Void)? = nil,
        hostBridge: HostBridge = NoopHostBridge()
    ) {
        self.store = store
        self.appState = appState
        self.telemetryPort = telemetryPort
        self.providerManager = providerManager
        self.analyticsProvider = analyticsProvider
        self.telemetrySessionIDsProvider = telemetrySessionIDsProvider
        self.managerUsageProvider = managerUsageProvider
        self.telemetryDeleteProvider = telemetryDeleteProvider
        self.hostBridge = hostBridge
    }

    // MARK: - Collaborators (CROW-1113)
    //
    // Each concern lives in its own file as a `@MainActor` type holding an
    // `unowned` back-ref to this service; `lazy` so it can take that ref to a
    // fully-initialized `self`. The public/internal entry points other modules
    // call stay on `SessionService` as facades (see each collaborator file's
    // `extension SessionService`), so callers don't churn.

    /// Analytics snapshots + Manager weekly usage rollups (CROW-1113).
    lazy var analytics = SessionAnalyticsController(owner: self)

    /// Scheduled-job runs (CROW-317) — worktree + session + clone-on-demand.
    lazy var jobs = JobRunner(owner: self)

    /// Review-session creation + clone prep + per-agent strips (CROW-1113).
    lazy var review = ReviewSessionController(owner: self)

    /// Session deletion + orphan-worktree recovery (CROW-1113).
    lazy var deletion = SessionDeletionController(owner: self)

    /// Manager lifecycle + AI-gateway resolution (CROW-1113).
    lazy var manager = ManagerSessionController(owner: self)

    /// Agent launch gate + launchAgent + deferred paste (CROW-1113).
    lazy var launch = AgentLaunchController(owner: self)

    /// Mid-flight agent handoff orchestration (CROW-627; CROW-1113).
    lazy var handoff = AgentHandoffController(owner: self)

    /// tmux surface lifecycle + crash recovery (CROW-1113).
    lazy var surfaces = SessionSurfaceController(owner: self)

    /// Upgrade the well-known primary Manager session from `.work` (how it was
    /// persisted before `SessionKind.manager` existed) to `.manager`. Returns
    /// `true` when a migration was applied. Pure/`nonisolated` so it can run on
    /// both the in-memory `appState.sessions` and the persisted `store` copy,
    /// and be unit-tested without a live app.
    nonisolated static func migrateLegacyManagerKind(_ sessions: inout [Session]) -> Bool {
        guard let idx = sessions.firstIndex(where: {
            $0.id == AppState.managerSessionID && $0.kind != .manager
        }) else { return false }
        sessions[idx].kind = .manager
        return true
    }

    /// One-time backfill of `reviewAuthor` for legacy review sessions that
    /// predate the field. For each review session missing an author, re-fetch it
    /// from the PR (via the stored `.pr` link) and persist. Runs detached and is
    /// idempotent — after the first fill the value is on disk (CROW-593).
    func backfillReviewAuthors() {
        guard let manager = providerManager else { return }
        let targets: [(id: UUID, url: String)] = appState.sessions.compactMap { session in
            guard session.kind == .review, (session.reviewAuthor ?? "").isEmpty,
                  let link = store.data.links.first(where: { $0.sessionID == session.id && $0.linkType == .pr })
            else { return nil }
            return (session.id, link.url)
        }
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            for target in targets {
                guard let backend = manager.codeBackend(for: .github),
                      let meta = try? await backend.fetchPRMetadata(prURL: target.url),
                      !meta.author.isEmpty else { continue }
                if let i = appState.sessions.firstIndex(where: { $0.id == target.id }) {
                    appState.sessions[i].reviewAuthor = meta.author
                }
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == target.id }) {
                        data.sessions[i].reviewAuthor = meta.author
                    }
                }
            }
        }
    }

    // MARK: - Shared shell / provider primitives
    // Cross-concern helpers kept on `SessionService` (rather than a collaborator)
    // because they are `nonisolated`, so they cannot route through a MainActor
    // `lazy` collaborator without a data race. `runShellSync`/`runShellAsync`
    // are the async/sync Process runners the deletion, review-clone, and job
    // paths share; `resolvedCodeProvider` is used by both hydrate and orphan
    // recovery.

    /// Synchronous shell helper safe to call from any thread. Used by
    /// `performDiskCleanup` while running on a detached task.
    nonisolated static func runShellSync(_ args: [String]) throws -> String {
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
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
        return stdout
    }

    /// Run `/usr/bin/env <args...>` and return stdout. Marked `nonisolated` and
    /// implemented via `withCheckedThrowingContinuation` + `terminationHandler`
    /// so `await shell(...)` truly suspends the calling task instead of
    /// blocking on `waitUntilExit()`. This is what keeps the main actor free
    /// during review-session kickoff (#404); the prior implementation pinned
    /// every git/gh call to the main thread.
    nonisolated func shell(env: [String: String] = [:], _ args: String...) async throws -> String {
        let resolvedEnv = env.isEmpty
            ? ShellEnvironment.shared.env
            : ShellEnvironment.shared.merging(env)
        return try await Self.runShellAsync(env: resolvedEnv, args: args)
    }

    /// Shared async Process runner. Hands ownership of the pipes/process to
    /// the termination handler so reads happen after exit (no deadlock from
    /// a full pipe blocking the child) and the continuation is resumed
    /// exactly once.
    nonisolated static func runShellAsync(env: [String: String], args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.environment = env
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SessionService",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                // Clear the termination handler so it can't fire after we
                // resume here — Process invokes it on launch failure paths
                // in some macOS versions, which would double-resume.
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }


    /// Resolve the code provider for a task-only tracker (Jira/Corveil) from the
    /// workspace that owns a worktree (`devRoot/<workspace>/<worktree>`). Returns
    /// `nil` for code-bearing task providers (they follow `provider`), and the
    /// workspace's own code provider otherwise — so a Jira-task + GitLab-code
    /// workspace gets `glab`, not a hardcoded `gh`. Falls back to `.github` when
    /// the workspace can't be resolved.
    public static func resolvedCodeProvider(forTask taskProvider: Provider?, worktreePath: String?) -> Provider? {
        guard taskProvider?.isTaskOnly == true else { return nil }
        guard let worktreePath else { return .github }
        let workspaceName = ((worktreePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot),
              let ws = config.workspaces.first(where: { $0.name == workspaceName }),
              let codeProvider = Provider(rawValue: ws.provider) else {
            return .github
        }
        return codeProvider
    }


    // MARK: - Terminal Tab Management

    /// Add a new plain-shell (unmanaged) terminal tab to a session.
    public func addTerminal(sessionID: UUID) {
        let cwd = appState.primaryWorktree(for: sessionID)?.worktreePath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let raw = SessionTerminal(sessionID: sessionID, name: "Shell", cwd: cwd, isManaged: false)
        let terminal = prepareTerminal(raw, trackReadiness: false)
        appState.terminals[sessionID, default: []].append(terminal)
        appState.activeTerminalID[sessionID] = terminal.id
        store.mutate { data in data.terminals.append(terminal) }
    }

    /// Close a non-managed terminal tab. Managed terminals cannot be closed individually.
    public func closeTerminal(sessionID: UUID, terminalID: UUID) {
        guard let terminals = appState.terminals[sessionID],
              let terminal = terminals.first(where: { $0.id == terminalID }),
              !terminal.isManaged else { return }

        appState.terminals[sessionID]?.removeAll { $0.id == terminalID }
        appState.terminalReadiness.removeValue(forKey: terminalID)
        appState.autoLaunchTerminals.remove(terminalID)

        if appState.activeTerminalID[sessionID] == terminalID {
            appState.activeTerminalID[sessionID] = appState.terminals[sessionID]?.first?.id
        }

        store.mutate { data in data.terminals.removeAll { $0.id == terminalID } }

        // Defer the backing destroy so SwiftUI's render pass detaches the
        // terminal surface from the view hierarchy before we kill the tmux
        // window. Destroying while AppKit still holds the view risks a
        // WebKit callback landing on a freed surface (issue #282).
        //
        // Note: single-tick defer is a conservative first attempt. Neither
        // Combine nor DispatchQueue strictly guarantee ordering against the
        // SwiftUI CATransaction commit; if #282 recurs the next step is a
        // two-tick defer (nested `DispatchQueue.main.async`) or moving the
        // destroy to a runloop-quiesce sweep.
        DispatchQueue.main.async {
            TerminalRouter.destroy(terminal)
        }
    }

    /// Rename a terminal tab. Returns `false` if the terminal was not found or the name is invalid.
    @discardableResult
    public func renameTerminal(sessionID: UUID, terminalID: UUID, name: String) -> Bool {
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

    /// Rename a session. Returns `false` if the session was not found or the name is invalid.
    @discardableResult
    public func renameSession(sessionID: UUID, name: String) -> Bool {
        guard Validation.isValidSessionName(name),
              let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        appState.sessions[idx].name = name
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                data.sessions[i].name = name
            }
        }
        syncAgentSessionName(sessionID: sessionID, newName: name)
        return true
    }

    /// Terminals to push a Remote-Control `/rename` into for a worker session:
    /// those launched with `--rc` (tracked in `remoteControlActiveTerminals`).
    /// That's the Claude Code instance whose claude.ai panel label is fixed at
    /// launch. Manager terminals are handled separately by
    /// `agentRenameTargets` (CROW-629) so Cursor/Codex/OpenCode Managers get
    /// `/rename` without being marked RC-active. Pure/`nonisolated` so it can
    /// be unit-tested without a live app.
    nonisolated static func remoteControlRenameTargets(
        terminals: [SessionTerminal],
        rcActiveTerminals: Set<UUID>
    ) -> [SessionTerminal] {
        terminals.filter { rcActiveTerminals.contains($0.id) }
    }

    /// Terminals that should receive an agent `/rename` after a Crow session
    /// rename (CROW-629). Decouples session-title sync from the Remote Control
    /// badge: Managers forward to command-bearing agent terminals when the
    /// agent supports rename (Cursor / Codex / OpenCode have no `--rc` but
    /// still expose `/rename`) — unmanaged Shell tabs (`command == nil`) are
    /// excluded so `/rename` is not pasted into a live shell; workers stay
    /// gated on `remoteControlActiveTerminals` so Claude's claude.ai panel
    /// label keeps syncing. Pure/`nonisolated` for unit tests.
    nonisolated static func agentRenameTargets(
        session: Session,
        terminals: [SessionTerminal],
        rcActiveTerminals: Set<UUID>,
        supportsRename: Bool
    ) -> [SessionTerminal] {
        guard supportsRename else { return [] }
        if session.isManager {
            // Same discriminator RC bookkeeping uses: only terminals that
            // launched an agent carry a `command`. Extra Shell tabs must not
            // receive `/rename` (would run as a bogus shell command).
            return terminals.filter { $0.command != nil }
        }
        return remoteControlRenameTargets(
            terminals: terminals,
            rcActiveTerminals: rcActiveTerminals
        )
    }

    /// After an in-app rename, push the new name to the running agent via its
    /// `/rename` slash command so the agent session title (and, for Claude
    /// `--rc`, the claude.ai Remote Control panel label) stays in sync.
    /// No-op when the agent has no rename surface, the session has no eligible
    /// terminal, or a terminal's surface isn't ready to receive. The name is
    /// already validated (no control characters) by the caller.
    private func syncAgentSessionName(sessionID: UUID, newName: String) {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let slash = AgentRegistry.shared.agent(for: session.agentKind)?
                .sessionRenameSlashCommand(newName: newName) else { return }
        let targets = Self.agentRenameTargets(
            session: session,
            terminals: appState.terminals(for: sessionID),
            rcActiveTerminals: appState.remoteControlActiveTerminals,
            supportsRename: true
        )
        for terminal in targets where TerminalRouter.canSend(terminal) {
            TerminalRouter.send(terminal, text: slash)
        }
    }

    // MARK: - Global Terminal Management


    // MARK: - Session Status

    /// Update a session's status and persist the change.
    private func updateSessionStatus(_ id: UUID, to status: SessionStatus) {
        // Managers stay always-active; never transition them through the
        // review/complete lifecycle.
        guard !appState.isManagerSession(id) else { return }

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

        scheduleAnalyticsSnapshot(for: id, status: status)
    }

    /// Lock or unlock a session to exempt it from (or restore it to) the
    /// retention cleanup reaper (CROW-569 shipped this as "pin"; CROW-573 renamed
    /// it to "lock"). Deliberately leaves `updatedAt` untouched so the retention
    /// clock is preserved — unlocking restores the session's original age-based
    /// eligibility rather than resetting it.
    public func setLocked(id: UUID, locked: Bool) {
        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].locked = locked
        }
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[idx].locked = locked
            }
        }
    }

    /// Set or clear the session's org-goal tag (#696, ADR 0008 follow-up 8).
    /// `nil` clears the tag back to untagged/neutral. The tag feeds
    /// `Session.alignmentWeight`, which is copied onto the analytics snapshot
    /// when the session reaches a terminal status.
    public func setOrgGoal(id: UUID, goal: String?) {
        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].orgGoal = goal
            appState.sessions[idx].updatedAt = Date()
        }
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[idx].orgGoal = goal
                data.sessions[idx].updatedAt = Date()
            }
        }
    }

    public func completeSession(id: UUID) {        updateSessionStatus(id, to: .completed)
    }

    public func setSessionInReview(id: UUID) {
        updateSessionStatus(id, to: .inReview)
    }

    public func setSessionActive(id: UUID) {
        updateSessionStatus(id, to: .active)
    }

    // MARK: - Persist Current State

    /// Sync all in-memory state back to the JSON store on disk.
    public func persistState() {
        // Snapshot color-driving hook state so a clean quit (this runs from
        // applicationWillTerminate) captures the final state for relaunch (#367).
        let hookSnapshots = appState.allHookStateSnapshots()
        store.mutate { data in
            data.sessions = appState.sessions
            // Flatten worktrees, links, terminals from dicts
            data.worktrees = appState.worktrees.values.flatMap { $0 }
            data.links = appState.links.values.flatMap { $0 }
            data.terminals = appState.terminals.values.flatMap { $0 }
            data.hookStates = Dictionary(
                uniqueKeysWithValues: hookSnapshots.map { ($0.key.uuidString, $0.value) })

            // Analytics-snapshot quit-race backfill (#690): a terminal status
            // transition spawns the snapshot write asynchronously, so a fast
            // quit can beat it. Backfill synchronously from the in-memory
            // aggregate — but never overwrite an existing snapshot, which is
            // DB-derived and at least as fresh.
            for session in appState.sessions
            where (session.status == .completed || session.status == .archived)
                && !session.isManager {
                let key = session.id.uuidString
                guard data.analyticsSnapshots?[key] == nil,
                      let analytics = appState.existingHookState(for: session.id)?.analytics,
                      !analytics.isEmpty else { continue }
                var snapshots = data.analyticsSnapshots ?? [:]
                snapshots[key] = SessionAnalyticsSnapshot(
                    sessionID: session.id, endedAt: session.updatedAt,
                    status: session.status, analytics: analytics,
                    compactionCount: appState.existingHookState(for: session.id)?
                        .compactionCount ?? 0,
                    wallClockDurationSeconds: session.wallClockDuration,
                    alignmentWeight: session.alignmentWeight,
                    orgGoal: session.orgGoal)
                data.analyticsSnapshots = snapshots
            }
        }
        // Keep the scorecard mirror in sync with any quit-race backfills.
        appState.analyticsSnapshots = store.data.analyticsSnapshots ?? [:]
    }

    // MARK: - Find Claude Binary

    /// Standard search paths for the Claude CLI binary, in priority order.
    public nonisolated static let claudeBinaryCandidates = [
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

    /// Find the VS Code `code` CLI binary. Pure (no actor state), so `nonisolated`
    /// — the headless daemon calls it off the main actor to gate/launch VS Code.
    public nonisolated static func findVSCodeBinary() -> String? {
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
    public func detectVSCode() {
        appState.vsCodeAvailable = Self.findVSCodeBinary() != nil
    }

    /// Open the primary worktree for a session in VS Code (via the host).
    public func openInVSCode(sessionID: UUID) {
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }
        hostBridge.openInEditor(path: wt.worktreePath)
    }

    /// Open a terminal window at the primary worktree path for a session (via the host).
    public func openTerminal(sessionID: UUID) {
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }
        hostBridge.openTerminalWindow(path: wt.worktreePath)
    }

    // MARK: - Backend dispatch helpers (#198 follow-up)

    /// Register a brand-new SessionTerminal's tmux window and return the row
    /// with its `tmuxBinding` set so the caller can persist it. The Manager
    /// terminal goes through this same path as every other session (#314); for
    /// it, `registerTerminal` pastes the stored `claude` command into the tmux
    /// window directly. If tmux is unavailable or registration fails the row is
    /// returned unbound and simply won't render.
    @MainActor
    func prepareTerminal(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        var t = terminal
        guard !TmuxBackend.shared.tmuxBinary.isEmpty else {
            CrowLog.info("[SessionService] tmux not configured; terminal \(t.id) will not render")
            return t
        }
        let session = appState.sessions.first(where: { $0.id == t.sessionID })
        do {
            let binding = try TmuxBackend.shared.registerTerminal(
                id: t.id,
                name: t.name,
                cwd: t.cwd,
                command: t.command,
                trackReadiness: trackReadiness,
                agentKind: session?.agentKind,
                // Covers the Manager, whose terminal is built without
                // `isManaged` but still runs a repainting agent (ADR-0013).
                agentSurface: t.isAgentSurface(session: session),
                usesAlternateScreen: AgentRegistry.shared.usesAlternateScreen(for: session?.agentKind),
                extraEnv: Self.artifactsEnv(sessionID: t.sessionID)
            )
            t.tmuxBinding = binding
        } catch {
            CrowLog.info("[SessionService] tmux registerTerminal failed (\(error)); terminal \(t.id) will not render")
        }
        return t
    }
}

