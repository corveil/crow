import ArgumentParser
import CrowIPC
import Foundation

// The Claude Code permission allowlist, aggregated across the global
// `~/.claude/settings.json` and every worktree's `.claude/settings.local.json`
// (#819). Same surface as the web Allowlist board — the daemon owns
// `AllowListService` (pure disk I/O), so these work with the desktop app down.

public struct ListAllowlist: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-allowlist",
        abstract: "List allowlist patterns and where each one is defined",
        discussion: """
        Reads the daemon's last scan rather than re-reading disk — run \
        refresh-allowlist first if a settings file changed underneath it.
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("list-allowlist"))
    }
}

public struct PromoteAllowlist: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "promote-allowlist",
        abstract: "Copy worktree-local allowlist patterns into ~/.claude/settings.json",
        discussion: """
        Patterns already in the global file are reported under already_global \
        and left alone. Quote patterns — parentheses and '*' are shell \
        metacharacters: --pattern 'Bash(npm test:*)'.

        Promote everything not yet global:
          crow list-allowlist | jq -r '.entries[] | select(.is_global | not) \
        | "--pattern", .pattern' | xargs crow promote-allowlist
        """
    )

    @Option(name: .long, parsing: .singleValue,
            help: "Allowlist pattern to promote, e.g. 'Bash(npm test:*)' (repeatable)")
    var pattern: [String] = []

    public init() {}

    public func validate() throws {
        _ = try normalizedAllowlistPatterns(pattern)
    }

    public func run() throws {
        let patterns = try normalizedAllowlistPatterns(pattern)
        // The daemon re-scans every worktree's settings after the write.
        let result = try rpc(
            "promote-allowlist",
            params: ["patterns": .array(patterns.map { .string($0) })],
            timeoutSeconds: 60
        )
        printJSON(result)
    }
}

public struct RefreshAllowlist: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "refresh-allowlist",
        abstract: "Re-scan global and worktree settings files for allowlist patterns"
    )

    public init() {}

    public func run() throws {
        // Walks every worktree's settings file — allow past the 30s default.
        printJSON(try rpc("refresh-allowlist", timeoutSeconds: 60))
    }
}
