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
///
/// Per ADR 0005 a "provider" is really two independent axes — a task tracker
/// (where the work-unit lives) and a code host (where the PR lives). `.jira` is
/// a **task-only** provider (no embedded git, like `.corveil`): a Jira-tasked
/// session pairs with a GitHub/GitLab `CodeBackend` via `Session.codeProvider`.
public enum Provider: String, Codable, Sendable {
    case github
    case gitlab
    case corveil
    case jira

    /// Task-only providers have no code/VCS surface (`ProviderManager.codeBackend`
    /// returns `nil`). A session tracked by one of these resolves its code
    /// operations through `Session.codeProvider` instead.
    public var isTaskOnly: Bool {
        switch self {
        case .corveil, .jira: return true
        case .github, .gitlab: return false
        }
    }
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
    case uninitialized    // Surface exists but createSurface() not called
    case surfaceCreated   // Web surface loaded, shell process spawning
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

    /// The built-in Crow→Jira workflow status name for this pipeline status, used
    /// as the fallback when a workspace has no per-project override (#523). Raw
    /// values already match common Jira names ("In Progress", "In Review", "Done",
    /// "Backlog"); only `.ready` needs a Jira-flavored alias ("To Do"). Surfaced
    /// in CrowCore so both the Settings UI (placeholders) and `JiraTaskBackend`
    /// (the live transition) share one source of truth.
    public var defaultJiraStatusName: String {
        switch self {
        case .ready: return "To Do"
        case .backlog, .inProgress, .inReview, .done, .unknown:
            return rawValue
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
