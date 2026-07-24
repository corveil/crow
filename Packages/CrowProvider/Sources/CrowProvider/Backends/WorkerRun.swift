import Foundation

/// A Corveil worker-run envelope, as returned by the `corveil worker-run …` CLI
/// (a projection of the `/api/worker-runs` JSON — see Corveil ADR-0020).
///
/// A worker run is the Corveil-sourced twin of a local `JobConfig` run: a
/// prompt snapshotted at enqueue that an external Crow runner claims, executes
/// on its own subscription, and completes — with allow-listed write-backs
/// routed through Corveil (`worker-run mcp-call`) so no org secrets live on the
/// runner. Crow only reads the fields it needs to execute and complete a run;
/// unknown fields are ignored (forward-compatible decoding).
public struct WorkerRun: Codable, Sendable, Equatable {
    /// Run id (the token passed to every `worker-run` verb).
    public let id: String
    /// Denormalized worker slug — the routing `kind` a runner filters on.
    public let kind: String?
    /// Resolved prompt (template vars already applied at enqueue). The body the
    /// agent executes; `nil`/empty means the run carries nothing to run.
    public let promptTitle: String?
    public let promptBody: String?
    /// Per-server write-back allow-list snapshot:
    /// `{ "<server>": { "allowed": [...], "dry_run": bool } }`. Surfaced so the
    /// wrapped prompt can tell the agent which `mcp-call` tools are permitted.
    public let writebackPolicy: [String: WritebackBinding]?
    /// Hard claim filter — a runner must advertise all of these caps.
    public let requiredCaps: [String]?
    /// Lifecycle: `queued | claimed | running | completed | failed`.
    public let status: String?
    /// Active claim (present once claimed), or `nil` when queued/terminal.
    public let claim: WorkerRunClaim?

    private enum CodingKeys: String, CodingKey {
        case id, kind, status, claim
        case promptTitle = "prompt_title"
        case promptBody = "prompt_body"
        case writebackPolicy = "writeback_policy"
        case requiredCaps = "required_caps"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        claim = try c.decodeIfPresent(WorkerRunClaim.self, forKey: .claim)
        promptTitle = try c.decodeIfPresent(String.self, forKey: .promptTitle)
        promptBody = try c.decodeIfPresent(String.self, forKey: .promptBody)
        writebackPolicy = try c.decodeIfPresent([String: WritebackBinding].self, forKey: .writebackPolicy)
        requiredCaps = try c.decodeIfPresent([String].self, forKey: .requiredCaps)
    }

    public init(
        id: String,
        kind: String? = nil,
        promptTitle: String? = nil,
        promptBody: String? = nil,
        writebackPolicy: [String: WritebackBinding]? = nil,
        requiredCaps: [String]? = nil,
        status: String? = nil,
        claim: WorkerRunClaim? = nil
    ) {
        self.id = id
        self.kind = kind
        self.promptTitle = promptTitle
        self.promptBody = promptBody
        self.writebackPolicy = writebackPolicy
        self.requiredCaps = requiredCaps
        self.status = status
        self.claim = claim
    }
}

/// One server's write-back grant inside a run's `writeback_policy`.
public struct WritebackBinding: Codable, Sendable, Equatable {
    public let allowed: [String]
    public let dryRun: Bool

    private enum CodingKeys: String, CodingKey {
        case allowed
        case dryRun = "dry_run"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent([String].self, forKey: .allowed) ?? []
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }

    public init(allowed: [String], dryRun: Bool = false) {
        self.allowed = allowed
        self.dryRun = dryRun
    }
}

/// The `claim` JSONB on a claimed/running run.
public struct WorkerRunClaim: Codable, Sendable, Equatable {
    public let workerID: String?
    public let leaseExpiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case workerID = "worker_id"
        case leaseExpiresAt = "lease_expires_at"
    }

    public init(workerID: String?, leaseExpiresAt: String? = nil) {
        self.workerID = workerID
        self.leaseExpiresAt = leaseExpiresAt
    }
}

/// The agent's final result for a run, read by Crow from
/// `<scratchDir>/.crow-run-result.json` on `.done` and mapped to
/// `corveil worker-run complete` (Crow owns the terminal Corveil calls).
public struct WorkerRunResult: Codable, Sendable, Equatable {
    public let title: String?
    public let content: String?
    /// Typed result blob, re-serialized verbatim into `complete --output`.
    public let output: String?
    /// Non-empty ⇒ the agent reported a failure ⇒ `complete --error`.
    public let error: String?

    public init(title: String?, content: String?, output: String? = nil, error: String? = nil) {
        self.title = title
        self.content = content
        self.output = output
        self.error = error
    }

    /// Decode a `.crow-run-result.json` payload from raw bytes. `output` may be a
    /// nested JSON object; it's re-encoded to a compact string so it can be
    /// handed straight to `worker-run complete --output`. Pure (no filesystem)
    /// so it's unit-testable.
    public static func decode(fromJSON data: Data) -> WorkerRunResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = obj["title"] as? String
        let content = obj["content"] as? String
        let error = obj["error"] as? String
        var output: String?
        if let outObj = obj["output"], !(outObj is NSNull) {
            output = (try? JSONSerialization.data(withJSONObject: outObj))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return WorkerRunResult(title: title, content: content, output: output, error: error)
    }

    /// Read and decode `<scratchDir>/.crow-run-result.json`, or `nil` if the file
    /// is missing/unparseable (⇒ the caller completes the run with `--error`).
    public static func decode(fromFile path: String) -> WorkerRunResult? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return decode(fromJSON: data)
    }
}
