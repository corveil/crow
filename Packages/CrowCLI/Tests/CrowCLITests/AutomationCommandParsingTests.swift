import ArgumentParser
import CrowIPC
import Testing
@testable import CrowCLILib

// MARK: - `crow automation` command parsing (CROW-812)
//
// `validate()` runs during `parse`, so the "nothing to set" and blank-value
// rejections surface here without a socket.

@Test func automationGroupRoutesToSubcommands() throws {
    #expect(try Automation.parseAsRoot(["get"]) is AutomationGet)
    #expect(try Automation.parseAsRoot(["set", "--attribution-trailers", "false"])
        is AutomationSet)
}

@Test func automationGroupRejectsUnknownSubcommands() {
    #expect(throws: (any Error).self) { _ = try Automation.parseAsRoot(["enable"]) }
    #expect(throws: (any Error).self) { _ = try Automation.parseAsRoot(["list"]) }
}

@Test func automationGetTakesNoFlags() throws {
    _ = try AutomationGet.parse([])
    #expect(throws: (any Error).self) { _ = try AutomationGet.parse(["--enabled", "true"]) }
}

// MARK: - set: booleans

/// The reason these are `@Option ... Bool?` and not `@Flag`: a patch has to tell
/// "set it to false" apart from "don't touch it", which a flag cannot express.
/// Six of the twelve default to `true`, so a `@Flag` design could never turn one
/// off.
@Test func automationSetParsesExplicitFalse() throws {
    let cmd = try AutomationSet.parse(["--manager-auto-permission-mode", "false"])
    #expect(cmd.permissions.managerAutoPermissionMode == false)
    #expect(cmd.permissions.remoteControlEnabled == nil)
    #expect(cmd.watchers.attributionTrailers == nil)
    #expect(cmd.respond.respondToChangesRequested == nil)
}

@Test func automationSetParsesEveryPermissionMode() throws {
    let cmd = try AutomationSet.parse([
        "--remote-control-enabled", "true",
        "--manager-auto-permission-mode", "false",
        "--review-auto-permission-mode", "false",
        "--coder-view-auto-permission-mode", "true",
        "--jobs-auto-permission-mode", "false",
    ])
    #expect(cmd.permissions.remoteControlEnabled == true)
    #expect(cmd.permissions.managerAutoPermissionMode == false)
    #expect(cmd.permissions.reviewAutoPermissionMode == false)
    #expect(cmd.permissions.coderViewAutoPermissionMode == true)
    #expect(cmd.permissions.jobsAutoPermissionMode == false)
}

@Test func automationSetParsesWatcherAndAutoRespondToggles() throws {
    let cmd = try AutomationSet.parse([
        "--attribution-trailers", "false",
        "--auto-create-watcher-enabled", "true",
        "--auto-merge-watcher-enabled", "true",
        "--respond-to-changes-requested", "false",
        "--respond-to-failed-checks", "true",
        "--auto-rebase-and-resolve-conflicts", "true",
    ])
    #expect(cmd.watchers.attributionTrailers == false)
    #expect(cmd.watchers.autoCreateWatcherEnabled == true)
    #expect(cmd.watchers.autoMergeWatcherEnabled == true)
    #expect(cmd.respond.respondToChangesRequested == false)
    #expect(cmd.respond.respondToFailedChecks == true)
    #expect(cmd.respond.autoRebaseAndResolveConflicts == true)
}

/// ArgumentParser parses `Bool` through `LosslessStringConvertible`, which takes
/// only `true`/`false` — so `--flag yes` fails loudly instead of being coerced.
@Test func automationSetRejectsNonBooleanLiterals() {
    for bad in ["yes", "1", "on", "True"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try AutomationSet.parse(["--auto-merge-watcher-enabled", bad])
        }
    }
}

/// A bare boolean flag would silently parse the next token as a subcommand or
/// leave the value unset — require the explicit literal.
@Test func automationSetRejectsBareBooleanFlag() {
    #expect(throws: (any Error).self) {
        _ = try AutomationSet.parse(["--auto-merge-watcher-enabled"])
    }
}

// MARK: - set: nothing to set

/// A no-op `set` would still rewrite config.json and fire a spurious "Config
/// reloaded" notification in every open browser, so it's an error.
@Test func automationSetRequiresAtLeastOneFlag() {
    #expect(setParseError([]).contains("Nothing to set"))
}

