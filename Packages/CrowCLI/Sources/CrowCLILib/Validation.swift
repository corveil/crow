import ArgumentParser
import CrowCore
import Foundation

/// Valid session status values accepted by the `set-status` command.
let validSessionStatuses = ["active", "paused", "inReview", "completed", "archived"]

/// Valid link type values accepted by the `add-link` command.
let validLinkTypes = ["ticket", "pr", "repo", "custom"]

/// Validate that a string is a well-formed UUID.
///
/// - Throws: `ValidationError` if the string is not a valid UUID.
func validateUUID(_ value: String, label: String = "UUID") throws {
    guard UUID(uuidString: value) != nil else {
        throw ValidationError("'\(value)' is not a valid \(label). Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
    }
}

/// Validate that a string is a recognized session status.
///
/// - Throws: `ValidationError` if the string is not one of: active, paused, inReview, completed, archived.
func validateSessionStatus(_ value: String) throws {
    guard validSessionStatuses.contains(value) else {
        throw ValidationError("'\(value)' is not a valid status. Expected one of: \(validSessionStatuses.joined(separator: ", "))")
    }
}

/// Validate that a string is a recognized link type.
///
/// - Throws: `ValidationError` if the string is not one of: ticket, pr, repo, custom.
func validateLinkType(_ value: String) throws {
    guard validLinkTypes.contains(value) else {
        throw ValidationError("'\(value)' is not a valid link type. Expected one of: \(validLinkTypes.joined(separator: ", "))")
    }
}

/// Validate that a job repo is an `owner/repo` slug (nested GitLab groups
/// allowed). The slug's last component becomes an on-disk folder name, so
/// path-like components (`.`, `..`, empty) are rejected. Mirrors the server's
/// check for fast local feedback.
///
/// - Throws: `ValidationError` for a bare name or path-like slug.
func validateRepoSlug(_ value: String) throws {
    let repo = value.trimmingCharacters(in: .whitespaces)
    let components = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 2,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw ValidationError("'\(value)' is not a valid repo. Expected an owner/repo slug (e.g. corveil/crow); components must not be empty, '.', or '..'.")
    }
}

/// Validate that a job name is not blank after trimming.
///
/// - Throws: `ValidationError` for an empty or whitespace-only name.
func validateJobName(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ValidationError("--name must not be blank.")
    }
}

/// Validate that a notification sound is one of the built-in sounds, matching
/// the Settings UI's sound picker (which only offers those). Delegates to
/// `NotificationSettings.canonicalSoundName` — the same predicate the
/// `notifications-set` handler enforces with — so the two can't drift.
///
/// - Throws: `ValidationError` listing the built-in sounds when unmatched.
func validateNotificationSound(_ value: String) throws {
    guard NotificationSettings.canonicalSoundName(value) != nil else {
        throw ValidationError("'\(value)' is not a built-in sound. Expected one of: \(NotificationSettings.builtInSounds.joined(separator: ", "))")
    }
}

/// Validate that at least one optional field is provided for set-ticket.
///
/// - Throws: `ValidationError` if all four fields are nil.
func validateSetTicketHasField(url: String?, title: String?, number: Int?, priority: String? = nil) throws {
    guard url != nil || title != nil || number != nil || priority != nil else {
        throw ValidationError("At least one of --url, --title, --number, or --priority is required.")
    }
}

/// Valid ticket priority values accepted by `set-ticket --priority` (#696).
/// Matches CrowCore's `TicketPriority` ladder minus `unknown` (clearing back
/// to unknown isn't a CLI operation).
let validTicketPriorities = ["highest", "high", "medium", "low", "lowest"]

/// Validate that a string is a recognized ticket priority, case-insensitively.
///
/// - Throws: `ValidationError` if not one of: highest, high, medium, low, lowest.
func validateTicketPriority(_ value: String) throws {
    guard validTicketPriorities.contains(value.lowercased()) else {
        throw ValidationError("'\(value)' is not a valid priority. Expected one of: \(validTicketPriorities.joined(separator: ", "))")
    }
}

/// Normalize repeatable `--pattern` values for `promote-allowlist` (#819): trim
/// each, drop blanks, dedupe preserving first-seen order, and require at least
/// one survivor. A blank pattern would be written verbatim into
/// `~/.claude/settings.json` and silently grant nothing. Returns a value rather
/// than `Void` like its neighbors because `validate()` and `run()` share it.
///
/// - Throws: `ValidationError` when no non-blank pattern remains.
func normalizedAllowlistPatterns(_ raw: [String]) throws -> [String] {
    var seen = Set<String>()
    let cleaned = raw
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !cleaned.isEmpty else {
        throw ValidationError("At least one non-blank --pattern is required.")
    }
    return cleaned
}

