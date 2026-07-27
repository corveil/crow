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

/// Validate a `crow gateway set --header` value: `Name: Value`.
///
/// A blank *value* is legal and meaningful — `--header "X-Api-Key:"` means
/// "keep the secret already stored for this header", which is how the base URL
/// can be changed without restating the key. A missing colon or blank name is
/// rejected so a typo'd flag fails loudly instead of being dropped server-side.
///
/// - Throws: `ValidationError` when the line has no colon or an empty name.
func validateHeaderLine(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard let colon = trimmed.firstIndex(of: ":"),
          !String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ValidationError(
            "'\(value)' is not a valid header. Expected 'Name: Value' (e.g. \"X-Api-Key: sk-…\").")
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
