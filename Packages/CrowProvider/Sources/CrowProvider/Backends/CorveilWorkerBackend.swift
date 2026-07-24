import Foundation
import CrowCore

/// Configuration for the Corveil worker-runner surface.
///
/// Unlike `CorveilConfig` (which relies on ambient `corveil login` state for the
/// task tracker), the runner authenticates with an **org-scoped API key** so it
/// can claim work as a stable `worker_id`. Both values are sourced from the
/// crowd process environment (`CORVEIL_URL` / `CORVEIL_API_KEY`) and are **never
/// persisted to disk** — they're threaded in here and passed to the `corveil`
/// CLI as env on each call. See corveil/crow#801 + Corveil ADR-0020/0014.
public struct CorveilWorkerConfig: Sendable, Equatable {
    /// Corveil base URL (`CORVEIL_URL`). Empty ⇒ let the CLI use its own default.
    public let url: String
    /// Org-scoped API key (`CORVEIL_API_KEY`). Empty ⇒ the runner is misconfigured.
    public let apiKey: String

    public init(url: String, apiKey: String) {
        self.url = url
        self.apiKey = apiKey
    }

    /// The env dictionary to pass to `corveil` invocations. Empty values are
    /// omitted so the CLI falls back to ambient state rather than seeing a blank.
    public var env: [String: String] {
        var e: [String: String] = [:]
        if !url.isEmpty { e["CORVEIL_URL"] = url }
        if !apiKey.isEmpty { e["CORVEIL_API_KEY"] = apiKey }
        return e
    }

    public var hasAPIKey: Bool { !apiKey.isEmpty }
}

/// Why a `worker-run` CLI call failed, distinguished so the runner loop can
/// react correctly (skip vs stop vs surface).
public enum WorkerRunError: Error, Equatable {
    /// `claim` lost the race (HTTP 409) — the run is already claimed. Pick another.
    case unclaimable
    /// `plan.FeatureCrowWorkers` is off for this org (HTTP 404 `feature_disabled`).
    case featureDisabled
    /// The org-scoped API key is missing/invalid.
    case unauthenticated
    /// The CLI emitted output that couldn't be parsed as a `WorkerRun`.
    case badResponse(String)
    /// Any other non-zero exit.
    case commandFailed(String)
}

/// `corveil worker-run …` CLI wrapper — the native successor to the manual
/// `worker-runner` skill loop. Structured like ``CorveilTaskBackend``: it wraps
/// the `corveil` CLI through a ``ShellRunner`` (so it's unit-testable with a
/// fake) and passes the runner's org-scoped credentials as env.
///
/// Crow owns the claim → heartbeat → complete lifecycle; the agent (running in a
/// scratch workdir) performs allow-listed write-backs directly via
/// `worker-run mcp-call`. See corveil/crow#801.
public struct CorveilWorkerBackend: Sendable {
    private let shellRunner: ShellRunner
    private let config: CorveilWorkerConfig

    public init(shellRunner: ShellRunner, config: CorveilWorkerConfig) {
        self.shellRunner = shellRunner
        self.config = config
    }

    // MARK: - Verbs

    /// List claimable runs matching this runner's routing (`--kind`, `--caps`).
    /// `caps` is only sent when non-empty; passing an empty array here does NOT
    /// send `--caps` (which would opt into the "no-cap runs only" subset filter).
    public func listClaimable(kind: String?, caps: [String], limit: Int? = nil) async throws -> [WorkerRun] {
        var args = ["corveil", "worker-run", "list", "--claimable", "--json"]
        if let kind, !kind.isEmpty {
            args += ["--kind", kind]
        }
        if !caps.isEmpty {
            args += ["--caps", caps.joined(separator: ",")]
        }
        if let limit {
            args += ["--limit", String(limit)]
        }
        let output = try await run(args)
        return Self.parseRuns(output)
    }

    /// Full snapshot for one run (prompt body + write-back policy).
    public func get(_ id: String) async throws -> WorkerRun {
        let output = try await run(["corveil", "worker-run", "get", id, "--json"])
        return try Self.parseRun(output)
    }

