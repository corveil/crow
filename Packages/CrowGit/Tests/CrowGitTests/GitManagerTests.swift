import Foundation
import Testing
@testable import CrowGit
import CrowCore

// MARK: - GitError Descriptions

@Test func commandFailedIncludesDetails() {
    let error = GitError.commandFailed(command: "git status", exitCode: 128, stderr: "fatal: not a git repository")
    let desc = error.errorDescription ?? ""
    #expect(desc.contains("git status"))
    #expect(desc.contains("128"))
    #expect(desc.contains("fatal: not a git repository"))
}

@Test func branchAlreadyExistsIncludesBranchName() {
    let error = GitError.branchAlreadyExists("feature/test")
    let desc = error.errorDescription ?? ""
    #expect(desc.contains("feature/test"))
}

@Test func noDefaultBranchIncludesRemoteName() {
    let error = GitError.noDefaultBranch(remote: "origin")
    let desc = error.errorDescription ?? ""
    #expect(desc.contains("origin"))
}

// MARK: - RepoInfo

@Test func repoInfoStoresAllProperties() {
    let info = RepoInfo(name: "crow", path: "/dev/crow", workspace: "RadiusMethod", provider: "github", cli: "gh", host: "github.com")
    #expect(info.name == "crow")
    #expect(info.path == "/dev/crow")
    #expect(info.workspace == "RadiusMethod")
    #expect(info.provider == "github")
    #expect(info.cli == "gh")
    #expect(info.host == "github.com")
}

@Test func repoInfoHostCanBeNil() {
    let info = RepoInfo(name: "repo", path: "/p", workspace: "ws", provider: "github", cli: "gh", host: nil)
    #expect(info.host == nil)
}

// MARK: - discoverRepos

/// Helper to create a temporary dev root directory for discoverRepos tests.
private func makeTempDevRoot() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("crow-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Helper to create a fake git repo (directory with .git subdirectory).
private func createFakeRepo(at base: URL, workspace: String, repo: String) {
    let gitDir = base.appendingPathComponent(workspace).appendingPathComponent(repo).appendingPathComponent(".git")
    try! FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
}

/// Helper to build a WorkspaceConfig pointing at a temp devRoot.
private func makeConfig(
    devRoot: String,
    workspaces: [String: WorkspaceEntry] = [:],
    defaults: WorkspaceDefaults = WorkspaceDefaults()
) -> WorkspaceConfig {
    WorkspaceConfig(devRoot: devRoot, workspaces: workspaces, defaults: defaults)
}

@Test func discoverReposFindsGitRepos() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    createFakeRepo(at: root, workspace: "OrgA", repo: "my-app")
    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.count == 1)
    #expect(repos[0].name == "my-app")
    #expect(repos[0].workspace == "OrgA")
}

@Test func discoverReposSkipsExcludedDirs() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // "node_modules" is in the default excludeDirs list
    createFakeRepo(at: root, workspace: "node_modules", repo: "some-pkg")
    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.isEmpty)
}

@Test func discoverReposSkipsCrowReviewsClones() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // crow-reviews holds transient PR-review clones that resolve to the same
    // org/repo slug as the canonical checkout; they must never be discovered.
    createFakeRepo(at: root, workspace: "crow-reviews", repo: "crow-pr-346")
    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.isEmpty)
}

@Test func discoverReposSkipsWorktrees() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Worktrees have .git as a file, not a directory
    let repoDir = root.appendingPathComponent("OrgA").appendingPathComponent("worktree-repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    let gitFile = repoDir.appendingPathComponent(".git")
    try "gitdir: /some/other/path/.git/worktrees/worktree-repo".write(to: gitFile, atomically: true, encoding: .utf8)

    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.isEmpty)
}

@Test func discoverReposReturnsEmptyForMissingDevRoot() async throws {
    let config = makeConfig(devRoot: "/nonexistent/path/\(UUID().uuidString)")
    let repos = try await GitManager(config: config).discoverRepos()
    #expect(repos.isEmpty)
}

@Test func discoverReposUsesWorkspaceOverrides() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    createFakeRepo(at: root, workspace: "CorpGitLab", repo: "project")
    let entry = WorkspaceEntry(provider: "gitlab", cli: "glab", host: "gitlab.corp.com")
    let config = makeConfig(devRoot: root.path, workspaces: ["CorpGitLab": entry])
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.count == 1)
    #expect(repos[0].provider == "gitlab")
    #expect(repos[0].cli == "glab")
    #expect(repos[0].host == "gitlab.corp.com")
}

@Test func discoverReposUsesDefaults() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    createFakeRepo(at: root, workspace: "MyOrg", repo: "repo1")
    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.count == 1)
    #expect(repos[0].provider == "github")
    #expect(repos[0].cli == "gh")
    #expect(repos[0].host == nil)
}

@Test func discoverReposFindsMultipleRepos() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    createFakeRepo(at: root, workspace: "Org", repo: "repo-a")
    createFakeRepo(at: root, workspace: "Org", repo: "repo-b")
    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.count == 2)
    let names = Set(repos.map(\.name))
    #expect(names.contains("repo-a"))
    #expect(names.contains("repo-b"))
}

@Test func discoverReposSkipsNonDirectoryEntries() async throws {
    let root = makeTempDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Create a regular file at the workspace level (not a directory)
    let filePath = root.appendingPathComponent("not-a-dir.txt")
    try "hello".write(to: filePath, atomically: true, encoding: .utf8)

    let config = makeConfig(devRoot: root.path)
    let repos = try await GitManager(config: config).discoverRepos()

    #expect(repos.isEmpty)
}
