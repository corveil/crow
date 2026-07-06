import Foundation

/// A development session representing work on a ticket or feature.
public struct Session: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var status: SessionStatus
    public var kind: SessionKind
    public var agentKind: AgentKind
    public var ticketURL: String?
    public var ticketTitle: String?
    public var ticketNumber: Int?
    public var provider: Provider?
    // Code-source provider, distinct from the task-source `provider`. Lets a
    // Corveil-tasked session use a GitHub or GitLab `CodeBackend` (ADR 0005,
    // CROW-414). `nil` means "follow `provider`"; callers resolve with
    // `session.codeProvider ?? session.provider`.
    public var codeProvider: Provider?
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
    // Timestamp at which Crow enabled GitHub native auto-merge on the
    // linked PR (CROW-299). Non-nil means the one-shot enable has already
    // run; the auto-merge watcher skips this session on subsequent polls.
    public var autoMergeEnabledAt: Date?
    // Whether the user has locked this session to exempt it from the retention
    // cleanup reaper (CROW-569 shipped this as "pinned"; CROW-573 renamed the
    // metaphor to "lock"). Locked sessions are never auto-archived/deleted by
    // `cleanup.retentionHours` regardless of age. Applies to any session kind,
    // including scheduled `job` sessions (the motivating case). Defaults to
    // `false`; the decoder also reads the legacy `pinned` key so sessions locked
    // under CROW-569 stay locked after upgrade.
    public var locked: Bool

    // PR author login for a `.review` session (e.g. "octocat"), captured at
    // review-creation from the PR itself. Lets the UI show "PR by @author" even
    // when the Reviews board (which otherwise carries the author) is empty. Nil
    // for non-review sessions and for legacy review sessions predating this
    // field (CROW-593).
    public var reviewAuthor: String?

    /// Whether this session is a Manager (orchestration) session. Managers run
    /// Claude Code in the devRoot and are excluded from PR/issue tracking.
    public var isManager: Bool { kind == .manager }

    /// Short label for the session's ticket badge/chip, or `nil` when no ticket
    /// is attached. Jira tickets have no standalone numeric id, so prefer the
    /// validated key (`MAXX-6859`) parsed from the browse URL; otherwise fall
    /// back to `Issue #<number>` (GitHub/GitLab) or a bare `Issue` when only a
    /// URL is known. Keeps the sidebar badge from vanishing on Jira sessions,
    /// which carry `ticketURL`/`ticketTitle` but a nil `ticketNumber` (CROW-463).
    public var ticketBadgeLabel: String? {
        if let url = ticketURL, Validation.isJiraSpec(url), let key = Validation.jiraKey(from: url) {
            return key
        }
        if let num = ticketNumber { return "Issue #\(num)" }
        if ticketURL != nil { return "Issue" }
        return nil
    }

    public init(
        id: UUID = UUID(),
        name: String,
        status: SessionStatus = .active,
        kind: SessionKind = .work,
        agentKind: AgentKind = .claudeCode,
        ticketURL: String? = nil,
        ticketTitle: String? = nil,
        ticketNumber: Int? = nil,
        provider: Provider? = nil,
        codeProvider: Provider? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        reviewPromptDispatched: Bool = false,
        lastReviewedHeadSha: String? = nil,
        autoMergeEnabledAt: Date? = nil,
        locked: Bool = false,
        reviewAuthor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.kind = kind
        self.agentKind = agentKind
        self.ticketURL = ticketURL
        self.ticketTitle = ticketTitle
        self.ticketNumber = ticketNumber
        self.provider = provider
        self.codeProvider = codeProvider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewPromptDispatched = reviewPromptDispatched
        self.lastReviewedHeadSha = lastReviewedHeadSha
        self.autoMergeEnabledAt = autoMergeEnabledAt
        self.locked = locked
        self.reviewAuthor = reviewAuthor
    }

    /// Parse a GitHub PR URL (`https://github.com/<owner>/<repo>/pull/<number>`)
    /// into its components. Returns `nil` if the URL is malformed. Shared by
    /// `SessionService.createReviewSession` and the kickoff-dedup helpers on
    /// `AppState`; keep here so callers don't reinvent the same parser.
    public static func parseReviewPR(url: String) -> (owner: String, repo: String, number: Int)? {
        let components = url.split(separator: "/")
        guard components.count >= 5,
              let number = Int(components.last ?? "") else { return nil }
        let owner = String(components[components.count - 4])
        let repo = String(components[components.count - 3])
        return (owner, repo, number)
    }

    // Backward-compatible decoding: default `kind`, `agentKind`, and
    // `reviewPromptDispatched` when missing from older persisted data.
    // `reviewPromptDispatched` defaults to `true` so existing review sessions
    // don't re-trigger their prompt on first launch after upgrade (CROW-224).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(SessionStatus.self, forKey: .status)
        kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .work
        agentKind = try container.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .claudeCode
        ticketURL = try container.decodeIfPresent(String.self, forKey: .ticketURL)
        ticketTitle = try container.decodeIfPresent(String.self, forKey: .ticketTitle)
        ticketNumber = try container.decodeIfPresent(Int.self, forKey: .ticketNumber)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider)
        codeProvider = try container.decodeIfPresent(Provider.self, forKey: .codeProvider)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        reviewPromptDispatched = try container.decodeIfPresent(Bool.self, forKey: .reviewPromptDispatched) ?? true
        lastReviewedHeadSha = try container.decodeIfPresent(String.self, forKey: .lastReviewedHeadSha)
        autoMergeEnabledAt = try container.decodeIfPresent(Date.self, forKey: .autoMergeEnabledAt)
        reviewAuthor = try container.decodeIfPresent(String.self, forKey: .reviewAuthor)
        // CROW-573 renamed `pinned` → `locked`. Prefer the new key, but fall
        // back to the legacy `pinned` key so sessions locked under CROW-569
        // remain locked after upgrade.
        if let locked = try container.decodeIfPresent(Bool.self, forKey: .locked) {
            self.locked = locked
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self)
            self.locked = (try? legacy?.decodeIfPresent(Bool.self, forKey: .pinned)) ?? nil ?? false
        }
    }

    /// Legacy coding keys for fields renamed after they shipped. Used only by
    /// the decoder to read older persisted data; the synthesized encoder always
    /// writes the current key names.
    private enum LegacyCodingKeys: String, CodingKey {
        case pinned
    }
}
