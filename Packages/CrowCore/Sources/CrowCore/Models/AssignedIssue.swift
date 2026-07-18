import Foundation

/// A GitHub/GitLab issue assigned to the current user.
public struct AssignedIssue: Identifiable, Codable, Sendable {
    public let id: String           // "github:org/repo#123" or "gitlab:host:org/repo#123"
    public var number: Int
    public var title: String
    public var state: String        // "open", "closed"
    public var url: String
    public var repo: String         // "org/repo"
    public var labels: [LabelInfo]
    public var provider: Provider
    /// PR number linked via closing issue references, if any.
    public var prNumber: Int?
    /// URL of the linked pull request, if any.
    public var prURL: String?
    public var updatedAt: Date?
    /// Normalized ticket priority (#696, ADR 0008 follow-up 8). Only Jira
    /// surfaces one today; nil for GitHub/GitLab/Corveil issues and for
    /// records persisted before this field existed.
    public var priority: TicketPriority?
    /// Raw tracker priority name (e.g. Jira "Critical"), preserved so custom
    /// priority schemes that normalize to `.unknown` stay inspectable.
    public var priorityName: String?
    /// Epic/parent work-item key (Jira Cloud unified `parent` field). Fetched
    /// for future epic-based goal inference; unused by the v1 alignment weight.
    public var parentKey: String?
    /// Epic/parent summary, when the tracker provides it.
    public var parentSummary: String?
    /// Pipeline status from the GitHub/GitLab project board.
    public var projectStatus: TicketStatus
    /// Issue body, server-capped to bound the board payload (#751). Plain text
    /// (GitHub `bodyText` / GitLab `description`); nil for records fetched
    /// before this field existed.
    public var body: String?
    /// Login/username of the issue author (#751).
    public var author: String?
    /// When the issue was opened (#751).
    public var createdAt: Date?
    /// Number of comments/notes on the issue (#751).
    public var commentsCount: Int?
    /// Normalized linked-PR state — "draft" / "open" / "merged" / "closed"
    /// (#751). nil when no PR is linked.
    public var prState: String?
    /// CI check rollup for the linked PR — "SUCCESS" / "FAILURE" / "PENDING" /
    /// "ERROR" / … (#751). nil when no PR or no checks.
    public var checksState: String?
    /// Names of failing CI checks on the linked PR, for the checks tooltip (#751).
    public var failedCheckNames: [String]?

    public init(
        id: String, number: Int, title: String, state: String,
        url: String, repo: String, labels: [LabelInfo] = [],
        provider: Provider, prNumber: Int? = nil, prURL: String? = nil,
        updatedAt: Date? = nil, priority: TicketPriority? = nil,
        priorityName: String? = nil, parentKey: String? = nil,
        parentSummary: String? = nil, projectStatus: TicketStatus = .unknown,
        body: String? = nil, author: String? = nil, createdAt: Date? = nil,
        commentsCount: Int? = nil, prState: String? = nil,
        checksState: String? = nil, failedCheckNames: [String]? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.repo = repo
        self.labels = labels
        self.provider = provider
        self.prNumber = prNumber
        self.prURL = prURL
        self.updatedAt = updatedAt
        self.priority = priority
        self.priorityName = priorityName
        self.parentKey = parentKey
        self.parentSummary = parentSummary
        self.projectStatus = projectStatus
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.commentsCount = commentsCount
        self.prState = prState
        self.checksState = checksState
        self.failedCheckNames = failedCheckNames
    }
}