    /// Atomically claim a queued run. Throws ``WorkerRunError/unclaimable`` on a
    /// 409 (someone else won the race) so the caller can move to the next one.
    public func claim(_ id: String, workerID: String, leaseSeconds: Int) async throws -> WorkerRun {
        let output = try await run([
            "corveil", "worker-run", "claim", id,
            "--worker-id", workerID,
            "--lease-seconds", String(leaseSeconds),
            "--json",
        ])
        return try Self.parseRun(output)
    }

    /// Extend the lease (and promote `claimed → running`). Best-effort — the
    /// caller heartbeats on a timer and a single miss isn't fatal.
    public func heartbeat(_ id: String, workerID: String, leaseSeconds: Int) async throws {
        _ = try await run([
            "corveil", "worker-run", "heartbeat", id,
            "--worker-id", workerID,
            "--lease-seconds", String(leaseSeconds),
            "--json",
        ])
    }

    /// Terminal transition. A non-empty `error` marks the run failed (skips
    /// delivery); otherwise it's completed with the given title/content/output.
    public func complete(
        _ id: String,
        workerID: String,
        title: String?,
        content: String?,
        output: String?,
        error: String?
    ) async throws {
        var args = [
            "corveil", "worker-run", "complete", id,
            "--worker-id", workerID,
            "--json",
        ]
        if let error, !error.isEmpty {
            args += ["--error", error]
        } else {
            if let title { args += ["--title", title] }
            if let content { args += ["--content", content] }
            if let output, !output.isEmpty { args += ["--output", output] }
        }
        _ = try await run(args)
    }

    // MARK: - Shell

    /// Run a `corveil` invocation with the runner's credentials as env, mapping
    /// shell failures to typed ``WorkerRunError``s.
    private func run(_ args: [String]) async throws -> String {
        do {
            return try await shellRunner.run(args: args, env: config.env, cwd: NSHomeDirectory())
        } catch let ShellRunnerError.nonZeroExit(_, output) {
            throw Self.classify(output)
        }
    }

    /// Map CLI stderr/stdout onto a typed error. The `worker-run` verbs surface
    /// HTTP status via the error envelope's `code`/message text.
    static func classify(_ output: String) -> WorkerRunError {
        let lower = output.lowercased()
        if lower.contains("feature_disabled") || lower.contains("feature disabled") {
            return .featureDisabled
        }
        if lower.contains("409") || lower.contains("conflict") || lower.contains("unclaimable") {
            return .unclaimable
        }
        if CorveilTaskBackend.looksUnauthenticated(output)
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("invalid api key") {
            return .unauthenticated
        }
        return .commandFailed(output)
    }

    // MARK: - Parsing

    /// Parse a single `WorkerRun` object from CLI JSON.
    static func parseRun(_ output: String) throws -> WorkerRun {
        guard let data = output.data(using: .utf8) else {
            throw WorkerRunError.badResponse(output)
        }
        // `list` returns an array, `get`/`claim` a bare object; tolerate an
        // array-of-one here too.
        let decoder = JSONDecoder()
        if let run = try? decoder.decode(WorkerRun.self, from: data) {
            return run
        }
        if let runs = try? decoder.decode([WorkerRun].self, from: data), let first = runs.first {
            return first
        }
        throw WorkerRunError.badResponse(output)
    }

    /// Parse an array of `WorkerRun`s from `list` output (tolerates a bare object).
    static func parseRuns(_ output: String) -> [WorkerRun] {
        guard let data = output.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        if let runs = try? decoder.decode([WorkerRun].self, from: data) {
            return runs
        }
        // Some CLIs wrap the list as `{ "runs": [...] }`.
        if let wrapper = try? decoder.decode(WorkerRunList.self, from: data) {
            return wrapper.runs
        }
        if let run = try? decoder.decode(WorkerRun.self, from: data) {
            return [run]
        }
        return []
    }

    private struct WorkerRunList: Codable { let runs: [WorkerRun] }
}
