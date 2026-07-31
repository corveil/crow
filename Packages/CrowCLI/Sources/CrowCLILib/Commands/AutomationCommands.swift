import ArgumentParser
import CrowIPC
import Foundation

// Settings → Automation as a CLI verb: `crow automation get|set` (CROW-812).
// Follows the `crow telemetry` / `crow cleanup` / `crow ui` shape from CROW-814 —
// a noun parent with bare `get` / `set` verbs, where `set` is a PATCH and passing
// no flags is an error rather than a silent no-op (a no-op would still rewrite
// config.json and fire a spurious "Config reloaded" notification in every open
// browser).
//
// Booleans are `@Option ... Bool?`, not `@Flag`, because a patch needs three
// states — true, false, and "not provided". ArgumentParser parses `Bool` through
// `LosslessStringConvertible`, which accepts *only* the literals `true` and
// `false`; hence the explicit "(true or false)" in each help string. The
// `--clear-*` flags are the exception and *are* `@Flag`: "clear = false" has no
// meaning, so there is no third state to express.
//
// One command rather than a verb per group, so a multi-field edit is one config
// lock, one config.json mtime bump, and one `configReloaded` broadcast. That
// makes for a long `--help`, so the flags are split into titled `@OptionGroup`s
// mirroring the web tab's own group headings.

// MARK: - crow automation

/// Parent command for the automation settings: `crow automation <subcommand>`.
public struct Automation: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "automation",
        abstract: "View or change the automation settings",
        discussion: """
        The Settings → Automation toggles: which sessions launch in auto \
        permission mode, whether Crow watches for crow:auto / crow:merge labels, \
        and whether it responds to changes-requested reviews and failed checks on \
        your behalf.

        --jobs-auto-permission-mode is included here so all five permission modes \
        read and write as one group, even though the web UI renders that one \
        under the Jobs tab.

        The tab's three board-filter lists are `AppConfig.defaults` fields and are \
        written by `crow defaults set`; `get` echoes them read-only here.
        """,
        subcommands: [AutomationGet.self, AutomationSet.self]
    )

    public init() {}
}

public struct AutomationGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show the current automation settings",
        discussion: """
        The `defaults` block is echoed read-only for context — write those three \
        lists with `crow defaults set`. Within it, \
        effective_exclude_review_repos is additionally *derived*: the global \
        exclude list unioned with every workspace's own, which is what the review \
        board actually filters on and is not stored anywhere as such.

        config_readable is false when config.json exists but could not be \
        decoded — the settings shown are then defaults, not what is on disk.
        """
    )

    public init() {}

    public func run() throws {
        let result = try rpc("automation-get")
        printJSON(result)
        if result["automation"]?.objectValue?["config_readable"]?.boolValue == false {
            warn("config.json exists but could not be decoded — showing defaults, not stored settings.")
        }
    }
}

// MARK: - Flag groups

/// The five `--permission-mode auto` switches, plus remote control — the web
/// tab's "Permission modes" group.
struct AutomationPermissionArgs: ParsableArguments {
    @Option(
        name: .customLong("remote-control-enabled"),
        help: "Launch new Claude Code sessions with --rc (true or false)")
    var remoteControlEnabled: Bool?

    @Option(
        name: .customLong("manager-auto-permission-mode"),
        help: "Launch the Manager terminal in auto permission mode (true or false)")
    var managerAutoPermissionMode: Bool?

    @Option(
        name: .customLong("review-auto-permission-mode"),
        help: "Launch code-review sessions in auto permission mode (true or false)")
    var reviewAutoPermissionMode: Bool?

    @Option(
        name: .customLong("coder-view-auto-permission-mode"),
        help: "Launch new work coder views in auto permission mode (true or false)")
    var coderViewAutoPermissionMode: Bool?

    @Option(
        name: .customLong("jobs-auto-permission-mode"),
        help: "Run scheduled jobs in auto permission mode (true or false)")
    var jobsAutoPermissionMode: Bool?

    var isEmpty: Bool {
        remoteControlEnabled == nil && managerAutoPermissionMode == nil
            && reviewAutoPermissionMode == nil && coderViewAutoPermissionMode == nil
            && jobsAutoPermissionMode == nil
    }

    var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let remoteControlEnabled {
            params["remote_control_enabled"] = .bool(remoteControlEnabled)
        }
        if let managerAutoPermissionMode {
            params["manager_auto_permission_mode"] = .bool(managerAutoPermissionMode)
        }
        if let reviewAutoPermissionMode {
            params["review_auto_permission_mode"] = .bool(reviewAutoPermissionMode)
        }
        if let coderViewAutoPermissionMode {
            params["coder_view_auto_permission_mode"] = .bool(coderViewAutoPermissionMode)
        }
        if let jobsAutoPermissionMode {
            params["jobs_auto_permission_mode"] = .bool(jobsAutoPermissionMode)
        }
        return params
    }
}

/// Commit attribution and the two label watchers.
struct AutomationWatcherArgs: ParsableArguments {
    @Option(
        name: .customLong("attribution-trailers"),
        help: "Add a Crow-Session trailer to commits in new worktrees (true or false)")
    var attributionTrailers: Bool?

