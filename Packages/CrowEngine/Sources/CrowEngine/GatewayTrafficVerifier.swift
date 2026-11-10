import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLSession live here on Linux
#endif
import CrowCore
import CrowPersistence

/// Proves gateway traffic per session from Corveil's request log (CROW-1423,
/// the debug-mode recording indicator). Deterministic, no LLM. Driven by
/// ``GatewayTrafficPoller``, at most once per 5 minutes and only while debug
/// mode is on.
///
/// One pass:
///
/// 1. **Read** each Corveil-connection org's request log (`GET /api/logs`) with
///    that org's own stored `sk-citadel` key, newest first, paged by
///    `next_cursor` (500 a page), bounded by `maxPages` and `maxAge`.
///
///    *Can a stored org key read it?* Yes, by Corveil's own rules: a key minted
///    through `POST /api/keys` (`crow corveil select-org`) is an ordinary user
///    API key, `/api/*` admits API keys, and `GET /api/logs` needs only
///    `logs.read.own`, which every org role holds. An org admin's key sees the
///    whole org's log; a member's sees their own requests, which are all
///    Crow's sessions send. The connection's OAuth token is **not** an option:
///    Corveil refuses OAuth bearers on `/api/*` outside a short allowlist
///    (`/api/me/organizations`, the key-provisioning routes), and `/api/logs`
///    isn't on it. So no scope is widened anywhere.
///
///    A key that is refused anyway (401/403: revoked, or a role change) is
///    recorded as such, and the operator's `corveil` CLI login is tried
///    instead (`corveil control observability logs-list`), which sees
///    whichever org it is logged into. The CLI is also the only reader for a
///    gateway the connection doesn't manage.
/// 2. **Index** `conversation id → {count, lastAt, apiKeyId, orgId}` across
///    every org read (``GatewayTraffic/index(entries:readOrgs:)``).
/// 3. **Match** each Claude Code session's conversations — Managers by
///    `managerConversations`, everything else by the transcript files in the
///    worktree's `~/.claude/projects/<slug>` folder — against the org/key its
///    resolved gateway belongs to (``GatewayTraffic/evidence``).
///
/// Key values are used only as the `Authorization` header of the read; they
/// are never logged, stored, or returned.
public struct GatewayTrafficVerifier: Sendable {
    /// One session as the verifier needs it, captured on the main actor.
    public struct SessionInput: Sendable {
        public var session: Session
        public var worktreePath: String?
        public var prLinks: [SessionLink]
        /// A Manager's agent-pane cwd (where its Claude project folder is keyed).
        public var managerCwd: String?

        public init(session: Session, worktreePath: String?, prLinks: [SessionLink], managerCwd: String?) {
            self.session = session
            self.worktreePath = worktreePath
            self.prLinks = prLinks
            self.managerCwd = managerCwd
        }
    }

    public enum FetchResult: Sendable {
        case page(GatewayTraffic.Page)
        /// HTTP 401/403: this credential can't read the log.
        case denied(Int)
        case failed(String)
    }

    /// `GET {url}` with `Authorization: Bearer {key}` → (status, body).
    public typealias HTTPGet = @Sendable (URL, String) async -> (status: Int, body: Data)?
    /// `corveil control observability logs-list --limit 500 [--cursor c]` → stdout.
    public typealias CLIList = @Sendable (String, String?) async -> Data?

    let http: HTTPGet
    let cli: CLIList
    let corveilBinary: @Sendable (AppConfig) -> String?
    let home: String
    let now: @Sendable () -> Date
    let maxPages: Int
    let maxAge: TimeInterval
    /// Whether to read with the connection's org keys. Always true in
    /// `crowd`; a test sets it false to exercise the CLI path alone.
    let useOrgKeys: Bool

    public init(
        http: @escaping HTTPGet = GatewayTrafficVerifier.urlSessionGet,
        cli: @escaping CLIList = GatewayTrafficVerifier.runCorveilCLI,
        corveilBinary: @escaping @Sendable (AppConfig) -> String? = GatewayTrafficVerifier.findCorveil,
        home: String = NSHomeDirectory(),
        now: @escaping @Sendable () -> Date = { Date() },
        maxPages: Int = 6,
        maxAge: TimeInterval = 24 * 3600,
        useOrgKeys: Bool = true
    ) {
        self.http = http
        self.cli = cli
        self.corveilBinary = corveilBinary
        self.home = home
        self.now = now
        self.maxPages = maxPages
        self.maxAge = maxAge
        self.useOrgKeys = useOrgKeys
    }

    // MARK: - Pass

