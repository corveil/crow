import ArgumentParser
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
        throw ValidationError("'\(value)' is not a valid repo. Expected an owner/repo slug (e.g. radiusmethod/crow); components must not be empty, '.', or '..'.")
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
