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
    /// Pipeline status from the GitHub/GitLab project board.
    public var projectStatus: TicketStatus

    public init(
        id: String, number: Int, title: String, state: String,
        url: String, repo: String, labels: [LabelInfo] = [],
        provider: Provider, prNumber: Int? = nil, prURL: String? = nil,
        updatedAt: Date? = nil, projectStatus: TicketStatus = .unknown
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
        self.projectStatus = projectStatus
    }
}
