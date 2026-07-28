import ArgumentParser
import CrowIPC
import Foundation

// Workspace/automation defaults: `crow defaults get | set` (CROW-810).
//
// Reads and writes `AppConfig.defaults` — the subtree behind Settings →
// Workspaces (provider, branch prefix), → Automation (the review/ticket exclude
// lists) and → General (the corveil binary path). Same shape as `crow telemetry`
// / `crow cleanup` / `crow ui`: a noun parent with bare `get` / `set` verbs, and
// `set` is a PATCH where passing nothing is an error rather than a silent no-op
// (a no-op would still rewrite config.json and fire a spurious "Config reloaded"
// in every open browser).
//
// Scalars follow the Settings-group convention of an explicit value
// (`--provider gitlab`) rather than `crow notifications`' `--flag`/`--no-flag`
// pairs. The three string lists are edited incrementally instead of by
// replacement — excluding one more repo shouldn't require restating the list —
// so each gets `--add-…` / `--remove-…` (both repeatable) and a `--clear-…`
// flag, with clear exclusive against the other two for that same list.

/// Parent command for workspace/automation defaults: `crow defaults <subcommand>`.
public struct Defaults: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "defaults",
        abstract: "View or change workspace and automation defaults",
        discussion: """
        These are the `defaults` block of config.json: the forge provider and \
        CLI used for new workspaces, the branch prefix for new session branches, \
        the repo/label lists that filter the review and ticket boards, and the \
        binary path overrides.
        """,
        subcommands: [DefaultsGet.self, DefaultsSet.self]
    )

    public init() {}
}

public struct DefaultsGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show the current workspace and automation defaults",
        discussion: """
        Echoes the whole defaults block, including `exclude_dirs` and \
        `mirror_claude_mcp_to_codex`, which `set` does not write — neither has a \
        Settings UI either, and omitting them would make this a worse answer to \
        "what is my config?".

        `config_readable` is false when config.json exists but could not be \
        decoded: the values shown are then the built-in defaults rather than \
        yours, which matters when you are working out why a filter isn't firing.
        """
    )

    public init() {}

    public func run() throws {
        let result = try rpc("defaults-get")
        printJSON(result)
        if result["config_readable"]?.boolValue == false {
            warn("config.json exists but could not be decoded — the values above are built-in defaults, not your settings.")
        }
    }
}