    /// Read, index and match. Returns per-session evidence plus one status
    /// line per log source tried.
    public func run(inputs: [SessionInput], config: AppConfig, devRoot: String?) async
        -> (evidence: [UUID: GatewayTraffic.Evidence], sources: [GatewayTrafficBoard.SourceStatus]) {
        let claudeInputs = inputs.filter { $0.session.agentKind == .claudeCode }
        guard !claudeInputs.isEmpty else { return ([:], []) }

        let at = now()
        let oldestWanted = at.addingTimeInterval(-maxAge)
        var entries: [GatewayTraffic.Entry] = []
        var readOrgs = Set<String>()
        var sources: [GatewayTrafficBoard.SourceStatus] = []
        var unreadable: [String] = []

        // 1. Each connection org, with its own key.
        let connection = config.corveilConnection
        if useOrgKeys, let connection, !connection.isEmpty {
            for org in connection.orgKeys {
                guard let secret = connection.orgKeySecrets[org.orgID]?.trimmingCharacters(in: .whitespaces),
                      !secret.isEmpty else { continue }
                let base = connection.baseURL
                let outcome = await readPages(oldestWanted: oldestWanted) { cursor in
                    guard let url = Self.logsURL(base: base, cursor: cursor) else { return .failed("bad base URL") }
                    guard let (status, body) = await http(url, secret) else { return .failed("no response") }
                    if status == 401 || status == 403 { return .denied(status) }
                    guard (200..<300).contains(status) else { return .failed("HTTP \(status)") }
                    return GatewayTraffic.decodePage(body).map { .page($0) } ?? .failed("unreadable body")
                }
                let label = "\(org.orgName) key (\(org.keyPrefix)…)"
                switch outcome {
                case .read(let got):
                    entries += got
                    readOrgs.insert(org.orgID)
                    sources.append(.init(label: label, readable: true, note: "\(got.count) requests"))
                case .denied(let status):
                    unreadable.append(org.orgName)
                    sources.append(.init(label: label, readable: false, note: "HTTP \(status): the gateway key can't read request logs"))
                case .failed(let why):
                    unreadable.append(org.orgName)
                    sources.append(.init(label: label, readable: false, note: why))
                }
            }
        }

        // 2. Fallback: the operator's `corveil` CLI login, when a key couldn't
        // read its org (or there are no connection keys to try).
        if !unreadable.isEmpty || readOrgs.isEmpty, let binary = corveilBinary(config) {
            let outcome = await readPages(oldestWanted: oldestWanted) { cursor in
                guard let data = await cli(binary, cursor) else { return .failed("corveil CLI failed (not logged in?)") }
                return GatewayTraffic.decodePage(data).map { .page($0) } ?? .failed("corveil CLI output unreadable")
            }
            switch outcome {
            case .read(let got):
                entries += got
                let orgs = Set(got.compactMap(\.organizationID))
                readOrgs.formUnion(orgs)
                sources.append(.init(label: "corveil CLI login", readable: true,
                                     note: "\(got.count) requests from \(orgs.count) org(s)"))
            case .denied(let status):
                sources.append(.init(label: "corveil CLI login", readable: false, note: "HTTP \(status)"))
            case .failed(let why):
                sources.append(.init(label: "corveil CLI login", readable: false, note: why))
            }
        }

        let index = GatewayTraffic.index(entries: entries, readOrgs: readOrgs)
        var names: [String: String] = [:]
        for org in connection?.orgKeys ?? [] { names[org.orgID] = org.orgName }

        var evidence: [UUID: GatewayTraffic.Evidence] = [:]
        for input in claudeInputs {
            evidence[input.session.id] = GatewayTraffic.evidence(
                conversations: conversations(for: input),
                index: index,
                expected: Self.expected(for: input, config: config, devRoot: devRoot),
                throughGateway: Self.throughGateway(input, config: config, devRoot: devRoot),
                orgNames: names, now: at)
        }
        return (evidence, sources)
    }

    // MARK: - Paging

    enum ReadOutcome { case read([GatewayTraffic.Entry]), denied(Int), failed(String) }

    /// Page newest-first until the window is covered, the budget is spent, or
    /// there is no cursor. A refusal on the first page is a refusal; a failure
    /// after some pages keeps what was read.
    func readPages(oldestWanted: Date, fetch: (String?) async -> FetchResult) async -> ReadOutcome {
        var all: [GatewayTraffic.Entry] = []
        var cursor: String?
        var pages = 0
        while true {
            switch await fetch(cursor) {
            case .denied(let status):
                return pages == 0 ? .denied(status) : .read(all)
            case .failed(let why):
                return pages == 0 ? .failed(why) : .read(all)
            case .page(let page):
                pages += 1
                all += page.entries.filter { $0.createdAt >= oldestWanted }
                guard GatewayTraffic.shouldFetchNext(
                    after: page, pagesRead: pages, maxPages: maxPages, oldestWanted: oldestWanted)
                else { return .read(all) }
                cursor = page.nextCursor
            }
        }
    }

    static func logsURL(base: String, cursor: String?) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var comps = URLComponents(string: trimmed + "/api/logs") else { return nil }
        comps.queryItems = [URLQueryItem(name: "limit", value: String(GatewayTraffic.pageSize))]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        // URLComponents leaves `+` alone in a query, which a server reads as a
        // space; a base64 cursor can contain one.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    // MARK: - Per session