/// Each of the three flag groups on its own has to satisfy the guard — a bug
/// here would reject a legitimate single-group edit.
@Test func automationSetAcceptsAnySingleGroup() throws {
    _ = try AutomationSet.parse(["--jobs-auto-permission-mode", "true"])
    _ = try AutomationSet.parse(["--auto-merge-watcher-enabled", "true"])
    _ = try AutomationSet.parse(["--respond-to-failed-checks", "true"])
}

/// The three board-filter lists the Automation tab renders belong to
/// `crow defaults set` (#810), which already ships these exact flag names.
/// Accepting them here too would mean two commands writing one config field with
/// two sets of list semantics — `defaults` makes clear exclusive with add/remove
/// and matches removes case-insensitively. `automation get` echoes the lists
/// read-only; only `defaults` writes them.
@Test func automationSetDoesNotClaimTheDefaultsListFlags() {
    for flag in ["--add-exclude-review-repo", "--remove-exclude-review-repo",
                 "--add-ignore-review-label", "--remove-ignore-review-label",
                 "--add-exclude-ticket-repo", "--remove-exclude-ticket-repo"] {
        #expect(throws: (any Error).self, "\(flag) must belong to `crow defaults`") {
            _ = try AutomationSet.parse([flag, "corveil/*"])
        }
    }
    for flag in ["--clear-exclude-review-repos", "--clear-ignore-review-labels",
                 "--clear-exclude-ticket-repos"] {
        #expect(throws: (any Error).self, "\(flag) must belong to `crow defaults`") {
            _ = try AutomationSet.parse([flag])
        }
    }
}

// MARK: - Helpers

/// The message a user actually sees on stderr. `parse` runs `validate`, so the
/// rejection surfaces here.
private func setParseError(_ args: [String]) -> String {
    do {
        _ = try AutomationSet.parse(args)
        return ""
    } catch {
        return String(describing: error)
    }
}

// MARK: - Wire contract
//
// The keys `crow automation set` puts on the wire. CrowCLI and CrowDaemon are
// separate packages that never share a symbol for these strings, so a typo in
// one would compile and pass that package's own tests while silently dropping
// the field. `AutomationHandlerTests.setAcceptsEveryWireKeyTheCLIEmits` feeds
// this exact list to the real handler and asserts every field lands.

/// Every flag in one invocation → exactly these keys, no more, no less.
@Test func automationSetEmitsTheExpectedWireKeys() throws {
    let cmd = try AutomationSet.parse([
        "--remote-control-enabled", "true",
        "--manager-auto-permission-mode", "false",
        "--review-auto-permission-mode", "false",
        "--coder-view-auto-permission-mode", "true",
        "--jobs-auto-permission-mode", "false",
        "--attribution-trailers", "false",
        "--auto-create-watcher-enabled", "true",
        "--auto-merge-watcher-enabled", "true",
        "--respond-to-changes-requested", "false",
        "--respond-to-failed-checks", "true",
        "--auto-rebase-and-resolve-conflicts", "true",
        "--auto-re-request-review", "false",
    ])

    #expect(Set(cmd.params.keys) == Set(automationWireKeys))
}

/// A flag not passed must not appear at all — an explicit `null` or a defaulted
/// `false` would overwrite the stored value instead of leaving it alone.
@Test func automationSetOmitsUnpassedFlagsEntirely() throws {
    let cmd = try AutomationSet.parse(["--auto-merge-watcher-enabled", "true"])
    #expect(cmd.params.keys.sorted() == ["auto_merge_watcher_enabled"])

    let two = try AutomationSet.parse([
        "--attribution-trailers", "false", "--respond-to-failed-checks", "true",
    ])
    #expect(two.params.keys.sorted() == ["attribution_trailers", "respond_to_failed_checks"])
}

let automationWireKeys = [
    "remote_control_enabled",
    "manager_auto_permission_mode",
    "review_auto_permission_mode",
    "coder_view_auto_permission_mode",
    "jobs_auto_permission_mode",
    "attribution_trailers",
    "auto_create_watcher_enabled",
    "auto_merge_watcher_enabled",
    "respond_to_changes_requested",
    "respond_to_failed_checks",
    "auto_rebase_and_resolve_conflicts",
    "auto_re_request_review",
]
