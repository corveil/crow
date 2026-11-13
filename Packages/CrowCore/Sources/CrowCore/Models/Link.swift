import Foundation

/// A link (issue, PR, repo) associated with a session.
public struct SessionLink: Identifiable, Codable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var label: String
    public var url: String
    public var linkType: LinkType
    /// The auto-rebase watcher's record of the merge-conflict prompts it has
    /// already sent for this PR (CROW-1453). Only ever set on a `.pr` link.
    /// It lives here, in `store.json`, rather than in the watcher's memory so
    /// a `crowd` restart, or a board poll that happens to omit this PR, can't
    /// make the watcher forget a hand-off and type the same prompt again.
    /// Optional so older `store.json` files still decode.
    public var autoRebaseConflictHandoff: AutoRebaseConflictHandoff?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        label: String,
        url: String,
        linkType: LinkType,
        autoRebaseConflictHandoff: AutoRebaseConflictHandoff? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.label = label
        self.url = url
        self.linkType = linkType
        self.autoRebaseConflictHandoff = autoRebaseConflictHandoff
    }
}

/// How many times the auto-rebase watcher has handed one PR head's merge
/// conflicts to the session's agent (CROW-1453).
///
/// The record is per head commit: a record for an older `headRefOid` means
/// nothing for the current one, so pushing a new head starts the count again.
/// Crow clears it when the PR merges or closes, when the operator clicks
/// **Rebase & Fix Conflicts**, and when the auto-rebase setting is turned off.
public struct AutoRebaseConflictHandoff: Codable, Sendable, Equatable {
    /// The PR head commit the prompts were about.
    public var headRefOid: String
    /// Conflict prompts sent to the agent for `headRefOid`.
    public var prompts: Int

    public init(headRefOid: String, prompts: Int) {
        self.headRefOid = headRefOid
        self.prompts = prompts
    }

    /// Prompts already sent for `headRefOid`: the stored count when the record
    /// is about that head, and zero otherwise.
    public func prompts(forHead headRefOid: String) -> Int {
        self.headRefOid == headRefOid ? prompts : 0
    }
}
