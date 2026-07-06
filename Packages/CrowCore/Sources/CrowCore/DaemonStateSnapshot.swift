import Foundation

/// A complete, `Codable` snapshot of the render-critical `AppState` that `crowd`
/// pushes to rich clients (the macOS app) so they can rebuild their `AppState`
/// from a single `get-state` RPC — the counterpart to `EventHub`'s `changed`
/// nudge, which only says *when* to re-fetch (ADR 0007; CROW-581, Stage 2/F).
///
/// Collections that `AppState` keys by session/terminal UUID are flattened to
/// arrays (like `StoreData`) or re-keyed by UUID *string* so they survive JSON.
/// The daemon builds this from its live `AppState`; the client decodes it with
/// the same models and applies it via `AppState.apply(_:)`.
public struct DaemonStateSnapshot: Codable, Sendable {
    public var sessions: [Session]
    public var terminals: [SessionTerminal]
    public var worktrees: [SessionWorktree]
    public var links: [SessionLink]
    public var hookStates: [String: PersistedHookState]
    public var terminalReadiness: [String: TerminalReadiness]
    public var prStatus: [String: PRStatus]
    public var reviewRequests: [ReviewRequest]
    public var assignedIssues: [AssignedIssue]
    public var allowEntries: [AllowEntry]
    public var remoteControlActiveTerminals: [String]
    public var remoteControlEnabled: Bool
    public var activeTerminalID: [String: String]
    public var config: AppConfig?

    public init(
        sessions: [Session] = [],
        terminals: [SessionTerminal] = [],
        worktrees: [SessionWorktree] = [],
        links: [SessionLink] = [],
        hookStates: [String: PersistedHookState] = [:],
        terminalReadiness: [String: TerminalReadiness] = [:],
        prStatus: [String: PRStatus] = [:],
        reviewRequests: [ReviewRequest] = [],
        assignedIssues: [AssignedIssue] = [],
        allowEntries: [AllowEntry] = [],
        remoteControlActiveTerminals: [String] = [],
        remoteControlEnabled: Bool = false,
        activeTerminalID: [String: String] = [:],
        config: AppConfig? = nil
    ) {
        self.sessions = sessions
        self.terminals = terminals
        self.worktrees = worktrees
        self.links = links
        self.hookStates = hookStates
        self.terminalReadiness = terminalReadiness
        self.prStatus = prStatus
        self.reviewRequests = reviewRequests
        self.assignedIssues = assignedIssues
        self.allowEntries = allowEntries
        self.remoteControlActiveTerminals = remoteControlActiveTerminals
        self.remoteControlEnabled = remoteControlEnabled
        self.activeTerminalID = activeTerminalID
        self.config = config
    }

    /// Capture the current render state from a live `AppState`.
    @MainActor
    public init(appState: AppState, config: AppConfig? = nil) {
        self.sessions = appState.sessions
        self.terminals = appState.terminals.values.flatMap { $0 }
        self.worktrees = appState.worktrees.values.flatMap { $0 }
        self.links = appState.links.values.flatMap { $0 }
        self.hookStates = Dictionary(
            uniqueKeysWithValues: appState.allHookStateSnapshots().map { ($0.key.uuidString, $0.value) })
        self.terminalReadiness = Dictionary(
            uniqueKeysWithValues: appState.terminalReadiness.map { ($0.key.uuidString, $0.value) })
        self.prStatus = Dictionary(
            uniqueKeysWithValues: appState.prStatus.map { ($0.key.uuidString, $0.value) })
        self.reviewRequests = appState.reviewRequests
        self.assignedIssues = appState.assignedIssues
        self.allowEntries = appState.allowEntries
        self.remoteControlActiveTerminals = appState.remoteControlActiveTerminals.map(\.uuidString)
        self.remoteControlEnabled = appState.remoteControlEnabled
        self.activeTerminalID = Dictionary(
            uniqueKeysWithValues: appState.activeTerminalID.map { ($0.key.uuidString, $0.value.uuidString) })
        self.config = config
    }
}

public extension AppState {
    /// Replace this `AppState`'s render state with a snapshot pushed by `crowd` —
    /// the inverse of `DaemonStateSnapshot(appState:)`. Regroups the snapshot's
    /// flat arrays back into the UUID-keyed maps the UI reads and re-keys the
    /// string-keyed maps to UUIDs. Used by the macOS crowd-client to hydrate its
    /// state on connect and on every `changed` push (ADR 0007; CROW-581, Stage 3/F).
    ///
    /// Applies only render state; config-derived settings are applied separately
    /// by the client (via `get-config`) so credential handling stays in one place.
    @MainActor
    func apply(_ snapshot: DaemonStateSnapshot) {
        sessions = snapshot.sessions
        terminals = Dictionary(grouping: snapshot.terminals, by: \.sessionID)
        worktrees = Dictionary(grouping: snapshot.worktrees, by: \.sessionID)
        links = Dictionary(grouping: snapshot.links, by: \.sessionID)
        terminalReadiness = Dictionary(uniqueKeysWithValues:
            snapshot.terminalReadiness.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        prStatus = Dictionary(uniqueKeysWithValues:
            snapshot.prStatus.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        reviewRequests = snapshot.reviewRequests
        assignedIssues = snapshot.assignedIssues
        allowEntries = snapshot.allowEntries
        remoteControlActiveTerminals = Set(snapshot.remoteControlActiveTerminals.compactMap { UUID(uuidString: $0) })
        remoteControlEnabled = snapshot.remoteControlEnabled
        activeTerminalID = Dictionary(uniqueKeysWithValues:
            snapshot.activeTerminalID.compactMap { key, value in
                guard let sid = UUID(uuidString: key), let tid = UUID(uuidString: value) else { return nil }
                return (sid, tid)
            })
        for (key, hookSnapshot) in snapshot.hookStates {
            if let sid = UUID(uuidString: key) { restoreHookState(hookSnapshot, for: sid) }
        }
    }
}