/// Normalize repeatable `crow defaults set --add-…` / `--remove-…` values
/// (#810): trim each, drop blanks, dedupe preserving first-seen order, and
/// require at least one survivor. Returns a value rather than `Void` because
/// `validate()` and `run()` share it.
///
/// Deduping is case-INSENSITIVE, unlike `normalizedAllowlistPatterns` above.
/// These values are matched case-insensitively by their consumers
/// (`repoMatchesPatterns` lowercases both sides; ignored labels go through a
/// lowercased Set), so `Owner/Repo` and `owner/repo` are one entry. Allowlist
/// patterns are matched literally, so there the two really are different rules.
///
/// - Throws: `ValidationError` when no non-blank value remains — a flag passed
///   with only whitespace is a typo, and sending it would be an inert write
///   reported as a success.
func normalizedListValues(_ raw: [String], flag: String) throws -> [String] {
    var seen = Set<String>()
    let cleaned = raw
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    guard !cleaned.isEmpty else {
        throw ValidationError("\(flag) needs at least one non-blank value.")
    }
    return cleaned
}

/// Valid `quick-action --action` values (CROW-817). Mirrors CrowCore's
/// `QuickAction` cases; CrowCLI doesn't depend on CrowCore, so this is a
/// hand-kept copy — the daemon re-validates and returns the same list in its
/// error message.
let validQuickActions = ["fixConflicts", "addressChanges", "fixChecks", "mergePR", "reReview"]

/// Validate that a string is a recognized PR quick action.
///
/// - Throws: `ValidationError` if not one of: fixConflicts, addressChanges,
///   fixChecks, mergePR, reReview.
func validateQuickAction(_ value: String) throws {
    guard validQuickActions.contains(value) else {
        throw ValidationError("'\(value)' is not a valid action. Expected one of: \(validQuickActions.joined(separator: ", "))")
    }
}

/// Validate a ticket URL that will be typed into the Manager terminal.
///
/// Mirrors the daemon's `isSafeIssueURL` for fast local feedback: an http(s)
/// URL with no whitespace and no control characters. Whitespace matters beyond
/// tidiness — `TerminalRouter` turns newlines into Enter presses, so an
/// embedded newline would split the injected prompt.
///
/// - Throws: `ValidationError` for a blank, non-http(s), or whitespace/control-bearing URL.
func validateIssueURL(_ value: String) throws {
    guard !value.isEmpty,
          value.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil,
          !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
        throw ValidationError("'\(value)' is not a valid URL. Expected an http(s) URL with no whitespace or control characters.")
    }
}

/// Validate the OTLP receiver port for `crow telemetry set --port` (#814).
/// Below 1024 needs root, which `crowd` doesn't have; above 65535 isn't a port
/// and wouldn't fit `TelemetryConfig.port`'s `UInt16`. Mirrors the server's
/// check for fast local feedback.
///
/// - Throws: `ValidationError` outside 1024–65535.
func validateTelemetryPort(_ value: Int) throws {
    guard (1024...65535).contains(value) else {
        throw ValidationError("'\(value)' is not a valid port. Expected 1024-65535.")
    }
}

/// Validate telemetry retention for `crow telemetry set --retention-days` (#814).
/// 0 is legal and means "keep forever" — it's the pruner's documented no-op.
///
/// - Throws: `ValidationError` for a negative value.
func validateRetentionDays(_ value: Int) throws {
    guard value >= 0 else {
        throw ValidationError("'\(value)' is not a valid retention. Expected 0 or greater (0 = keep forever).")
    }
}

/// Validate session-cleanup retention for `crow cleanup set --retention-hours`
/// (#814). Unlike telemetry there is no "forever": the cutoff is
/// `now - retentionHours`, so 0 deletes a session the moment it completes and a
/// negative value pushes the cutoff into the future, sweeping every completed
/// and archived session — worktree and branch included.
///
/// - Throws: `ValidationError` below 1.
func validateRetentionHours(_ value: Int) throws {
    guard value >= 1 else {
        throw ValidationError("'\(value)' is not a valid retention. Expected 1 hour or more.")
    }
}

/// Validate `crow defaults set --provider` (#810). Delegates to
/// `ConfigDefaults.validProviders` rather than keeping a copy — `GitManager`
/// compares the stored value with `==`, so an accepted casing variant would
/// silently fall through to the wrong forge branch.
///
/// - Throws: `ValidationError` listing the accepted providers.
func validateProvider(_ value: String) throws {
    guard ConfigDefaults.validProviders.contains(value) else {
        throw ValidationError("'\(value)' is not a valid provider. Expected one of: \(ConfigDefaults.validProviders.joined(separator: ", "))")
    }
}

