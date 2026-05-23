import Foundation

/// A single commit's metadata plus its diffstat, as collected by
/// `GitManager.summarizeCommits`. Lives in CrowCore so CrowGit (which produces
/// it), CrowCLI, and CrowUI can all share one type.
public struct CommitInfo: Codable, Sendable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let authorName: String
    public let authorEmail: String
    public let date: Date            // ISO author date (git %aI)
    public let subject: String
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int

    public init(
        hash: String,
        shortHash: String,
        authorName: String,
        authorEmail: String,
        date: Date,
        subject: String,
        filesChanged: Int,
        insertions: Int,
        deletions: Int
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.subject = subject
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// All commits in the requested window for a single repo, grouped under the
/// repo's discovered path. Identified by `path` (unique per checkout).
public struct RepoCommitSummary: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let repo: String
    public let path: String
    public let workspace: String
    public let commits: [CommitInfo]
    /// Hosted-commit-page prefix derived from the repo's `origin` remote, e.g.
    /// `https://github.com/org/repo/commit/` (GitHub) or
    /// `https://gitlab.com/org/repo/-/commit/` (GitLab). Append a commit hash to
    /// open it in the browser. `nil` when the repo has no parseable remote.
    public let commitURLPrefix: String?

    public var totalInsertions: Int { commits.reduce(0) { $0 + $1.insertions } }
    public var totalDeletions: Int { commits.reduce(0) { $0 + $1.deletions } }
    public var totalFilesChanged: Int { commits.reduce(0) { $0 + $1.filesChanged } }

    public init(repo: String, path: String, workspace: String, commits: [CommitInfo], commitURLPrefix: String? = nil) {
        self.repo = repo
        self.path = path
        self.workspace = workspace
        self.commits = commits
        self.commitURLPrefix = commitURLPrefix
    }
}