    /// The session's Claude Code conversations with their transcript mtimes.
    func conversations(for input: SessionInput) -> [GatewayTraffic.Conversation] {
        let s = input.session
        if s.isManager {
            let cwd = input.managerCwd
            return RecordingStatus.managerConversations(s)
                .filter { $0.agentKind == .claudeCode }
                .map { ref in
                    let mtime = cwd.flatMap { Self.mtime(projectDir(cwd: $0).appendingPathComponent("\(ref.id).jsonl")) }
                    return GatewayTraffic.Conversation(id: ref.id, lastWrite: mtime)
                }
        }
        // A work, review or job session owns every Claude transcript in its
        // worktree's project folder: the same set `LogSyncCollector` uploads
        // for it, and the only record that covers `/clear`, resumes and
        // relaunches (`harnessConversationID` holds just the latest). Worktree
        // paths are unique per session, but a path can be reused after a
        // delete, so a transcript that last changed before this session
        // existed is a previous tenant's and is left out.
        guard let wt = input.worktreePath else { return [] }
        let dir = projectDir(cwd: wt)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Self.ownConversations(files.filter { $0.pathExtension == "jsonl" }.map {
            GatewayTraffic.Conversation(id: $0.deletingPathExtension().lastPathComponent, lastWrite: Self.mtime($0))
        }, sessionCreatedAt: s.createdAt)
    }

    /// Drop transcripts whose last write predates the session (a previous
    /// tenant of a reused worktree path). One with no readable mtime is kept.
    static func ownConversations(
        _ conversations: [GatewayTraffic.Conversation], sessionCreatedAt: Date
    ) -> [GatewayTraffic.Conversation] {
        conversations.filter { conv in conv.lastWrite.map { $0 >= sessionCreatedAt } ?? true }
    }

    func projectDir(cwd: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(AgentLogSource.posixPathSlug(cwd), isDirectory: true)
    }

    static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The gateway this session resolves to now: the same rule the launch
    /// uses (a Manager by its workspace tag, anything else by worktree path or
    /// PR slug). Shared with the `recording` payload.
    static func resolvedGateway(
        session: Session, worktreePath: String?, prLinks: [SessionLink], devRoot: String?, config: AppConfig
    ) -> WorkspaceGateway? {
        if session.isManager {
            return ManagerSessionController.managerGatewayMatch(
                workspaceTag: session.managerWorkspaceTag, config: config).gateway
        }
        guard let devRoot else { return nil }
        return SessionService.gatewayMatch(
            worktreePath: worktreePath, prLinks: prLinks, devRoot: devRoot, config: config)?.gateway
    }

    static func resolvedGateway(_ input: SessionInput, config: AppConfig, devRoot: String?) -> WorkspaceGateway? {
        resolvedGateway(session: input.session, worktreePath: input.worktreePath, prLinks: input.prLinks,
                        devRoot: devRoot, config: config)
    }

    /// The org/key the session's resolved gateway belongs to, when the Corveil
    /// connection manages it.
    static func expected(for input: SessionInput, config: AppConfig, devRoot: String?) -> GatewayTraffic.Expected? {
        CorveilGatewayMigration.managedOrgKey(for: resolvedGateway(input, config: config, devRoot: devRoot), config: config)
            .map { GatewayTraffic.Expected(organizationID: $0.orgID, organizationName: $0.orgName, apiKeyID: $0.keyID) }
    }

    /// Whether silence in the log means something: the agent launched
    /// through a gateway, or (no launch recorded) one is configured.
    static func throughGateway(_ input: SessionInput, config: AppConfig, devRoot: String?) -> Bool {
        if let launched = input.session.launchedGateway, launched.via != .unknown {
            return launched.baseURL != nil
        }
        return !(resolvedGateway(input, config: config, devRoot: devRoot)?.isEmpty ?? true)
    }

    // MARK: - Default I/O

    public static let urlSessionGet: HTTPGet = { url, key in
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    public static let runCorveilCLI: CLIList = { binary, cursor in
        var args = ["control", "observability", "logs-list", "--limit", String(GatewayTraffic.pageSize)]
        if let cursor { args += ["--cursor", cursor] }
        return await Task.detached { () -> Data? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        }.value
    }

    /// `defaults.binaries["corveil"]`, else the usual install locations.
    public static let findCorveil: @Sendable (AppConfig) -> String? = { config in
        let fm = FileManager.default
        if let configured = config.defaults.binaries["corveil"], fm.isExecutableFile(atPath: configured) {
            return configured
        }
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/corveil", "/usr/local/bin/corveil", home + "/.local/bin/corveil", home + "/go/bin/corveil"]
            .first { fm.isExecutableFile(atPath: $0) }
    }
}

extension SessionService {
    /// Snapshot what the verifier needs from app state (main actor).
    @MainActor
    public static func gatewayTrafficInputs(_ appState: AppState) -> [GatewayTrafficVerifier.SessionInput] {
        appState.sessions.map { s in
            GatewayTrafficVerifier.SessionInput(
                session: s,
                worktreePath: appState.primaryWorktree(for: s.id)?.worktreePath,
                prLinks: appState.links(for: s.id),
                managerCwd: s.isManager
                    ? appState.terminals(for: s.id).first(where: { $0.isAgentSurface(session: s) })?.cwd
                    : nil)
        }
    }
}
