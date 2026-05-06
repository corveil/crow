import Foundation

/// A pull request where the current user has been requested as a reviewer.
public struct ReviewRequest: Identifiable, Codable, Sendable {
    public let id: String             // "github:org/repo#123"
    public var prNumber: Int
    public var title: String
    public var url: String             // full PR URL
    public var repo: String            // "org/repo"
    public var author: String          // PR author login
    public var headBranch: String
    public var baseBranch: String
    public var isDraft: Bool
    public var requestedAt: Date?
    public var labels: [String]
    public var provider: Provider
    public var reviewSessionID: UUID?  // set if a review session already exists

    public init(
        id: String,
        prNumber: Int,
        title: String,
        url: String,
        repo: String,
        author: String,
        headBranch: String,
        baseBranch: String,
        isDraft: Bool = false,
        requestedAt: Date? = nil,
        labels: [String] = [],
        provider: Provider = .github,
        reviewSessionID: UUID? = nil
    ) {
        self.id = id
        self.prNumber = prNumber
        self.title = title
        self.url = url
        self.repo = repo
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.isDraft = isDraft
        self.requestedAt = requestedAt
        self.labels = labels
        self.provider = provider
        self.reviewSessionID = reviewSessionID
    }
}
