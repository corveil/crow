import Foundation

/// Normalized ticket priority ladder (ADR 0008 follow-up 8 — alignment/KPI
/// mapping). Jira is the only backend that surfaces a priority today;
/// GitHub/GitLab/Corveil tickets carry no priority and stay `nil` on the
/// models, which the alignment weight treats the same as `.unknown`.
public enum TicketPriority: String, Codable, Sendable, CaseIterable {
    case highest
    case high
    case medium
    case low
    case lowest
    case unknown

    /// Map a Jira priority name onto the normalized ladder, case-insensitively.
    /// Covers the modern Jira Cloud scheme (Highest…Lowest), the classic
    /// scheme (Blocker/Critical/Major/Minor/Trivial), and the enum's own raw
    /// values (so CLI input like `--priority high` maps directly).
    /// `nil` or an unrecognized custom name → `.unknown`.
    public init(jiraName: String?) {
        switch jiraName?.lowercased() {
        case "highest", "blocker": self = .highest
        case "high", "critical": self = .high
        case "medium", "major": self = .medium
        case "low", "minor": self = .low
        case "lowest", "trivial": self = .lowest
        default: self = .unknown
        }
    }
}
