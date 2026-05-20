import Foundation

/// A development session representing work on a ticket or feature.
public struct Session: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var status: SessionStatus
    public var kind: SessionKind
    public var ticketURL: String?
    public var ticketTitle: String?
    public var ticketNumber: Int?
    public var provider: Provider?
    public var createdAt: Date
    public var updatedAt: Date
    // Whether a review-kind session has had its initial `/crow-review-pr`
    // prompt dispatched. Gates the launchClaude prompt-vs-`--continue`
    // branch so completed reviews don't restart on app relaunch.
    public var reviewPromptDispatched: Bool
    // Head SHA of the PR at the time the review session was created or
    // last re-launched. Used by the kickoff guard as a fallback re-kick
    // signal when a PR's head advances without an explicit re-request
    // (e.g. force-push) or before the viewer-submitted-review signal is
    // observed. Nil for non-review sessions and for legacy persisted
    // sessions predating this field (CROW-290).
    public var lastReviewedHeadSha: String?

    public init(
        id: UUID = UUID(),
        name: String,
        status: SessionStatus = .active,
        kind: SessionKind = .work,
        ticketURL: String? = nil,
        ticketTitle: String? = nil,
        ticketNumber: Int? = nil,
        provider: Provider? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        reviewPromptDispatched: Bool = false,
        lastReviewedHeadSha: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.kind = kind
        self.ticketURL = ticketURL
        self.ticketTitle = ticketTitle
        self.ticketNumber = ticketNumber
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewPromptDispatched = reviewPromptDispatched
        self.lastReviewedHeadSha = lastReviewedHeadSha
    }

    // Backward-compatible decoding: default `kind` to `.work` when missing
    // from older persisted data. `reviewPromptDispatched` defaults to `true`
    // when missing so existing review sessions don't re-trigger their prompt
    // on the first launch after upgrade (CROW-224).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(SessionStatus.self, forKey: .status)
        kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .work
        ticketURL = try container.decodeIfPresent(String.self, forKey: .ticketURL)
        ticketTitle = try container.decodeIfPresent(String.self, forKey: .ticketTitle)
        ticketNumber = try container.decodeIfPresent(Int.self, forKey: .ticketNumber)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        reviewPromptDispatched = try container.decodeIfPresent(Bool.self, forKey: .reviewPromptDispatched) ?? true
        lastReviewedHeadSha = try container.decodeIfPresent(String.self, forKey: .lastReviewedHeadSha)
    }
}