public struct DefaultsSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change workspace and automation defaults",
        discussion: """
        Only the flags you pass change; at least one is required.

        Most of these are live. The provider and CLI are re-read on each repo \
        scan, the board lists are re-read on each board poll (about a minute), \
        and the branch prefix is read when a workspace is created. --binary is \
        the exception: agent binary discovery and the .claude/bin symlinks are \
        both set up at startup, so a change there returns "restart_required" and \
        needs a crowd restart — including when you remove one, since the stale \
        symlink keeps shadowing PATH until then.

        --provider and --cli are stored independently and neither implies the \
        other, matching how GitManager reads them; setting only one warns if the \
        resulting pair is crossed.
        """
    )

    @Option(name: .long, help: "Forge for new workspaces (github or gitlab)")
    var provider: String?

    @Option(name: .long, help: "Forge CLI for new workspaces (gh or glab)")
    var cli: String?

    @Option(
        name: .customLong("branch-prefix"),
        help: "Prefix for new session branches, e.g. 'feature/' (empty for none)")
    var branchPrefix: String?

    @Option(
        name: .long, parsing: .singleValue,
        help: "Binary path override as NAME=PATH, e.g. corveil=/opt/corveil/bin/corveil; NAME= removes it (repeatable)")
    var binary: [String] = []

    @Option(
        name: .customLong("add-exclude-review-repo"), parsing: .singleValue,
        help: "Repo to hide from the review board; supports one wildcard, e.g. 'owner/*' (repeatable)")
    var addExcludeReviewRepo: [String] = []
    @Option(
        name: .customLong("remove-exclude-review-repo"), parsing: .singleValue,
        help: "Repo to stop hiding from the review board (repeatable)")
    var removeExcludeReviewRepo: [String] = []
    @Flag(
        name: .customLong("clear-exclude-review-repos"),
        help: "Empty the review-board repo exclusions")
    var clearExcludeReviewRepos = false

    @Option(
        name: .customLong("add-exclude-ticket-repo"), parsing: .singleValue,
        help: "Repo to hide from the ticket board; supports one wildcard (repeatable)")
    var addExcludeTicketRepo: [String] = []
    @Option(
        name: .customLong("remove-exclude-ticket-repo"), parsing: .singleValue,
        help: "Repo to stop hiding from the ticket board (repeatable)")
    var removeExcludeTicketRepo: [String] = []
    @Flag(
        name: .customLong("clear-exclude-ticket-repos"),
        help: "Empty the ticket-board repo exclusions")
    var clearExcludeTicketRepos = false

    @Option(
        name: .customLong("add-ignore-review-label"), parsing: .singleValue,
        help: "PR label that hides a review from the board; exact match, no wildcards (repeatable)")
    var addIgnoreReviewLabel: [String] = []
    @Option(
        name: .customLong("remove-ignore-review-label"), parsing: .singleValue,
        help: "PR label to stop ignoring (repeatable)")
    var removeIgnoreReviewLabel: [String] = []
    @Flag(
        name: .customLong("clear-ignore-review-labels"),
        help: "Empty the ignored review labels")
    var clearIgnoreReviewLabels = false

    public init() {}

    /// The three lists, as (wire field, flag stem, values) so validation and
    /// param building each walk them once instead of repeating the same block
    /// three times with a different noun.
    private var listEdits: [(field: String, stem: String, add: [String], remove: [String], clear: Bool)] {
        [
            ("exclude_review_repos", "exclude-review-repo",
             addExcludeReviewRepo, removeExcludeReviewRepo, clearExcludeReviewRepos),
            ("exclude_ticket_repos", "exclude-ticket-repo",
             addExcludeTicketRepo, removeExcludeTicketRepo, clearExcludeTicketRepos),
            ("ignore_review_labels", "ignore-review-label",
             addIgnoreReviewLabel, removeIgnoreReviewLabel, clearIgnoreReviewLabels),
        ]
    }

    private var hasListEdit: Bool {
        listEdits.contains { !$0.add.isEmpty || !$0.remove.isEmpty || $0.clear }
    }

    public func validate() throws {
        guard provider != nil || cli != nil || branchPrefix != nil || !binary.isEmpty
                || hasListEdit else {
            throw ValidationError(
                "Nothing to set — provide at least one of --provider, --cli, --branch-prefix, --binary, or an --add-/--remove-/--clear- flag for a list.")
        }
        if let provider { try validateProvider(provider) }
        if let cli { try validateForgeCLI(cli) }
        if let branchPrefix { try validateBranchPrefix(branchPrefix) }
        if !binary.isEmpty { _ = try parseBinaryOverrides(binary) }
        // Per list, not globally: clearing one list while adding to another is a
        // perfectly good call.
        for edit in listEdits where edit.clear && !(edit.add.isEmpty && edit.remove.isEmpty) {
            throw ValidationError(
                "--clear-\(edit.stem)s cannot be combined with --add-\(edit.stem) or --remove-\(edit.stem) — clear empties the list.")
        }
        // Only lists the caller actually named: `normalizedListValues` treats an
        // all-blank flag as a typo and throws, and an untouched list is empty.
        for edit in listEdits {
            if !edit.add.isEmpty {
                _ = try normalizedListValues(edit.add, flag: "--add-\(edit.stem)")
            }
            if !edit.remove.isEmpty {
                _ = try normalizedListValues(edit.remove, flag: "--remove-\(edit.stem)")
            }
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let provider { params["provider"] = .string(provider) }
        if let cli { params["cli"] = .string(cli) }
        if let branchPrefix { params["branch_prefix"] = .string(branchPrefix) }
        if !binary.isEmpty {
            params["binaries"] = .object(
                try parseBinaryOverrides(binary).mapValues { .string($0) })
        }
        for edit in listEdits {
            if !edit.add.isEmpty {
                params["add_\(edit.field)"] = .array(
                    try normalizedListValues(edit.add, flag: "--add-\(edit.stem)").map { .string($0) })
            }
            if !edit.remove.isEmpty {
                params["remove_\(edit.field)"] = .array(
                    try normalizedListValues(edit.remove, flag: "--remove-\(edit.stem)").map { .string($0) })
            }
            if edit.clear { params["clear_\(edit.field)"] = .bool(true) }
        }

        let result = try rpc("defaults-set", params: params)
        printJSON(result)

        // stdout stays pure JSON (every command's contract); the nudges go to
        // stderr so an interactive user doesn't miss an inert or half-done write.
        if result["restart_required"]?.boolValue == true {
            warn("binary overrides changed — restart crowd for agent discovery and the .claude/bin symlinks to pick them up.")
        }
        let notExecutable = result["binaries_not_executable"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        if !notExecutable.isEmpty {
            warn("saved, but not executable right now (the symlink will be skipped until it is): \(notExecutable.joined(separator: ", "))")
        }
        if result["provider_cli_mismatch"]?.boolValue == true {
            warn("provider and cli disagree — pass --provider and --cli together, or set the other one now.")
        }
    }
}
