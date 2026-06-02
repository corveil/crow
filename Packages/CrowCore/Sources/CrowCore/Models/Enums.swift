import Foundation

/// What kind of session this is. Multiple `.manager` sessions can coexist;
/// the one with `AppState.managerSessionID` is the back-compat "primary".
public enum SessionKind: String, Codable, Sendable {
    case work    // Normal development session (default)
    case review  // PR review session
    case job     // Session spun up by a scheduled job (CROW-317)
    case manager // Orchestration session running Claude Code in the devRoot
}

/// Status of a development session.
public enum SessionStatus: String, Codable, Sendable {
    case active
    case paused
    case inReview
    case completed
    case archived
}

/// Git provider type.
public enum Provider: String, Codable, Sendable {
    case github
    case gitlab
}

/// Type of link associated with a session.
public enum LinkType: String, Codable, Sendable {
    case ticket
    case pr
    case repo
    case custom
}

/// Coding-agent activity state as inferred from hook events.
public enum AgentActivityState: String, Codable, Sendable {
    case idle
    case working
    case waiting
    case done
}

/// Terminal surface lifecycle state.
public enum TerminalReadiness: String, Codable, Sendable, Comparable {
    case failed           // createSurface() exhausted retries; UI shows error overlay with Retry
    case uninitialized    // GhosttySurfaceView exists but createSurface() not called
    case surfaceCreated   // ghostty_surface_t exists, shell process spawning
    case timedOut         // Sentinel never appeared within the readiness budget; UI shows Retry
    case shellReady       // Shell prompt detected (probe file appeared)
    case agentLaunched    // Agent launch command has been sent

    private var sortOrder: Int {
        switch self {
        case .failed: -1
        case .uninitialized: 0
        case .surfaceCreated: 1
        case .timedOut: 2
        case .shellReady: 3
        case .agentLaunched: 4
        }
    }

    public static func < (lhs: TerminalReadiness, rhs: TerminalReadiness) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Pipeline status for a ticket, derived from project board fields.
public enum TicketStatus: String, Codable, Sendable, CaseIterable {
    case backlog    = "Backlog"
    case ready      = "Ready"
    case inProgress = "In Progress"
    case inReview   = "In Review"
    case done       = "Done"
    case unknown    = "Unknown"

    /// The pipeline stages shown in the UI (including Done).
    public static let pipelineStatuses: [TicketStatus] = [.backlog, .ready, .inProgress, .inReview, .done]

    /// Initialize from a GitHub/GitLab project board status name (case-insensitive).
    public init(projectBoardName name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "backlog": self = .backlog
        case "ready", "todo", "to do": self = .ready
        case "in progress", "doing", "active": self = .inProgress
        case "in review", "review": self = .inReview
        case "done", "closed", "complete", "completed": self = .done
        default: self = .unknown
        }
    }
}

/// Sort order options for the ticket board.
public enum TicketSortOrder: String, CaseIterable, Sendable {
    case updatedDesc = "Recently Updated"
    case updatedAsc  = "Oldest Updated"
    case titleAsc    = "Title A–Z"
    case titleDesc   = "Title Z–A"
    case numberDesc  = "Newest"
    case numberAsc   = "Oldest"
}
