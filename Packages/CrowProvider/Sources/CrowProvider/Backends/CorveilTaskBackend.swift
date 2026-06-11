import Foundation
import CrowCore

/// Per-workspace Corveil configuration threaded into ``CorveilTaskBackend``.
///
/// The corveil CLI manages its own auth state and target host (`corveil login`,
/// `CORVEIL_URL`), so none of these are required to *call* Corveil — they only
/// refine behavior:
/// - `host`: self-hosted Corveil host (e.g. `corveil.acme.io`) used **only** as a
///   fallback when corveil's JSON omits the `url` field (corveil#1363 added it,
///   so post-landing the fallback is almost never taken). The public `corveil.io`
///   is auto-detected; this is only needed for self-hosted instances.
public struct CorveilConfig: Sendable, Equatable {
    public let host: String?

    public init(host: String? = nil) {
        self.host = host
    }
}

/// `TaskBackend` implementation for Corveil. Wraps the `corveil` CLI.
///
/// Corveil is a **task-only** provider (no embedded git) — the second instance
/// of the "task tracker with no code surface" shape ADR 0005 carved out, after
/// Jira. A Corveil-tasked session pairs with a GitHub/GitLab `CodeBackend`
/// (resolved via `Session.codeProvider`); `ProviderManager.codeBackend(.corveil)`
/// returns `nil`.
///
/// Capabilities:
/// - `.batchedQuery` — corveil's `task list --ids` (corveil#1364) gives us bulk
///   fetch in a single HTTP request per polling cycle.
/// - `.projectBoardStatus` — corveil exposes a real `in_progress` intermediate
///   status, wired through `setTaskStatus`. The `.inReview` → `in_progress`
///   mapping is lossy (corveil has no review-distinct status), so the
///   project-board UI surface handles the visual distinction.
///
/// See ADR 0005.
public struct CorveilTaskBackend: TaskBackend {
    public let provider: Provider = .corveil
    public let capabilities: Set<TaskCapability> = [.batchedQuery, .projectBoardStatus]

    private let shellRunner: ShellRunner
    private let config: CorveilConfig

    public init(shellRunner: ShellRunner, config: CorveilConfig = CorveilConfig()) {
        self.shellRunner = shellRunner
        self.config = config
    }

