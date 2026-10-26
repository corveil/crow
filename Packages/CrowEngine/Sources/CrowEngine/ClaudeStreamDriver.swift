import CrowCore
import Foundation

/// EXPERIMENTAL: drives Claude Code headless over
/// `claude -p --input-format stream-json --output-format stream-json`, instead
/// of a TUI in tmux. Opt-in (`CROW_CHAT_DRIVER=1` on crowd, off by default),
/// isolated from the launch / `send` paths, and one process per Crow session.
///
/// The process is a child of crowd, so it does not survive a crowd restart the
/// way tmux-hosted agents do. It is a stepping stone to an out-of-process agent
/// host, which will supersede it.
///
/// Wire protocol (verified against Claude Code 2.1.309):
/// - stdin: `{"type":"user","message":{"role":"user","content":"…"}}` per turn;
///   the same process takes any number of turns.
/// - stdout: `system/init` (carries `session_id`), `assistant` / `user` records
///   in transcript shape, `stream_event` token deltas (with
///   `--include-partial-messages`), and one `result` per turn.
/// - permissions: only with `--permission-prompt-tool stdio` does Claude ask
///   the host — as `{"type":"control_request","request":{"subtype":"can_use_tool",…}}`,
///   answered by a `control_response`. Without it, `--permission-prompts host`
///   silently auto-denies (`system/permission_denied`).
///
/// Claude also writes its normal `~/.claude/projects/<slug>/<id>.jsonl`, so the
/// Chat view's transcript reader renders a driven session unchanged.
public final class ClaudeStreamDriver: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case conversationStarted(id: String)
        case turnStarted
        case turnEnded(isError: Bool)
        case permissionRequested(PermissionRequest)
        case exited(status: Int32)
    }

    /// Context usage for the Chat view's meter. `contextWindow` and `costUSD`
    /// come from `result` (`modelUsage[*].contextWindow`, `total_cost_usd`; both
    /// verified present on 2.1.309), the token count from the latest
    /// main-conversation `assistant` record.
    public struct Usage: Sendable, Equatable {
        public var usedTokens: Int?
        public var model: String?
        public var contextWindow: Int?
        public var costUSD: Double?
    }

    public struct PermissionRequest: Sendable, Equatable {
        public var requestID: String
        public var toolName: String
        public var summary: String
        /// Echoed back as `updatedInput` on allow, as JSON text.
        public var inputJSON: String
    }

    public let sessionID: UUID
    public let cwd: String
    public let logURL: URL
    private let executable: String
    private let arguments: [String]
    private let onEvent: @Sendable (Event) -> Void

    /// Guards the state below. Never held across a pipe write: a child that
    /// stops reading stdin must not wedge `ingest` (#1372 review).
    private let lock = NSLock()
    /// Serializes log appends from `write` and `ingest`, independently of `lock`.
    private let logLock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var logHandle: FileHandle?
    private var _conversationID: String?
    private var _pending: [String: PermissionRequest] = [:]
    private var _usage = Usage()

    public var conversationID: String? { lock.withLock { _conversationID } }
    public var pendingPermissions: [PermissionRequest] {
        lock.withLock { Array(_pending.values).sorted { $0.requestID < $1.requestID } }
    }
    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }
    public var usage: Usage { lock.withLock { _usage } }

    /// The production argv. `claudePath` comes from the agent's resolved
    /// binary; a login shell supplies the PATH crowd itself may not have.
    public static func defaultCommand(claudePath: String, resumeID: String?) -> (String, [String]) {
        var claude = [claudePath, "-p",
                      "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                      "--include-partial-messages",
                      "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]
        if let resumeID { claude += ["--resume", resumeID] }
        return ("/bin/zsh", ["-lc", "exec \"$@\"", "crow-chat-driver"] + claude)
    }

    public init(
        sessionID: UUID, cwd: String, logURL: URL,
        executable: String, arguments: [String],
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.logURL = logURL
        self.executable = executable
        self.arguments = arguments
        self.onEvent = onEvent
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            self?.ingest(chunk)
        }
        // Drain stderr so a chatty child never blocks on a full pipe.
        errPipe.fileHandleForReading.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
        }
        p.terminationHandler = { [weak self] proc in
            self?.onEvent(.exited(status: proc.terminationStatus))
        }
        lock.withLock {
            process = p
            stdin = inPipe.fileHandleForWriting
            logHandle = log
        }
        try p.run()
    }

    public func sendUser(_ text: String) throws {
        try write(["type": "user", "message": ["role": "user", "content": text]])
        onEvent(.turnStarted)
    }

    public func respondPermission(requestID: String, allow: Bool, message: String? = nil) throws {
        guard let req = lock.withLock({ _pending.removeValue(forKey: requestID) }) else {
            throw DriverError.unknownRequest(requestID)
        }
        let response: [String: Any]
        if allow {
            let input = (try? JSONSerialization.jsonObject(with: Data(req.inputJSON.utf8))) ?? [:]
            response = ["behavior": "allow", "updatedInput": input]
        } else {
            response = ["behavior": "deny", "message": message ?? "Denied from Crow chat."]
        }
        try write([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": response],
        ])
        // Back from waiting on the human to the model's turn.
        onEvent(.turnStarted)
    }

    public func stop() {
        lock.withLock {
            try? stdin?.close()
            stdin = nil
            if process?.isRunning == true { process?.terminate() }
        }
    }

    public enum DriverError: Error, CustomStringConvertible {
        case notRunning
        case unknownRequest(String)
        public var description: String {
            switch self {
            case .notRunning: return "Chat driver is not running"
            case .unknownRequest(let id): return "No pending permission request \(id)"
            }
        }
    }

    // MARK: - IO

    private func write(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        guard let stdin = lock.withLock({ self.stdin }) else { throw DriverError.notRunning }
        try stdin.write(contentsOf: data)
        // The log is the transcript of what crossed the wire, both ways.
        appendLog(Data(">".utf8) + data)
    }

    private func appendLog(_ data: Data) {
        let handle = lock.withLock { logHandle }
        logLock.withLock { try? handle?.write(contentsOf: data) }
    }

    private func ingest(_ chunk: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<nl]))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        for line in lines where !line.isEmpty {
            // `stream_event` deltas are high-volume and redundant with the
            // final `assistant` record; keep them out of the log.
            if line.range(of: Data("\"type\":\"stream_event\"".utf8)) == nil {
                appendLog(line + Data([0x0A]))
            }
        }
        for line in lines {
            lock.withLock { Self.updateUsage(&_usage, from: line) }
            guard let event = Self.classify(line) else { continue }
            lock.withLock {
                switch event {
                case .conversationStarted(let id): _conversationID = id
                case .permissionRequested(let req): _pending[req.requestID] = req
                default: break
                }
            }
            onEvent(event)
        }
    }

    /// Fold one stdout line into `usage`. Pure.
    static func updateUsage(_ usage: inout Usage, from line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "assistant":
            // Subagent traffic carries a `parent_tool_use_id`; only the main
            // conversation fills the session's context.
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return }
            guard let message = obj["message"] as? [String: Any],
                  let u = message["usage"] as? [String: Any] else { return }
            func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            let used = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
            guard used > 0 else { return }
            usage.usedTokens = used
            if let m = message["model"] as? String, m != "<synthetic>" { usage.model = m }
        case "result":
            if let cost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue { usage.costUSD = cost }
            if let models = obj["modelUsage"] as? [String: [String: Any]] {
                // Prefer the entry for the model that answered; `[1m]` variants
                // key as `<model>[1m]`.
                let key = usage.model.flatMap { m in
                    models.keys.first { $0 == m || $0.hasPrefix(m) }
                } ?? models.keys.sorted().first
                if let key, let w = (models[key]?["contextWindow"] as? NSNumber)?.intValue {
                    usage.contextWindow = w
                }
            }
        default:
            break
        }
    }

    /// Map one stdout line to a driver event. Pure; most lines are `nil`.
    public static func classify(_ line: Data) -> Event? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        switch obj["type"] as? String {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String {
                return .conversationStarted(id: id)
            }
            return nil
        case "result":
            return .turnEnded(isError: obj["is_error"] as? Bool ?? false)
        case "control_request":
            guard let reqID = obj["request_id"] as? String,
                  let req = obj["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool" else { return nil }
            let name = req["tool_name"] as? String ?? "tool"
            let input = req["input"] ?? [String: Any]()
            let inputJSON = (try? JSONSerialization.data(withJSONObject: input))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .permissionRequested(PermissionRequest(
                requestID: reqID, toolName: name,
                summary: ChatTranscript.toolInputSummary(name: name, input: input),
                inputJSON: inputJSON))
        default:
            return nil
        }
    }
}
