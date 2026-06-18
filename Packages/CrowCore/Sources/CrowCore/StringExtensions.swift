import Foundation

public extension String {
    /// The whitespace-and-newline-trimmed string, or `nil` if it is empty after
    /// trimming. Single source for the "treat a blank value as unset" rule shared
    /// across the Jira status-mapping code (#523) — a blank override field falls
    /// back to the built-in default.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
