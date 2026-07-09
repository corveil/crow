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
/// - Throws: `ValidationError` if all three fields are nil.
func validateSetTicketHasField(url: String?, title: String?, number: Int?) throws {
    guard url != nil || title != nil || number != nil else {
        throw ValidationError("At least one of --url, --title, or --number is required.")
    }
}
