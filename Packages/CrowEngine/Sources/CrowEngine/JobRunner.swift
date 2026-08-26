import Foundation
import CrowCore
import CrowGit
import CrowPersistence

/// Scheduled-job runs (CROW-317), extracted from `SessionService` (CROW-1113).
/// Creates a fresh git worktree + session + managed agent terminal in the job's
/// scoped repo and arms auto-launch so the first prompt dispatches once the
/// shell is ready — clone-on-demand included. Behavior-preserving: same
/// `{devRoot}/{workspace}/{repoFolder}` layout, same branch/worktree naming,
/// same back-compat resolution for pre-workspace jobs. Reaches `appState`, the
/// shared **injected** `JSONStore`, and the shared shell / `prepareTerminal`
/// primitives through an unowned back-reference (ADR 0012 / #728). `runJob` and
/// the pure layout helpers stay on `SessionService` as facades.
@MainActor
final class JobRunner {
    private unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }

    init(owner: SessionService) { self.owner = owner }

    /// Run a scheduled job: create a fresh worktree + session + managed Claude
    /// terminal in the job's scoped repo and arm auto-launch so the first prompt
    /// dispatches once the shell is ready.
    ///
    /// Mirrors `createReviewSession`, but the worktree is a real git worktree off
    /// the repo's default branch (via `GitManager`) rather than a clone. The
    /// returned terminal id lets the caller (`JobScheduler`) deliver any
    /// remaining prompts after launch. Returns `nil` if the repo is missing or
    /// the worktree can't be created.
    func runJob(_ job: JobConfig, devRoot: String) async -> (sessionID: UUID, terminalID: UUID)? {
        guard let firstPrompt = job.prompts.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            CrowLog.info("[SessionService] Job '\(job.name)' has no prompts; skipping")
            return nil
        }

        let gitManager = GitManager(config: WorkspaceConfig(
            devRoot: devRoot, workspaces: [:], defaults: WorkspaceDefaults()
        ))

        // Resolve the repo to a local checkout. The job carries a workspace and
        // an `owner/repo` slug (CROW-327): the checkout lives at
        // `{devRoot}/{workspace}/{repoFolder}` where repoFolder is the slug's
        // last component. Clone it on demand if it isn't on disk yet.
        let repoFolder = Self.jobRepoFolder(for: job.repo)
        let repoPath: String
        let workspacePath: String

        if !job.workspace.isEmpty {
            let layout = Self.jobWorktreeLayout(
                devRoot: devRoot, workspace: job.workspace, repo: job.repo
            )
            workspacePath = layout.workspacePath
            repoPath = layout.repoPath
            if !FileManager.default.fileExists(atPath: (repoPath as NSString).appendingPathComponent(".git")) {
                guard await cloneJobRepo(job: job, devRoot: devRoot, into: repoPath) else {
                    CrowLog.info("[SessionService] Job '\(job.name)': repo '\(job.repo)' is not cloned and clone-on-demand failed")
                    return nil
                }
            }
        } else {
            // Back-compat: jobs saved before the workspace field returned store a
            // bare repo name. Resolve by folder name among local checkouts. Sort
            // first so a duplicated name binds deterministically across runs.
            let repos = ((try? await gitManager.discoverRepos()) ?? [])
                .sorted { $0.path < $1.path }
            guard let repoInfo = repos.first(where: { $0.name == job.repo }) else {
                CrowLog.info("[SessionService] Job '\(job.name)': repo '\(job.repo)' not found under devRoot")
                return nil
            }
            repoPath = repoInfo.path
            workspacePath = (repoPath as NSString).deletingLastPathComponent
        }

        let slug = Self.slugify(job.name)
        let stamp = Self.runStamp()
        let branch = "feature/job-\(slug)-\(stamp)"
        let worktreePath = (workspacePath as NSString)
            .appendingPathComponent("\(repoFolder)-job-\(slug)-\(stamp)")

        // Create the worktree on disk (fetch + new branch off default + retry).
        do {
            try await gitManager.createWorktree(
                repoPath: repoPath, worktreePath: worktreePath, branch: branch
            )
        } catch {
            CrowLog.info("[SessionService] Job '\(job.name)': createWorktree failed: \(error.localizedDescription)")
            return nil
        }

        // Write the first prompt to the file launchClaude reads on first launch.
        // Write failures MUST surface (CROW-439): if the file isn't there, the
        // launcher's prompt-file shell substitution yields an
        // empty string and the agent silently idles.
        let promptPath = (worktreePath as NSString).appendingPathComponent(".crow-job-prompt.md")
        do {
            try firstPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        } catch {
            CrowLog.info("[SessionService] Job '\(job.name)': failed to write \(promptPath): \(error.localizedDescription)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: promptPath) else {
            CrowLog.info("[SessionService] Job '\(job.name)': prompt file missing at \(promptPath) after write")
            return nil
        }

        let session = Session(
            name: "job-\(slug)-\(stamp)",
            kind: .job,
            agentKind: appState.agentKind(for: .job)
        )
        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoFolder,
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            isPrimary: true
        )
        let terminal = SessionTerminal(
            sessionID: session.id,
            name: session.agentKind.displayName,
            cwd: worktreePath,
            isManaged: true
        )

        // Backend dispatch — starts the surface / tmux window and tracks readiness.
        let preparedTerminal = owner.prepareTerminal(terminal, trackReadiness: true)

        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [preparedTerminal]
        appState.terminalReadiness[preparedTerminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(preparedTerminal.id)

        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(preparedTerminal)
        }

        CrowLog.info("[SessionService] Job '\(job.name)': created session '\(session.name)' at \(worktreePath)")
        return (session.id, preparedTerminal.id)
    }

    /// The local folder name for a job's repo: the slug's last component
    /// (`corveil/api` → `api`, GitLab `group/sub/proj` → `proj`), or the
    /// value verbatim when it isn't a slug (legacy bare-name jobs).
    nonisolated static func jobRepoFolder(for repo: String) -> String {
        repo.contains("/") ? (repo as NSString).lastPathComponent : repo
    }

    /// Where a workspace-scoped job's checkout and worktree parent live:
    /// `{devRoot}/{workspace}/{repoFolder}`. Pure path math (no filesystem),
    /// so it's unit-testable independent of clone/worktree side effects.
    nonisolated static func jobWorktreeLayout(
        devRoot: String, workspace: String, repo: String
    ) -> (workspacePath: String, repoPath: String, repoFolder: String) {
        let repoFolder = jobRepoFolder(for: repo)
        let workspacePath = (devRoot as NSString).appendingPathComponent(workspace)
        let repoPath = (workspacePath as NSString).appendingPathComponent(repoFolder)
        return (workspacePath, repoPath, repoFolder)
    }

    /// Clone a job's repo into `destination` on demand (the provider list can
    /// include repos not yet checked out). Needs an `owner/repo` slug; the
    /// workspace supplies the provider and (for GitLab) the host. Returns
    /// whether a `.git` checkout exists at `destination` afterward.
    private func cloneJobRepo(job: JobConfig, devRoot: String, into destination: String) async -> Bool {
        guard job.repo.contains("/") else {
            CrowLog.info("[SessionService] Job '\(job.name)': repo '\(job.repo)' is not an owner/repo slug; cannot clone")
            return false
        }
        let workspace = ConfigStore.loadConfig(devRoot: devRoot)?
            .workspaces.first { $0.name == job.workspace }
        let provider = workspace?.provider ?? "github"

        // Ensure the workspace parent exists — a brand-new workspace may have no
        // checkouts on disk yet, and git won't create leading directories.
        try? FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        CrowLog.info("[SessionService] Job '\(job.name)': cloning \(job.repo) into \(destination)")
        do {
            if provider == "gitlab" {
                var env: [String: String] = [:]
                if let host = workspace?.host, !host.isEmpty { env["GITLAB_HOST"] = host }
                _ = try await owner.shell(env: env, "glab", "repo", "clone", job.repo, destination)
            } else {
                _ = try await owner.shell("gh", "repo", "clone", job.repo, destination)
            }
        } catch {
            CrowLog.info("[SessionService] Job '\(job.name)': clone failed: \(error.localizedDescription)")
        }
        return FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent(".git"))
    }

    /// A filesystem/branch-safe slug derived from a job name.
    private static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "job" : String(slug.prefix(40))
    }

    /// A compact `yyyyMMdd-HHmmss` timestamp that makes each run's branch/worktree unique.
    private static func runStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    func runJob(_ job: JobConfig, devRoot: String) async -> (sessionID: UUID, terminalID: UUID)? {
        await jobs.runJob(job, devRoot: devRoot)
    }

    /// The local folder name for a job's repo (see `JobRunner.jobRepoFolder`).
    nonisolated static func jobRepoFolder(for repo: String) -> String {
        JobRunner.jobRepoFolder(for: repo)
    }

    /// Where a workspace-scoped job's checkout and worktree parent live
    /// (see `JobRunner.jobWorktreeLayout`).
    nonisolated static func jobWorktreeLayout(
        devRoot: String, workspace: String, repo: String
    ) -> (workspacePath: String, repoPath: String, repoFolder: String) {
        JobRunner.jobWorktreeLayout(devRoot: devRoot, workspace: workspace, repo: repo)
    }
}
