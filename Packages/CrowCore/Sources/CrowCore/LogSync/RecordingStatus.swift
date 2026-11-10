import Foundation

/// The two per-session "is this being recorded by Corveil?" indicators shown
/// on every sidebar row while debug mode is on (CROW-1423).
///
/// Pure: every input is a value the caller already has (the session, config,
/// a ledger snapshot, the collector's skip notes, a clock). No disk, no
/// `op read`, no actor hop, so the rules are unit-tested directly and a read
/// RPC can call it on every poll.
///
/// ⚠️ REDACTION. The output rides `list-sessions`, which remote `/rpc` peers
/// read. It may carry a gateway **base URL** and fixed explanatory text only —
/// never a header name or value from config.
public enum RecordingStatus {

    // MARK: - Gateway

    public enum GatewayState: String, Sendable, Equatable, CaseIterable {
        /// Proven: the gateway's request log holds this session's
        /// conversations, under the expected org/key.
        case verified
        /// Proven wrong: requests were seen, but under a different org or key
        /// than the session's resolved gateway.
        case mismatch
        /// Launched through a gateway and active, but its expected org's log
        /// shows no request from it.
        case silent
        /// Launched through the gateway that is configured now.
        case routed
        /// Launched with something other than what is configured now: a
        /// relaunch would change it.
        case drift
        /// A gateway is configured, but no launch has been recorded (the agent
        /// started before Crow recorded launches).
        case unverified
        /// Launched with the gateway explicitly cleared: vendor direct.
        case direct
        /// No gateway configured, and no launch recorded through one.
        case off
        /// A harness Crow has no gateway route for (Cursor, OpenCode, …).
        case unsupported
    }

    public struct GatewayIndicator: Sendable, Equatable {
        public var state: GatewayState
        /// The launched base URL when there is one, else the configured one.
        public var baseURL: String?
        public var detail: String
    }

    /// Compare what the agent was launched with against what a launch would
    /// get now.
    ///
    /// - Parameters:
    ///   - launched: ``Session/launchedGateway``.
    ///   - configuredBaseURL: the gateway a launch of this session's harness
    ///     would use now (nil when none applies).
    ///   - harnessRoutable: whether Crow can route this harness through a
    ///     gateway at all (Claude always; Codex when its gateway opted in).
    ///   - agentName: display name for the text.
    public static func gateway(
        launched: LaunchedGateway?, configuredBaseURL: String?,
        harnessRoutable: Bool, agentName: String,
        traffic: GatewayTraffic.Evidence? = nil
    ) -> GatewayIndicator {
        var base = launchGateway(launched: launched, configuredBaseURL: configuredBaseURL,
                                 harnessRoutable: harnessRoutable, agentName: agentName)
        guard let traffic else { return base }
        switch traffic.state {
        case .verified:
            base.state = .verified
            base.detail = traffic.detail + "\n" + base.detail
        case .mismatch:
            base.state = .mismatch
            base.detail = traffic.detail + "\n" + base.detail
        case .silent:
            base.state = .silent
            base.detail = traffic.detail + "\n" + base.detail
        case .unavailable, .none:
            if !traffic.detail.isEmpty { base.detail += "\n" + traffic.detail }
        }
        return base
    }

    /// The launch-vs-config half of ``gateway(launched:configuredBaseURL:harnessRoutable:agentName:traffic:)``.
    static func launchGateway(
        launched: LaunchedGateway?, configuredBaseURL: String?,
        harnessRoutable: Bool, agentName: String
    ) -> GatewayIndicator {
        let configured = configuredBaseURL.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if let launched {
            switch launched.via {
            case .launchLine, .codexOverride, .settingsEnv:
                let url = launched.baseURL ?? "?"
                guard let configured else {
                    return GatewayIndicator(
                        state: .drift, baseURL: url,
                        detail: "Launched through \(url), but no gateway is configured now. A relaunch would go to the vendor directly.")
                }
                if sameGateway(url, configured) {
                    return GatewayIndicator(state: .routed, baseURL: url, detail: "Launched through \(url)")
                }
                return GatewayIndicator(
                    state: .drift, baseURL: url,
                    detail: "Launched through \(url); the config now says \(configured). Relaunch to apply.")
            case .none:
                if let configured {
                    return GatewayIndicator(
                        state: .drift, baseURL: configured,
                        detail: "Launched without a gateway; \(configured) is configured now. Relaunch to route through it.")
                }
                return GatewayIndicator(state: .direct, baseURL: nil,
                                        detail: "Launched without a gateway (vendor direct)")
            case .unknown:
                break
            }
        }
        guard harnessRoutable else {
            return GatewayIndicator(state: .unsupported, baseURL: nil,
                                    detail: "\(agentName) isn't routed through a Crow gateway")
        }
        if let configured {
            return GatewayIndicator(
                state: .unverified, baseURL: configured,
                detail: "Configured: \(configured). This agent's launch wasn't recorded (it started before Crow recorded launches), so it may not be using it.")
        }
        return GatewayIndicator(state: .off, baseURL: nil, detail: "No gateway configured")
    }