    // MARK: - TaskBackend

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = CorveilTaskID.parse(url) else {
            throw ProviderError.invalidURL(url)
        }
        let output = try await run([
            "corveil", "task", "get", parsed.id, "--json",
        ])
        let obj = Self.firstObject(output)
        let title = (obj?["title"] as? String) ?? "Task \(parsed.id)"
        // corveil#1363 puts the user-facing URL right on the task; fall back to
        // a host-built URL when missing (older CLIs / unexpected payloads).
        let resolvedURL = (obj?["url"] as? String) ?? browseURL(for: parsed.id) ?? url
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: "",
            org: "",
            url: resolvedURL,
            provider: .corveil,
            isMR: false
        )
    }

    public func listAssigned(includeClosed: Bool) async throws -> AssignedListing {
        let open: [AssignedIssue]
        do {
            let openOut = try await run([
                "corveil", "task", "list",
                "--assignee", "@me",
                "--status", "open",
                "--json",
            ])
            open = Self.parseAssigned(openOut, host: config.host, statusOverride: nil)
        } catch {
            // Match Jira's degrade-to-empty semantics rather than throwing.
            return AssignedListing(open: [], closed: [])
        }

        guard includeClosed else {
            return AssignedListing(open: open, closed: [])
        }

        let closed: [AssignedIssue]
        do {
            let closedOut = try await run([
                "corveil", "task", "list",
                "--assignee", "@me",
                "--status", "closed",
                "--json",
            ])
            closed = Self.parseAssigned(closedOut, host: config.host, statusOverride: .done)
        } catch {
            return AssignedListing(open: open, closed: [])
        }
        return AssignedListing(open: open, closed: closed)
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        guard let parsed = CorveilTaskID.parse(url) else { throw ProviderError.invalidURL(url) }
        var args = ["corveil", "task", "update", parsed.id]
        for label in add {
            args.append("--add-label")
            args.append(label)
        }
        for label in remove {
            args.append("--remove-label")
            args.append(label)
        }
        _ = try await run(args)
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        guard let parsed = CorveilTaskID.parse(url) else { throw ProviderError.invalidURL(url) }
        _ = try await run([
            "corveil", "task", "update", parsed.id,
            "--status", Self.corveilStatusName(for: status),
        ])
    }

    public func assign(url: String, to login: String) async throws {
        guard let parsed = CorveilTaskID.parse(url) else { throw ProviderError.invalidURL(url) }
        _ = try await run([
            "corveil", "task", "update", parsed.id,
            "--assignee", login,
        ])
    }

    public func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
        // Corveil has no project/repo concept analogous to GitHub or Jira's
        // project key, so the `repo` parameter is intentionally ignored here.
        // Self-assign matches the Jira pattern in setup.sh flows.
        var args = [
            "corveil", "task", "create",
            "--title", title,
            "--description", body,
            "--assignee", "@me",
        ]
        for label in labels {
            args.append("--label")
            args.append(label)
        }
        args.append("--json")
        let output = try await run(args)

        guard let obj = Self.firstObject(output),
              let id = obj["id"].flatMap({ Self.stringify($0) }),
              let parsed = CorveilTaskID.parse(id) else {
            throw ProviderError.commandFailed("corveil task create did not return a parseable id; got: \(output)")
        }
        let resolvedURL = (obj["url"] as? String) ?? browseURL(for: parsed.id) ?? parsed.id
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: "",
            org: "",
            url: resolvedURL,
            provider: .corveil,
            isMR: false
        )
    }

    // MARK: - Helpers

    /// Run a `corveil` invocation, translating shell failures into typed
    /// `ProviderError`s and giving a clear hint when corveil isn't authenticated.
    private func run(_ args: [String]) async throws -> String {
        do {
            return try await shellRunner.run(args: args, env: [:], cwd: NSHomeDirectory())
        } catch let ShellRunnerError.nonZeroExit(_, output) {
            if Self.looksUnauthenticated(output) {
                throw ProviderError.commandFailed("corveil is not authenticated — run `corveil login`. (\(output))")
            }
            throw ProviderError.commandFailed(output)
        }
    }

    private func browseURL(for id: String) -> String? {
        let host = config.host?.isEmpty == false ? config.host! : nil
        guard let host else { return nil }
        let prefix = host.hasPrefix("http") ? host : "https://\(host)"
        return "\(prefix)/dashboard/tasks/\(id)"
    }

    static func looksUnauthenticated(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("corveil login")
            || lower.contains("not authenticated")
            || lower.contains("unauthorized")
            || lower.contains("please login")
    }

    /// Map a Crow pipeline status to a Corveil status. Corveil's vocabulary is
    /// `open` / `in_progress` / `closed`; Crow's pipeline has five stages plus
    /// `.unknown`. `.inReview` collapses into `in_progress` — corveil has no
    /// review-distinct intermediate, so the project-board status capability is
    /// the UI surface that distinguishes "in review" visually.
    static func corveilStatusName(for status: TicketStatus) -> String {
        switch status {
        case .backlog, .ready: return "open"
        case .inProgress, .inReview: return "in_progress"
        case .done: return "closed"
        case .unknown: return "open"
        }
    }

    /// Reverse mapping from a corveil status string into Crow's `TicketStatus`.
    /// The reverse direction is lossless because we map "open" → `.ready` (the
    /// natural "queued, not started" state); `.backlog` is unreachable from
    /// corveil JSON, which is fine because it's a Crow-side curation concept.
    static func ticketStatus(fromCorveil raw: String) -> TicketStatus {
        switch raw.lowercased() {
        case "open": return .ready
        case "in_progress", "in-progress", "inprogress": return .inProgress
        case "closed", "done": return .done
        default: return .unknown
        }
    }

    // MARK: - JSON parsing

    /// corveil emits a JSON array of tasks for `task list` and a bare object for
    /// `task get` / `task create`. Return the first element of an array, or the
    /// bare object itself.
    static func firstObject(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = json as? [[String: Any]] { return arr.first }
        if let obj = json as? [String: Any] { return obj }
        return nil
    }

    /// Stringify a JSON value that could be either a string or a number (corveil
    /// could plausibly emit task ids as either). Used for parsing the created
    /// task's id out of `task create --json`.
    static func stringify(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func parseAssigned(_ output: String, host: String?, statusOverride: TicketStatus?) -> [AssignedIssue] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item -> AssignedIssue? in
            guard let idRaw = item["id"].flatMap(stringify),
                  let parsed = CorveilTaskID.parse(idRaw) else { return nil }
            let title = (item["title"] as? String) ?? "Task \(parsed.id)"
            let rawStatus = (item["status"] as? String) ?? ""
            let status = statusOverride ?? ticketStatus(fromCorveil: rawStatus)
            let state = (statusOverride == .done || rawStatus.lowercased() == "closed") ? "closed" : "open"
            let labels = (item["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            // Prefer the url emitted by corveil#1363; fall back to a host-built URL.
            let url: String = (item["url"] as? String)
                ?? host.flatMap({ h -> String? in
                    let prefix = h.hasPrefix("http") ? h : "https://\(h)"
                    return "\(prefix)/dashboard/tasks/\(parsed.id)"
                })
                ?? parsed.id
            return AssignedIssue(
                id: "corveil:\(parsed.id)",
                number: parsed.number,
                title: title,
                state: state,
                url: url,
                repo: "",
                labels: labels,
                provider: .corveil,
                projectStatus: status
            )
        }
    }
}

/// Parses Corveil task ids out of either a dashboard URL or a bare id.
///
/// Recognized shapes:
/// - `https://corveil.io/dashboard/tasks/42`
/// - `https://corveil.acme.io/dashboard/tasks/abc-42`
/// - bare numeric id: `42`
/// - bare slug id: `task-42` (best-effort — only when a numeric suffix is present)
///
/// `number` is the integer suffix when present (used by `TicketInfo.number` and
/// `AssignedIssue.number`); `id` is the full token passed to the CLI.
enum CorveilTaskID {
    static func parse(_ spec: String) -> (id: String, number: Int)? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bare id (numeric or slug): no slash, no scheme.
        if !trimmed.contains("/") {
            return makeID(from: trimmed)
        }

        // URL: pick the segment after `/tasks/`, stripping any query/fragment.
        if let range = trimmed.range(of: "/tasks/") {
            let tail = String(trimmed[range.upperBound...])
            let cleaned = tail
                .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" })
                .first
                .map(String.init) ?? ""
            return makeID(from: cleaned)
        }
        return nil
    }

    private static func makeID(from raw: String) -> (id: String, number: Int)? {
        guard !raw.isEmpty else { return nil }
        if let n = Int(raw) { return (raw, n) }
        // Slug with a trailing numeric suffix (e.g. "task-42"); extract the
        // suffix for the `number` field but pass the full id to the CLI.
        if let suffix = raw.split(separator: "-").last, let n = Int(suffix) {
            return (raw, n)
        }
        return nil
    }
}
