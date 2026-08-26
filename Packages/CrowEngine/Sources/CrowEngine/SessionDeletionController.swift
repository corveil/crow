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

/// Session deletion + orphan-worktree recovery (CROW-1113), extracted from
/// `SessionService`. Owns the full delete cascade (terminal teardown, worktree
/// removal with branch deletion, hook-config + main-clone reconciliation,
/// telemetry-row cleanup) and the launch-time re-import of worktrees on disk
/// with no session record. Behavior-preserving: same review-clone vs
/// git-worktree branch, same protected-branch guard, same detached disk work,
/// same retryable-failure surfacing. Reaches `appState`, the shared **injected**
/// `JSONStore`, `providerManager`, and the shared shell / `prepareTerminal`
/// primitives through an unowned back-reference (ADR 0012 / #728). The public
/// entry points + `performDiskCleanup` / `WorktreeCleanupItem` stay on
/// `SessionService` as facades.
@MainActor
final class SessionDeletionController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var providerManager: ProviderManager? { owner.providerManager }
    private var telemetryDeleteProvider: (@Sendable (UUID) async -> Void)? { owner.telemetryDeleteProvider }

    init(owner: SessionService) { self.owner = owner }

    // MARK: - Delete Session

    /// Snapshot of one worktree's cleanup work, captured on the MainActor and
    /// passed by value into a detached task so disk/git operations don't block UI.
    struct WorktreeCleanupItem: Sendable {
        let repoPath: String
        let worktreePath: String
        let branch: String
        let isMainCheckout: Bool
        /// Agent whose per-worktree hook config to remove before deletion, so
        /// the removal dispatches through the right writer (e.g. Cursor's
        /// `.cursor/hooks.json`, not just Claude's `.claude/settings.local.json`).
        var agentKind: AgentKind = .claudeCode
    }

    /// Delete a session and clean up all associated resources.
    ///
    /// Performs a full cascade: destroys terminal surfaces, removes worktrees from disk
    /// (with branch deletion for non-protected branches), removes hook configs, and cleans
    /// up all in-memory state (sessions, worktrees, links, terminals, hook state, PR status).
    /// The primary Manager session (well-known UUID) cannot be deleted;
    /// additional Manager sessions are deletable.
    ///
    /// The slow filesystem/git work runs in a detached task so the main thread stays
    /// responsive. While cleanup is in flight, `appState.isDeletingSession[id]` is `true`
    /// so the UI can show a spinner. On failure the session is left in place with
    /// `appState.sessionDeletionError[id]` set, allowing the user to retry.
    public func deleteSession(id: UUID) async {
        guard id != AppState.managerSessionID else { return }
        guard appState.isDeletingSession[id] != true else { return }

        let session = appState.sessions.first(where: { $0.id == id })
        let wts = appState.worktrees(for: id)
        let terminals = appState.terminals(for: id)
        let isReview = session?.kind == .review
        let items = wts.map {
            WorktreeCleanupItem(
                repoPath: $0.repoPath,
                worktreePath: $0.worktreePath,
                branch: $0.branch,
                isMainCheckout: $0.isMainRepoCheckout,
                agentKind: session?.agentKind ?? .claudeCode
            )
        }
        // Ownership as it will be *after* this delete: the session is still in
        // `appState` here (it is removed once cleanup succeeds), so counting it
        // as live would let a main clone keep a hook block naming a session that
        // is going away — which is precisely how #897's stale file was created.
        let ownershipAfterDelete = SessionService.HookOwnership.snapshot(
            appState, crowPath: ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot())
        ).excluding(sessionID: id)

        appState.isDeletingSession[id] = true
        appState.sessionDeletionError.removeValue(forKey: id)

        // Slow git + filesystem work runs on a background thread so the main actor
        // stays free to render the spinner and respond to other input.
        let cleanupError: String? = await Task.detached(priority: .utility) {
            Self.performDiskCleanup(
                items: items, isReview: isReview, ownership: ownershipAfterDelete)
        }.value

        if let cleanupError {
            // Leave session, terminals, and persisted state intact so the user can
            // retry. Surface the failure inline; auto-clear after a short delay so
            // the row returns to its normal appearance.
            appState.sessionDeletionError[id] = cleanupError
            appState.isDeletingSession.removeValue(forKey: id)
            Task { [weak appState] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                _ = await MainActor.run { appState?.sessionDeletionError.removeValue(forKey: id) }
            }
            return
        }

        // Cleanup succeeded — destroy live terminal surfaces and tear down state.
        for terminal in terminals {
            TerminalRouter.destroy(terminal)
        }

        appState.sessions.removeAll { $0.id == id }
        appState.worktrees.removeValue(forKey: id)
        appState.links.removeValue(forKey: id)
        // Clean up auto-launch and remote-control sets for deleted session's terminals
        if let terms = appState.terminals[id] {
            for t in terms {
                appState.autoLaunchTerminals.remove(t.id)
                appState.remoteControlActiveTerminals.remove(t.id)
            }
        }
        appState.terminals.removeValue(forKey: id)
        appState.activeTerminalID.removeValue(forKey: id)
        appState.removeHookState(for: id)
        appState.prStatus.removeValue(forKey: id)
        appState.autoMergeState.removeValue(forKey: id)
        appState.autoRebaseState.removeValue(forKey: id)
        appState.isMarkingInReview.removeValue(forKey: id)
        appState.isMarkingIssueDone.removeValue(forKey: id)
        appState.isAddingMergeLabel.removeValue(forKey: id)
        appState.isDeletingSession.removeValue(forKey: id)

        store.mutate { data in
            data.sessions.removeAll { $0.id == id }
            data.worktrees.removeAll { $0.sessionID == id }
            data.links.removeAll { $0.sessionID == id }
            data.terminals.removeAll { $0.sessionID == id }
            data.hookStates?[id.uuidString] = nil
        }

        // Drop the session's raw telemetry rows now that the session itself is
        // gone (#772). Only after the cleanup succeeded — a retryable failure
        // returns above with the session intact, and its metrics with it. Any
        // `SessionAnalyticsSnapshot` is deliberately left alone: the scorecard
        // aggregates historical work whose sessions have since been deleted.
        if let telemetryDeleteProvider {
            await telemetryDeleteProvider(id)
        }

        if appState.selectedSessionID == id {
            appState.selectedSessionID = appState.sessions.first?.id
        }
    }

    /// Run the on-disk portion of session deletion. Safe to call from any thread —
    /// touches no MainActor state. Returns `nil` on success, or a short error
    /// string describing the first fatal failure (a worktree that could be removed
    /// neither by `git worktree remove` nor by direct directory removal).
    /// Soft failures (branch delete, prune) only get NSLog'd.
    nonisolated static func performDiskCleanup(
        items: [WorktreeCleanupItem],
        isReview: Bool,
        ownership: SessionService.HookOwnership
    ) -> String? {
        var firstFatalError: String? = nil

        for item in items {
            // Review clones are standalone `git clone` checkouts (not `git worktree add`
            // artifacts) and always have repoPath == worktreePath, which would otherwise
            // trip the main-checkout guard below and leave the clone orphaned on disk.
            if isReview {
                guard FileManager.default.fileExists(atPath: item.worktreePath) else { continue }
                do {
                    try FileManager.default.removeItem(atPath: item.worktreePath)
                    CrowLog.info("[SessionService] Cleaned up review clone: \(item.worktreePath)")
                } catch {
                    let msg = "Failed to remove review clone: \(error.localizedDescription)"
                    CrowLog.info("[SessionService] \(msg) (\(item.worktreePath))")
                    if firstFatalError == nil { firstFatalError = msg }
                }
                continue
            }

            if item.isMainCheckout {
                CrowLog.info("Skipping worktree cleanup for main checkout: \(item.worktreePath) (branch: \(item.branch))")
                continue
            }

            // Remove our hook config before deleting the worktree, dispatching
            // through the session's own agent so non-Claude configs (e.g.
            // Cursor's `.cursor/hooks.json`) are cleaned by the right writer,
            // not just `.claude/settings.local.json`.
            let cleanupWriter = AgentRegistry.shared.agent(for: item.agentKind)?.hookConfigWriter
                ?? ClaudeHookConfigWriter()
            cleanupWriter.removeHookConfig(worktreePath: item.worktreePath)

            // …and from the **main clone**, which this worktree's sessions were
            // also loading (#915). Removing the worktree does not remove the
            // block that named it, so without this a reaped worktree can leave
            // its binary/session id behind in a long-lived clone — exactly the
            // April artifact in #897 — until the next boot sweep. `repoPath` is
            // the clone, and doing it here rather than after `git worktree
            // remove` means we don't need the (soon-deleted) worktree's `.git`
            // to resolve it. Non-fatal: this loop's first hard error aborts the
            // whole session delete, and a settings file is not worth that.
            SessionService.reconcileMainCloneHooks(directory: item.repoPath, ownership: ownership)

            var gitRemoveFailed = false
            do {
                let removeResult = try SessionService.runShellSync(["git", "-C", item.repoPath, "worktree", "remove", "--force", item.worktreePath])
                CrowLog.info("Removed worktree: \(item.worktreePath) \(removeResult)")

                if !SessionWorktree.isProtectedBranch(item.branch) {
                    do {
                        _ = try SessionService.runShellSync(["git", "-C", item.repoPath, "branch", "-D", item.branch])
                    } catch {
                        CrowLog.info("[SessionService] Failed to delete branch \(item.branch): \(error)")
                    }
                }

                do {
                    _ = try SessionService.runShellSync(["git", "-C", item.repoPath, "worktree", "prune"])
                } catch {
                    CrowLog.info("[SessionService] Failed to prune worktree metadata: \(error)")
                }
            } catch {
                gitRemoveFailed = true
                CrowLog.info("[SessionService] Failed to remove worktree \(item.worktreePath): \(error)")
            }

            // Either way, ensure the directory is gone.
            if FileManager.default.fileExists(atPath: item.worktreePath) {
                do {
                    try FileManager.default.removeItem(atPath: item.worktreePath)
                } catch {
                    CrowLog.info("[SessionService] Failed to remove directory \(item.worktreePath): \(error)")
                    if gitRemoveFailed && firstFatalError == nil {
                        firstFatalError = "Could not remove worktree at \(item.worktreePath): \(error.localizedDescription)"
                    }
                }
            }
        }

        return firstFatalError
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
    public func detectOrphanedWorktrees() async {
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
                guard let output = try? await owner.shell("git", "-C", repoPath, "worktree", "list", "--porcelain") else { continue }
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
                    CrowLog.info("[SessionService] Recovered orphan worktree: \(wt.path) branch=\(wt.branch)")
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
        if let remoteURL = try? await owner.shell("git", "-C", repoPath, "remote", "get-url", "origin") {
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

        // Try to fetch issue title via the TaskBackend abstraction (ADR 0005).
        // Falls through silently if no `providerManager` is wired or the fetch
        // fails — title stays whatever the dir-name parser produced.
        if let issueURL = info.url, let manager = providerManager {
            let backend = manager.taskBackend(forURL: issueURL)
            if let ticket = try? await backend.fetchTask(url: issueURL) {
                info.title = ticket.title
            }
        }

        return info
    }

    /// Check for a pull request on a branch and return a link if found.
    private func findPRLink(branch: String, repoPath: String, sessionID: UUID, provider: Provider) async -> SessionLink? {
        guard let repoSlug = resolveRepoSlug(repoPath: repoPath) else { return nil }
        // Route through CodeBackend.linkedPR (ADR 0005). Without a wired
        // providerManager we can't look up a PR; that's the caller's signal
        // to skip the link.
        guard let manager = providerManager,
              let backend = manager.codeBackend(for: provider),
              let pr = try? await backend.linkedPR(repo: repoSlug, branch: branch) else {
            return nil
        }
        CrowLog.info("[SessionService] Found PR #\(pr.number) for branch '\(branch)'")
        return SessionLink(sessionID: sessionID, label: "PR #\(pr.number)", url: pr.url, linkType: .pr)
    }


    private func recoverOrphan(worktreePath: String, branch: String, repoName: String, repoPath: String) async {
        let dirName = (worktreePath as NSString).lastPathComponent
        let ticket = await parseTicketInfo(dirName: dirName, repoPath: repoPath)

        // A task-only tracker (Jira/Corveil) has no code backend — pair it with
        // the workspace's code provider for PR/git flows.
        let codeProvider = SessionService.resolvedCodeProvider(forTask: ticket.provider, worktreePath: worktreePath)
        let session = Session(
            name: dirName,
            status: .active,
            agentKind: appState.agentKind(for: .work),
            ticketURL: ticket.url,
            ticketTitle: ticket.title,
            ticketNumber: ticket.number,
            provider: ticket.provider,
            codeProvider: codeProvider
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
            name: session.agentKind.displayName,
            cwd: worktreePath,
            isManaged: true
        )

        // Collect links
        var links: [SessionLink] = []
        if let ticketURL = ticket.url {
            let label = ticket.number.map { "Issue #\($0)" } ?? "Issue"
            links.append(SessionLink(sessionID: session.id, label: label, url: ticketURL, linkType: .ticket))
        }
        if let prLink = await findPRLink(branch: branch, repoPath: repoPath, sessionID: session.id, provider: session.codeProvider ?? session.provider ?? .github) {
            links.append(prLink)
        }

        // Backend dispatch — prepareTerminal returns the row with
        // backend/tmuxBinding set and starts the surface or tmux window.
        let terminal = owner.prepareTerminal(rawTerminal, trackReadiness: true)

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

        CrowLog.info("[SessionService] Recovered session '\(dirName)' — ticket=#\(ticket.number.map(String.init) ?? "none") title=\(ticket.title ?? "unknown")")
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    /// Snapshot of one worktree's cleanup work (see
    /// `SessionDeletionController.WorktreeCleanupItem`).
    typealias WorktreeCleanupItem = SessionDeletionController.WorktreeCleanupItem

    public func deleteSession(id: UUID) async {
        await deletion.deleteSession(id: id)
    }

    public func detectOrphanedWorktrees() async {
        await deletion.detectOrphanedWorktrees()
    }

    /// Run the on-disk portion of session deletion (see
    /// `SessionDeletionController.performDiskCleanup`).
    nonisolated static func performDiskCleanup(
        items: [WorktreeCleanupItem], isReview: Bool, ownership: HookOwnership
    ) -> String? {
        SessionDeletionController.performDiskCleanup(
            items: items, isReview: isReview, ownership: ownership)
    }
}