/// Validate `crow defaults set --cli` (#810), the forge CLI `GitManager` shells
/// out to. Stored independently of `--provider`, so a crossed pair is legal but
/// warned about server-side.
///
/// - Throws: `ValidationError` listing the accepted CLIs.
func validateForgeCLI(_ value: String) throws {
    guard ConfigDefaults.validCLIs.contains(value) else {
        throw ValidationError("'\(value)' is not a valid forge CLI. Expected one of: \(ConfigDefaults.validCLIs.joined(separator: ", "))")
    }
}

/// Validate `crow defaults set --branch-prefix` (#810) against the model's own
/// `ConfigDefaults.isValidBranchPrefix`, so the CLI and the daemon can't drift
/// on what git will accept as a ref. Trimmed first, matching the handler: a
/// pasted trailing space is a typo, not a request for an invalid prefix. An
/// empty prefix is legal and means "no prefix".
///
/// - Throws: `ValidationError` for a prefix git would reject as a ref name.
func validateBranchPrefix(_ value: String) throws {
    guard ConfigDefaults.isValidBranchPrefix(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ValidationError("'\(value)' is not a valid branch prefix. It must not contain a space, any of ~^:?*[\\, '..', '@{', or end in '.'")
    }
}

/// Parse repeatable `crow defaults set --binary NAME=PATH` values into the map
/// the `binaries` param carries (#810). Returns a value rather than `Void` like
/// most of its neighbours because `validate()` and `run()` share it.
///
/// Splits on the **first** `=` only, so a path may contain one
/// (`--binary codex=/opt/codex=v2/bin/codex`). A blank PATH is meaningful — it
/// removes the entry — and is the only way to unset an override.
///
/// `~` is expanded here rather than server-side: `Scaffolder` probes the target
/// with `isExecutableFile(atPath:)`, which does no tilde expansion, so an
/// unexpanded `~/bin/x` would be stored happily and then silently never resolve.
/// Relative paths are rejected for the same reason — that call resolves them
/// against the *daemon's* cwd, not the caller's shell.
///
/// A duplicate NAME is rejected rather than resolved last-wins: two `--binary`
/// values for one tool are contradictory, and silently discarding one is the
/// mistake `notifications-set` avoided with `@Flag(exclusivity: .exclusive)`.
///
/// - Throws: `ValidationError` for a missing `=`, a blank/path-like/reserved
///   name, a relative path, or a repeated name.
func parseBinaryOverrides(_ raw: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for entry in raw {
        guard let separator = entry.firstIndex(of: "=") else {
            throw ValidationError("'\(entry)' is not a valid --binary value. Expected NAME=PATH (e.g. corveil=/opt/corveil/bin/corveil); NAME= removes the entry.")
        }
        let name = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
        guard name != ConfigDefaults.reservedBinaryName else {
            throw ValidationError("'\(ConfigDefaults.reservedBinaryName)' is reserved — Crow always points {devRoot}/.claude/bin/crow at the running app's own CLI, so an override here is overwritten on every launch.")
        }
        guard ConfigDefaults.isValidBinaryName(name) else {
            throw ValidationError("'\(name)' is not a valid binary name. Expected a plain name like corveil or codex.")
        }
        guard result[name] == nil else {
            throw ValidationError("--binary \(name) was given more than once. Pass one value per binary.")
        }
        var path = String(entry[entry.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        if path == "~" || path.hasPrefix("~/") {
            path = NSString(string: path).expandingTildeInPath
        }
        guard path.isEmpty || path.hasPrefix("/") else {
            throw ValidationError("'\(path)' is not an absolute path. --binary needs an absolute path (it is resolved by the daemon, not your shell); use NAME= to remove the entry.")
        }
        result[name] = path
    }
    return result
}

/// Validate a `crow gateway set --header` value: `Name: Value`.
///
/// A blank *value* is legal and meaningful — `--header "X-Api-Key:"` means
/// "keep the secret already stored for this header", which is how the base URL
/// can be changed without restating the key. A missing colon or blank name is
/// rejected so a typo'd flag fails loudly instead of being dropped server-side.
///
/// One `--header` must mean one header: the daemon parses these by splitting on
/// newlines, so an embedded `\n` would smuggle in a second header. Reject it
/// here so the typo fails loudly at the flag rather than silently expanding.
///
/// - Throws: `ValidationError` when the line has no colon, an empty name, or an
///   embedded newline.
func validateHeaderLine(_ value: String) throws {
    // CharacterSet, not `contains("\n")`: Swift treats CRLF as a single Character,
    // so a grapheme comparison misses "\r\n" entirely.
    guard value.rangeOfCharacter(from: .newlines) == nil else {
        throw ValidationError(
            "A --header must be a single line — '\(value)' contains a newline. Pass one --header per header.")
    }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard let colon = trimmed.firstIndex(of: ":"),
          !String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ValidationError(
            "'\(value)' is not a valid header. Expected 'Name: Value' (e.g. \"X-Api-Key: sk-…\").")
    }
}

/// Validate a workspace code provider for `crow workspace add|edit` (CROW-809).
/// Delegates to `WorkspaceInfo.validProviders` — the same list the handler enforces
/// with — so the two can't drift.
///
/// - Throws: `ValidationError` when not github or gitlab.
func validateWorkspaceProvider(_ value: String) throws {
    guard WorkspaceInfo.validProviders.contains(value.trimmingCharacters(in: .whitespaces)) else {
        throw ValidationError("'\(value)' is not a valid provider. Expected one of: \(WorkspaceInfo.validProviders.joined(separator: ", "))")
    }
}

/// Validate a workspace task provider. An empty string is legal and means
/// "follow the code provider" — the Settings dropdown's blank option.
///
/// - Throws: `ValidationError` when not one of the four providers or "".
func validateWorkspaceTaskProvider(_ value: String) throws {
    let provider = value.trimmingCharacters(in: .whitespaces)
    guard provider.isEmpty || WorkspaceInfo.validTaskProviders.contains(provider) else {
        throw ValidationError("'\(value)' is not a valid task provider. Expected one of: \(WorkspaceInfo.validTaskProviders.joined(separator: ", ")), or \"\" to follow the code provider")
    }
}

/// Validate a `crow workspace --session-env` entry: `KEY=VALUE`.
///
/// A blank *value* is legal — an env var set to the empty string is meaningfully
/// different from an unset one. A missing `=` or blank key is rejected so a
/// typo'd flag fails loudly instead of being silently dropped by the parser.
///
/// Newlines are rejected for the same reason as in `validateHeaderLine`: the
/// value is exported into the agent's shell environment, where an embedded
/// newline would read as a second statement.
///
/// The key is checked for whitespace and control characters as well. Splitting
/// on the first `=` means a key here can never contain one — but it can contain
/// a space, and `FOO BAR` is an entry no shell can ever reference. Mirrors
/// `WorkspaceRPC.decodeSessionEnv`, which enforces the same rules for the remote
/// `/rpc` writers this function never sees.
///
/// - Throws: `ValidationError` when the entry has no `=`, a blank key, an
///   embedded newline, or a key carrying whitespace or control characters.
func validateSessionEnvEntry(_ value: String) throws {
    // CharacterSet, not `contains("\n")`: Swift treats CRLF as a single
    // Character, so a grapheme comparison misses "\r\n" entirely.
    guard value.rangeOfCharacter(from: .newlines) == nil else {
        throw ValidationError(
            "A --session-env entry must be a single line — '\(value)' contains a newline.")
    }
    guard let split = value.firstIndex(of: "=") else {
        throw ValidationError(
            "'\(value)' is not a valid env entry. Expected 'KEY=VALUE' (e.g. \"AWS_PROFILE=dev\").")
    }
    // Trimmed to match `WorkspaceFieldArgs.parseSessionEnv`, which trims the key
    // before sending it — so surrounding spaces are a typo, not a rejection.
    let key = String(value[..<split]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else {
        throw ValidationError(
            "'\(value)' is not a valid env entry. Expected 'KEY=VALUE' (e.g. \"AWS_PROFILE=dev\").")
    }
    guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          key.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw ValidationError(
            "'\(key)' is not a valid env variable name — it must not contain whitespace or control characters.")
    }
}

/// Validate the set-goal argument shape: exactly one of `--goal`/`--clear`,
/// and a provided goal must not be blank (a whitespace goal would silently
/// fail to earn the on-goal alignment multiplier).
///
/// - Throws: `ValidationError` on both, neither, or a blank goal.
func validateSetGoal(goal: String?, clear: Bool) throws {
    switch (goal, clear) {
    case (.some, true):
        throw ValidationError("--goal and --clear are mutually exclusive.")
    case (nil, false):
        throw ValidationError("Exactly one of --goal or --clear is required.")
    case (.some(let goal), false):
        guard !goal.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--goal must not be blank.")
        }
    case (nil, true):
        break
    }
}
