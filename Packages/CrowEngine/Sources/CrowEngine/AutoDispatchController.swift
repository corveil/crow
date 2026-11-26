import CrowCore
import Foundation

/// Where a `crow:auto` / `crow:explore` dispatch goes (CROW-1501). Pure.
///
/// The primary Manager only grows: every dispatch appends a `/crow-workspace`
/// run to it, and `crow:auto` labels arrive hours apart, so most dispatches
/// found it cold and very large and paid a full cache rebuild. That was the
/// largest automated share of idle rebuilds in the #1501 measurement. A
/// dispatch needs none of the primary's history, because `/crow-workspace`
/// brings everything it needs, so a cold, large primary is skipped. Routing,
/// not cache-warming: nothing here sends anything to keep a cache alive.
public enum AutoDispatchRouting {
    public enum Target: Equatable, Sendable {
        /// The primary Manager, as before.
        case primary
        /// The extra Manager an earlier cold dispatch created, still usable.
        case spare(UUID)
        /// A new extra Manager, launched with the dispatch as its first prompt.
        case fresh
    }

    /// The newest extra Manager this router created.
    public struct Spare: Equatable, Sendable {
        public var id: UUID
        public var warmth: SessionContextReport.Warmth?
        public var agentState: AgentReadinessState?

        public init(id: UUID, warmth: SessionContextReport.Warmth?, agentState: AgentReadinessState?) {
            self.id = id
            self.warmth = warmth
            self.agentState = agentState
        }
    }

    /// - The primary is used unless its context is known to be both large and
    ///   cold. Unknown (no transcript, a harness without one) keeps today's
    ///   behaviour.
    /// - Otherwise the spare, if it can take a paste now (idle, or working:
    ///   the agent queues it) and is not itself cold and large. A cold small
    ///   spare is reused, so a new Manager is started only every several
    ///   dispatches, not on each one.
    /// - Otherwise a fresh Manager.
    public static func target(primary: SessionContextReport.Warmth?, spare: Spare?) -> Target {
        guard primary?.coldAndLarge == true else { return .primary }
        if let spare, spare.agentState == .idle || spare.agentState == .working,
           spare.warmth?.coldAndLarge != true {
            return .spare(spare.id)
        }
        return .fresh
    }
}

/// Sends `crow:auto` dispatches where ``AutoDispatchRouting`` says (CROW-1501).
///
/// The tracker calls ``enqueue(_:)`` once per labeled issue, synchronously, in
/// one sweep. Requests are drained on the next MainActor turn, so a burst is
/// routed together: one transcript read, and at most one fresh Manager per
/// kind (`/crow-batch-workspace` for several issues). Transcripts are read off
/// the MainActor (#892).
@MainActor
public final class AutoDispatchController {
    public struct Request: Equatable, Sendable {
        public var url: String
        /// `owner/repo`, to tag a fresh Manager when no default workspace is set.
        public var repo: String
        /// For the notification.
        public var number: Int
        public var title: String
        public var explore: Bool

        public init(url: String, repo: String, number: Int = 0, title: String = "", explore: Bool) {
            self.url = url
            self.repo = repo
            self.number = number
            self.title = title
            self.explore = explore
        }
    }

    /// What one drain did, for the log and for tests.
    public struct Dispatch: Equatable, Sendable {
        public var requests: [Request]
        public var target: AutoDispatchRouting.Target
        /// The session the lines went to; nil when dropped.
        public var sessionID: UUID?
    }

    public struct IO {
        public var send: @MainActor (SessionTerminal, String) -> Void
        public var paneCommands: @MainActor () -> [UUID: String]?
        /// Create an extra Manager seeded with `prompt` as its first message.
        public var createManager: @MainActor (_ name: String, _ prompt: String, _ workspaceID: UUID) -> UUID

        public init(
            send: @escaping @MainActor (SessionTerminal, String) -> Void,
            paneCommands: @escaping @MainActor () -> [UUID: String]?,
            createManager: @escaping @MainActor (String, String, UUID) -> UUID
        ) {
            self.send = send
            self.paneCommands = paneCommands
            self.createManager = createManager
        }
    }

    /// Extra Managers this router creates are named `auto-dispatch`,
    /// `auto-dispatch 2`, …; the newest one is the spare. Found by name, so it
    /// survives a `crowd` restart.
    public nonisolated static let spareName = "auto-dispatch"

