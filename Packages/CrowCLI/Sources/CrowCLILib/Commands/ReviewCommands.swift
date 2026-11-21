import ArgumentParser
import CrowIPC
import Foundation

/// Parent command for review-clone verbs: `crow review <subcommand>`.
public struct Review: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Act on a PR review session's clone",
        subcommands: [
            ReviewRestrip.self,
        ]
    )

    public init() {}
}

/// Remove PR-supplied harness config from a review clone (CROW-1492).
public struct ReviewRestrip: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restrip",
        abstract: "Remove PR-supplied harness config from a review session's clone",
        discussion: """
            Run right after `gh pr checkout` in a review session. Checkout restores \
            the PR head's harness config (.cursor, .grok, .agents, .gemini, .muse, \
            .codex, .mcp.json, .claude/settings.json, .claude/settings.local.json), \
            and this removes it again (CROW-960).

            The daemon does the removal, outside the agent's sandbox, because \
            Claude Code's sandbox blocks writes to .claude/settings*.json. It acts \
            only on the session's own clone under {devRoot}/crow-reviews/, and \
            refuses any other kind of session. Working tree only: the files stay in \
            git, so `git show HEAD:<path>` still shows them. It never deletes \
            .claude/ itself.

            After removing, it checks every path again. If anything is left, it \
            exits non-zero with the paths and reasons, and the review must stop.
            """
    )
    @Option(name: .long, help: "Review session UUID (usually \"$CROW_SESSION_ID\")") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("review-restrip", params: ["session_id": .string(session)])
        printJSON(result)
    }
}
