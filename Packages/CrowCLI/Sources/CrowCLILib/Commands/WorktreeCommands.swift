import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Worktree Commands

/// Register a git worktree for a session.
public struct AddWorktree: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "add-worktree", abstract: "Register a worktree for a session")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Repo name") var repo: String
    @Option(name: .long, help: "Worktree path") var path: String
    @Option(name: .long, help: "Branch name") var branch: String
    @Option(name: .customLong("repo-path"), help: "Main repo path (for git commands)") var repoPath: String?
    @Flag(name: .long, help: "Mark as primary worktree. The first worktree of a session is primary even without this flag.") var primary: Bool = false

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "session_id": .string(session),
            "repo": .string(repo),
            "path": .string(path),
            "branch": .string(branch),
        ]
        if let repoPath { params["repo_path"] = .string(repoPath) }
        if primary { params["primary"] = .bool(true) }
        let result = try rpc("add-worktree", params: params)
        printJSON(result)
    }
}

/// List worktrees registered for a session.
public struct ListWorktrees: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list-worktrees", abstract: "List worktrees for a session")
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("list-worktrees", params: ["session_id": .string(session)])
        printJSON(result)
    }
}