    private let appState: AppState
    private let configProvider: () -> AppConfig?
    private let launchCommand: ([String], Bool) -> String
    private let io: IO
    private let snapshotProvider: @Sendable ([SessionContextReport.Source]) async
        -> [UUID: (ContextSnapshot, SessionContextReport.Located)]
    private let now: () -> Date
    private let onRouted: @MainActor (Dispatch) -> Void
    private var pending: [Request] = []
    private var draining = false
    /// Resumed when a drain finishes; see ``waitUntilDrained()``.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        appState: AppState,
        configProvider: @escaping () -> AppConfig?,
        launchCommand: @escaping ([String], Bool) -> String,
        io: IO,
        snapshotProvider: (@Sendable ([SessionContextReport.Source]) async
            -> [UUID: (ContextSnapshot, SessionContextReport.Located)])? = nil,
        now: @escaping () -> Date = Date.init,
        onRouted: @escaping @MainActor (Dispatch) -> Void = { _ in }
    ) {
        self.appState = appState
        self.configProvider = configProvider
        self.launchCommand = launchCommand
        self.io = io
        self.snapshotProvider = snapshotProvider ?? { sources in
            await Task.detached { SessionContextReport.snapshots(for: sources) }.value
        }
        self.now = now
        self.onRouted = onRouted
    }

    public func enqueue(_ request: Request) {
        pending.append(request)
        guard !draining else { return }
        draining = true
        Task { @MainActor [weak self] in await self?.drain() }
    }

    /// Wait until every enqueued request has been routed. Tests only.
    func waitUntilDrained() async {
        guard draining else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func drain() async {
        while !pending.isEmpty {
            let batch = pending
            pending = []
            for dispatch in await route(batch) {
                onRouted(dispatch)
            }
        }
        draining = false
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Route one batch. Internal for tests.
    ///
    /// Each request is tagged with its own workspace (``workspace(for:config:)``),
    /// and a cold primary's dispatches stay inside that workspace: one spare or
    /// fresh Manager per workspace, never one workspace's Manager for another's
    /// issue. A tagged Manager uses its workspace's gateway and log sync, so
    /// crossing workspaces would send one tenant's work through another's.
    func route(_ batch: [Request]) async -> [Dispatch] {
        let config = configProvider()
        let threshold = (config?.contextCompaction ?? ContextCompactionSettings()).effectiveMinContextTokens
        let primarySession = appState.sessions.first { $0.id == AppState.managerSessionID }

        // Group by workspace, in arrival order. A nil key: none resolves.
        var groups: [(workspaceID: UUID?, requests: [Request])] = []
        for request in batch {
            let id = config.flatMap { workspace(for: request, config: $0) }
            if let i = groups.firstIndex(where: { $0.workspaceID == id }) {
                groups[i].requests.append(request)
            } else {
                groups.append((id, [request]))
            }
        }
        var spares: [UUID: Session] = [:]
        for case let id? in groups.map(\.workspaceID) { spares[id] = currentSpare(workspaceID: id) }

        let sources = ([primarySession] + spares.values.map { Optional($0) }).compactMap { session in
            session.flatMap { SessionContextReport.source(for: $0, appState: appState) }
        }
        let snapshots = sources.isEmpty ? [:] : await snapshotProvider(sources)
        let at = now()
        func warmth(_ id: UUID?) -> SessionContextReport.Warmth? {
            id.flatMap { snapshots[$0] }.flatMap {
                SessionContextReport.warmth($0.0, largeThreshold: threshold, now: at)
            }
        }

        let primaryWarmth = warmth(primarySession?.id)
        guard primaryWarmth?.coldAndLarge == true else {
            return [sendLines(batch, to: AppState.managerSessionID, target: .primary)]
        }
        let why = snapshots[AppState.managerSessionID].map { snap in
            "tokens \(snap.0.tokens ?? 0), idle \(Int(snap.0.idleSeconds(now: at) ?? 0))s"
        } ?? ""
        let paneCommands = io.paneCommands()

        var out: [Dispatch] = []
        for (workspaceID, requests) in groups {
            guard let workspaceID else {
                CrowLog.automation("crow:auto: primary Manager is cold and large (\(why)) but no workspace resolves for \(requests.map(\.url).joined(separator: " ")); using the primary")
                out.append(sendLines(requests, to: AppState.managerSessionID, target: .primary))
                continue
            }
            let spareSession = spares[workspaceID]
            let spare = spareSession.map { session in
                AutoDispatchRouting.Spare(
                    id: session.id, warmth: warmth(session.id),
                    agentState: AgentReadiness.state(
                        AgentStateReport.inputs(for: session, appState: appState, paneCommands: paneCommands),
                        now: at))
            }
            switch AutoDispatchRouting.target(primary: primaryWarmth, spare: spare) {
            case .primary:
                out.append(sendLines(requests, to: AppState.managerSessionID, target: .primary))
            case .spare(let id):
                CrowLog.automation("crow:auto: primary Manager is cold and large (\(why)); routing \(requests.count) dispatch(es) to \(spareSession?.name ?? id.uuidString)")
                out.append(sendLines(requests, to: id, target: .spare(id)))
            case .fresh:
                for explore in [false, true] {
                    let group = requests.filter { $0.explore == explore }
                    guard !group.isEmpty else { continue }
                    let urls = group.map(\.url)
                    let name = Self.freshName(existing: Set(appState.managerSessions.map(\.name)))
                    let id = io.createManager(name, Self.freshPrompt(launchCommand(urls, explore)), workspaceID)
                    CrowLog.automation("crow:auto: primary Manager is cold and large (\(why)); started \(name) for \(urls.joined(separator: " "))")
                    out.append(Dispatch(requests: group, target: .fresh, sessionID: id))
                }
            }
        }
        return out
    }

    /// Type one launch line per request into `sessionID`'s agent pane, as the
    /// primary always received them.
    private func sendLines(_ batch: [Request], to sessionID: UUID, target: AutoDispatchRouting.Target) -> Dispatch {
        let urls = batch.map(\.url)
        let terminal: SessionTerminal? = sessionID == AppState.managerSessionID
            ? appState.terminals[sessionID]?.first
            : appState.sessions.first { $0.id == sessionID }.flatMap {
                AgentStateReport.agentTerminal(for: $0, appState: appState)
            }
        guard let terminal else {
            for url in urls { CrowLog.automation("crow:auto: Manager terminal not ready; dropped \(url)") }
            return Dispatch(requests: batch, target: target, sessionID: nil)
        }
        for request in batch {
            io.send(terminal, launchCommand([request.url], request.explore))
        }
        return Dispatch(requests: batch, target: target, sessionID: sessionID)
    }

    /// The newest live extra Manager named like ``spareName`` and tagged with
    /// `workspaceID`. A human-made Manager of the same name in that workspace
    /// would be picked too; the name is the only marker, so it survives a
    /// `crowd` restart.
    private func currentSpare(workspaceID: UUID) -> Session? {
        appState.managerSessions
            .filter { $0.id != AppState.managerSessionID && Self.isSpareName($0.name) }
            .filter { $0.managerWorkspaceTag == workspaceID }
            .filter { $0.status != .completed && $0.status != .archived }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The workspace a request's Manager is tagged with, in
    /// ``ManagerWorkspaceTag``'s order: the workspace that claims the issue's
    /// repo (context), else `defaults.managerWorkspace`. Nil when neither
    /// resolves: every extra Manager needs one (CROW-1386).
    private func workspace(for request: Request, config: AppConfig) -> UUID? {
        let claimed = config.workspace(forRepoSlug: request.repo)?.id.uuidString
        return try? ManagerWorkspaceTag.resolve(requested: nil, context: claimed, config: config).workspaceID
    }

    /// A fresh Manager's first prompt. It follows the workspace brief
    /// (``ManagerWorkspaceBrief``), so the slash command is not at the start
    /// of the message and the harness won't expand it. The agent is told to
    /// run it instead.
    nonisolated static func freshPrompt(_ command: String) -> String {
        "Crow started this Manager for a `crow:auto` dispatch, because the primary Manager's context is large "
            + "and its prompt cache had expired. Run this skill command now, exactly as if the operator had typed it, "
            + "then wait:\n\n" + command.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    nonisolated static func isSpareName(_ name: String) -> Bool {
        if name == spareName { return true }
        let prefix = spareName + " "
        guard name.hasPrefix(prefix), let n = Int(name.dropFirst(prefix.count)) else { return false }
        return n >= 2
    }

    /// The first of `auto-dispatch`, `auto-dispatch 2`, … not in use.
    nonisolated static func freshName(existing: Set<String>) -> String {
        guard existing.contains(spareName) else { return spareName }
        var n = 2
        while existing.contains("\(spareName) \(n)") { n += 1 }
        return "\(spareName) \(n)"
    }
}