    /// Two base URLs name the same gateway: case, a trailing slash and Codex's
    /// required `/v1` suffix (CROW-1407) are not differences.
    public static func sameGateway(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces).lowercased()
            while v.hasSuffix("/") { v.removeLast() }
            if v.hasSuffix("/v1") { v.removeLast(3) }
            while v.hasSuffix("/") { v.removeLast() }
            return v
        }
        return norm(a) == norm(b)
    }

    // MARK: - Transcripts

    public enum TranscriptState: String, Sendable, Equatable, CaseIterable {
        case uploaded
        /// Opted in, nothing shipped yet: inside the quiet period, still
        /// active, or a Manager conversation not yet idle.
        case waiting
        /// `failedTransient`: re-attempted after a backoff.
        case retrying
        /// `skippedPermanent`: never re-attempted.
        case rejected
        /// The configuration says this session never uploads.
        case notOptedIn = "not_opted_in"
        /// Opted in, but the collector skipped it (no transcript on disk, no
        /// worktree, …). The reason is in `detail`.
        case skipped
    }

    public struct TranscriptIndicator: Sendable, Equatable {
        public var state: TranscriptState
        public var detail: String
        /// Managers only: conversations uploaded / known.
        public var uploaded: Int?
        public var total: Int?
    }

    /// Gateway header names that may carry the Corveil key, in preference
    /// order. Shared with `LogSyncCollector.corveilKeyHeaderNames`.
    public static let corveilKeyHeaderNames = ["x-citadel-api-key", "authorization", "x-api-key", "x-corveil-key"]

    /// Whether a gateway carries a Corveil key header with a non-blank value.
    /// Presence only: an `op://` reference is not resolved here (a read path
    /// must never shell out), so an unresolvable reference still reads as
    /// "has one".
    public static func hasCorveilKey(_ gateway: WorkspaceGateway?) -> Bool {
        guard let gateway, !gateway.isEmpty,
              !gateway.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        return gateway.customHeaders.contains { name, value in
            corveilKeyHeaderNames.contains(name.lowercased())
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Every conversation a Manager has run, oldest first: its recorded
    /// history plus the current id when the history predates it (CROW-1382).
    /// The collector uploads one artifact per entry.
    public static func managerConversations(_ session: Session) -> [HarnessConversationRef] {
        var refs = session.harnessConversationHistory
        if let current = session.harnessConversationID,
           !refs.contains(where: { $0.id == current }) {
            refs.append(HarnessConversationRef(agentKind: session.agentKind, id: current))
        }
        return refs
    }

    /// `{devRoot}/{workspace}/…` → `workspace`; nil outside the dev root.
    public static func workspaceFolder(forWorktreePath path: String, devRoot: String) -> String? {
        let root = (devRoot as NSString).standardizingPath
        let full = (path as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { return nil }
        return full.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
    }

    /// The transcript indicator, mirroring `LogSyncCollector`'s rules:
    /// the primary and untagged Managers never upload; a work, review or job
    /// session uploads under the workspace its **worktree path** names; the
    /// workspace must tick `uploadSessionLogs` and carry a gateway with a
    /// Corveil key; a Manager ships one artifact per harness conversation.
    public static func transcripts(
        session: Session, worktreePath: String?, devRoot: String?, config: AppConfig?,
        ledger: LogSyncLedger, skipNotes: [LogSyncSkipNote], now: Date
    ) -> TranscriptIndicator {
        transcripts(session: session, worktreePath: worktreePath, devRoot: devRoot, config: config,
                    ledger: LedgerIndex(ledger), skipNotes: skipNotes, now: now)
    }

    /// The same, against a ledger indexed once per read (`list-sessions`
    /// builds one ``LedgerIndex`` for all its rows rather than scanning the
    /// ledger per row).
    public static func transcripts(
        session: Session, worktreePath: String?, devRoot: String?, config: AppConfig?,
        ledger: LedgerIndex, skipNotes: [LogSyncSkipNote], now: Date
    ) -> TranscriptIndicator {
        func notOptedIn(_ why: String) -> TranscriptIndicator {
            TranscriptIndicator(state: .notOptedIn, detail: "Not opted in: \(why)")
        }
        func skipped(_ why: String) -> TranscriptIndicator {
            TranscriptIndicator(state: .skipped, detail: "Not uploading: \(why)")
        }

        if session.id == AppState.managerSessionID {
            return notOptedIn("the primary Manager never uploads transcripts, by design")
        }
        guard let config else { return notOptedIn("config.json is unreadable") }

        let workspace: WorkspaceInfo
        if session.isManager {
            guard let tag = session.managerWorkspaceTag else {
                return notOptedIn("untagged Manager (created before Managers needed a workspace)")
            }
            guard let ws = config.workspaces.first(where: { $0.id == tag }) else {
                return notOptedIn("this Manager's workspace was removed")
            }
            workspace = ws
        } else {
            guard let worktreePath else { return skipped("the session has no worktree") }
            guard let devRoot, let folder = workspaceFolder(forWorktreePath: worktreePath, devRoot: devRoot) else {
                return skipped("the worktree is outside the dev root")
            }
            guard let ws = config.workspaces.first(where: { $0.name.lowercased() == folder.lowercased() }) else {
                if folder == "crow-reviews" {
                    return notOptedIn("review clones live under crow-reviews/, which the collector doesn't map to a workspace")
                }
                return notOptedIn("\(folder)/ isn't a configured workspace")
            }
            workspace = ws
        }
        guard workspace.uploadSessionLogs else {
            return notOptedIn("workspace \(workspace.name) has transcript upload off")
        }
        guard hasCorveilKey(workspace.gateway) else {
            return notOptedIn("workspace \(workspace.name) has no gateway with a Corveil API key")
        }

        let quiet = max(0, (config.logSync ?? LogSyncConfig()).quietPeriodMinutes)
        if session.isManager {
            return managerTranscripts(
                session: session, ledger: ledger, skipNotes: skipNotes, quietMinutes: quiet, now: now)
        }
        return workTranscripts(
            session: session, ledger: ledger, skipNotes: skipNotes, quietMinutes: quiet, now: now)
    }

    private static let kindSuffix = ":" + LogSyncArtifactKind.sessionTranscript.rawValue

    /// The ledger's session-transcript entries grouped by upload uid (a
    /// session id, or a Manager conversation id). Keys are
    /// `{uid}:{harness}:{kind}` (`LogSyncLedger.key`); the uid never contains
    /// a colon, so it is everything before the first one.
    public struct LedgerIndex: Sendable {
        public struct Slot: Sendable {
            public var harness: String
            public var entry: LogSyncLedger.Entry
        }
        var byUID: [String: [Slot]]

        public init(_ ledger: LogSyncLedger) {
            var byUID: [String: [Slot]] = [:]
            for (key, entry) in ledger.entries where key.hasSuffix(RecordingStatus.kindSuffix) {
                guard let colon = key.firstIndex(of: ":") else { continue }
                let uid = String(key[..<colon])
                let rest = key[key.index(after: colon)...].dropLast(RecordingStatus.kindSuffix.count)
                byUID[uid, default: []].append(Slot(harness: String(rest), entry: entry))
            }
            self.byUID = byUID.mapValues { $0.sorted { $0.harness < $1.harness } }
        }

        /// Entries for one uid (any harness), sorted by harness.
        public func entries(uid: String) -> [(harness: String, entry: LogSyncLedger.Entry)] {
            (byUID[uid] ?? []).map { ($0.harness, $0.entry) }
        }
    }

    private static func workTranscripts(
        session: Session, ledger: LedgerIndex, skipNotes: [LogSyncSkipNote],
        quietMinutes: Int, now: Date
    ) -> TranscriptIndicator {
        let found = ledger.entries(uid: session.id.uuidString)
        let terminal = session.status == .completed || session.status == .archived
        let uploaded = found.filter { $0.entry.status == .uploaded }
        if !uploaded.isEmpty {
            var lines = uploaded.map {
                "Uploaded \($0.harness) transcript \(ago($0.entry.at, now)) (\(bytes($0.entry.sizeBytes)) gzipped)"
            }
            for other in found where other.entry.status != .uploaded {
                lines.append("\(other.harness): \(describe(other.entry, now))")
            }
            if !terminal {
                lines.append("Uploaded while the session was still open. Uploads are write-once, so anything after that isn't in Corveil.")
            }
            return TranscriptIndicator(state: .uploaded, detail: lines.joined(separator: "\n"))
        }
        if let transient = found.first(where: { $0.entry.status == .failedTransient }) {
            return TranscriptIndicator(
                state: .retrying,
                detail: "\(transient.harness): \(describe(transient.entry, now)). Retried after 30 min.")
        }
        if let rejected = found.first(where: { $0.entry.status == .skippedPermanent }) {
            return TranscriptIndicator(
                state: .rejected,
                detail: "\(rejected.harness): \(describe(rejected.entry, now)). Not retried.")
        }
        if !skipNotes.isEmpty {
            return TranscriptIndicator(
                state: .skipped,
                detail: "Not uploading: " + skipNotes.map(\.detail).joined(separator: "; "))
        }
        let waiting = terminal
            ? "Waiting: \(session.status.rawValue); uploads on the next collector pass (every 5 min)"
            : "Waiting: uploads once the transcript has been idle \(quietMinutes) min, or when the session completes"
        return TranscriptIndicator(state: .waiting, detail: waiting)
    }

    private static func managerTranscripts(
        session: Session, ledger: LedgerIndex, skipNotes: [LogSyncSkipNote],
        quietMinutes: Int, now: Date
    ) -> TranscriptIndicator {
        // A note with no `scope` is about the whole Manager (no agent terminal,
        // its workspace gone, an unresolvable gateway key): the collector
        // stopped before looking at any conversation, so nothing pending can
        // upload. A scoped note is about one conversation (no transcript file).
        // Either is a skip, shown as one, exactly like a work session's.
        let unscoped = skipNotes.filter { $0.scope == nil }
        let managerWide = unscoped.isEmpty ? nil : "Not uploading: " + unscoped.map(\.detail).joined(separator: "; ")
        let conversations = managerConversations(session)
        guard !conversations.isEmpty else {
            if let managerWide {
                return TranscriptIndicator(state: .skipped, detail: managerWide, uploaded: 0, total: 0)
            }
            return TranscriptIndicator(
                state: .waiting, detail: "Waiting: no harness conversation recorded yet",
                uploaded: 0, total: 0)
        }
        var uploaded = 0, retrying = 0, rejected = 0, skipped = 0, pending = 0
        var lines: [String] = []
        for ref in conversations {
            let short = String(ref.id.prefix(8))
            let found = ledger.entries(uid: ref.id)
            if found.contains(where: { $0.entry.status == .uploaded }) {
                uploaded += 1
            } else if let t = found.first(where: { $0.entry.status == .failedTransient }) {
                retrying += 1
                lines.append("\(short): \(describe(t.entry, now))")
            } else if let r = found.first(where: { $0.entry.status == .skippedPermanent }) {
                rejected += 1
                lines.append("\(short): \(describe(r.entry, now))")
            } else if let note = skipNotes.first(where: { $0.scope == ref.id }) {
                skipped += 1
                lines.append("\(short): \(note.detail)")
            } else if managerWide != nil {
                skipped += 1
            } else {
                pending += 1
                lines.append("\(short): waiting for \(quietMinutes) min idle")
            }
        }
        let total = conversations.count
        let state: TranscriptState
        if uploaded == total { state = .uploaded }
        else if retrying > 0 { state = .retrying }
        else if skipped > 0 { state = .skipped }
        else if pending > 0 { state = .waiting }
        else { state = .rejected }
        let head = "\(uploaded) of \(total) conversation\(total == 1 ? "" : "s") uploaded"
        let body = (managerWide.map { [$0] } ?? []) + lines
        return TranscriptIndicator(
            state: state, detail: ([head] + body).joined(separator: "\n"),
            uploaded: uploaded, total: total)
    }

    private static func describe(_ entry: LogSyncLedger.Entry, _ now: Date) -> String {
        let why = entry.reason.map { " (\($0))" } ?? ""
        switch entry.status {
        case .uploaded: return "uploaded \(ago(entry.at, now))"
        case .failedTransient: return "upload failed\(why) \(ago(entry.at, now))"
        case .skippedPermanent: return "rejected\(why) \(ago(entry.at, now))"
        }
    }

    static func ago(_ epoch: Double, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince1970 - epoch))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}