    @Option(
        name: .customLong("auto-create-watcher-enabled"),
        help: "Auto-launch a workspace for crow:auto labeled issues (true or false)")
    var autoCreateWatcherEnabled: Bool?

    @Option(
        name: .customLong("auto-merge-watcher-enabled"),
        help: "Auto-merge Crow-authored PRs labeled crow:merge (true or false)")
    var autoMergeWatcherEnabled: Bool?

    var isEmpty: Bool {
        attributionTrailers == nil && autoCreateWatcherEnabled == nil
            && autoMergeWatcherEnabled == nil
    }

    var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let attributionTrailers {
            params["attribution_trailers"] = .bool(attributionTrailers)
        }
        if let autoCreateWatcherEnabled {
            params["auto_create_watcher_enabled"] = .bool(autoCreateWatcherEnabled)
        }
        if let autoMergeWatcherEnabled {
            params["auto_merge_watcher_enabled"] = .bool(autoMergeWatcherEnabled)
        }
        return params
    }
}

/// The four `AppConfig.autoRespond` toggles.
struct AutomationRespondArgs: ParsableArguments {
    @Option(
        name: .customLong("respond-to-changes-requested"),
        help: "Type a fix-it instruction into the session on a changes-requested review (true or false)")
    var respondToChangesRequested: Bool?

    @Option(
        name: .customLong("respond-to-failed-checks"),
        help: "Type a fix-it instruction into the session when CI checks fail (true or false)")
    var respondToFailedChecks: Bool?

    @Option(
        name: .customLong("auto-rebase-and-resolve-conflicts"),
        help: "Rebase onto the base branch and force-with-lease push on conflict (true or false)")
    var autoRebaseAndResolveConflicts: Bool?

    @Option(
        name: .customLong("auto-re-request-review"),
        help: "Re-request review once a changes-requested PR's findings are addressed (true or false)")
    var autoReRequestReview: Bool?

    var isEmpty: Bool {
        respondToChangesRequested == nil && respondToFailedChecks == nil
            && autoRebaseAndResolveConflicts == nil && autoReRequestReview == nil
    }

    var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let respondToChangesRequested {
            params["respond_to_changes_requested"] = .bool(respondToChangesRequested)
        }
        if let respondToFailedChecks {
            params["respond_to_failed_checks"] = .bool(respondToFailedChecks)
        }
        if let autoRebaseAndResolveConflicts {
            params["auto_rebase_and_resolve_conflicts"] = .bool(autoRebaseAndResolveConflicts)
        }
        if let autoReRequestReview {
            params["auto_re_request_review"] = .bool(autoReRequestReview)
        }
        return params
    }
}

// MARK: - crow automation set

public struct AutomationSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change the automation settings",
        discussion: """
        Only the flags you pass change; at least one is required.

        Everything here is live within about one board poll (~60s) — the daemon \
        re-reads config.json rather than holding a snapshot, so no crowd restart \
        is needed. The permission modes and --remote-control-enabled apply to \
        newly launched sessions, and --attribution-trailers to newly created \
        worktrees; running sessions and existing worktrees are untouched.

        --manager-auto-permission-mode is the one exception: it is baked into the \
        Manager terminal's stored command, so it needs `crow restart-manager` (or \
        an app relaunch) to take effect. A change to it returns \
        "manager_restart_required": true.

        The tab's three board-filter lists (excluded review repos, ignored review \
        labels, excluded ticket repos) are `AppConfig.defaults` fields, so they \
        belong to `crow defaults set` — one writer, one set of semantics. \
        `crow automation get` echoes them read-only for context.
        """
    )

    @OptionGroup(title: "Permission modes")
    var permissions: AutomationPermissionArgs

    @OptionGroup(title: "Attribution & watchers")
    var watchers: AutomationWatcherArgs

    @OptionGroup(title: "Auto-respond")
    var respond: AutomationRespondArgs

    public init() {}

    public func validate() throws {
        guard !permissions.isEmpty || !watchers.isEmpty || !respond.isEmpty else {
            throw ValidationError(
                "Nothing to set — provide at least one flag. See `crow automation set --help`.")
        }
    }

    /// The `automation-set` request body. Split out of `run()` so a test can
    /// assert the wire keys without a socket — the group structs are a CLI-side
    /// convenience, but the daemon decodes a flat dictionary, and a typo on
    /// either side of that boundary would compile and pass both packages' own
    /// tests. `setAcceptsEveryWireKeyTheCLIEmits` pins it against the handler.
    var params: [String: JSONValue] {
        var params = permissions.params
        // The three groups own disjoint keys, so the combine closure never fires.
        params.merge(watchers.params) { current, _ in current }
        params.merge(respond.params) { current, _ in current }
        return params
    }

    public func run() throws {
        let result = try rpc("automation-set", params: params)
        printJSON(result)
        // stdout stays pure JSON (every command's contract); the nudge goes to
        // stderr so an interactive user doesn't miss an inert write.
        if result["manager_restart_required"]?.boolValue == true {
            warn("manager auto permission mode changed — run `crow restart-manager` for it to take effect.")
        }
    }
}
