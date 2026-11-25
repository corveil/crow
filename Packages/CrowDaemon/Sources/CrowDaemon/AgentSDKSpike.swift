import CrowCore
import CrowIPC
import Foundation

// THROWAWAY SPIKE (CROW-1524, ADR 0033). Delete this file, its RPC handlers,
// `chat-sdk.js` and `spikes/agent-sdk-sidecar/` together when the spike ends.
//
// One Crow session's chat turns run on the Claude Agent SDK instead of the tmux
// terminal: crowd supervises a Node sidecar (`spikes/agent-sdk-sidecar/sidecar.mjs`)
// per session and speaks NDJSON to it over stdio. The sidecar already translates
// SDK messages into Web Chat's event vocabulary, so crowd only numbers the lines,
// keeps them for late readers (`get-sdk-chat-events`), pushes them to browsers as
// `sdk-chat-event` notifications, and forwards the operator's input.
//
// Off unless crowd starts with `CROW_AGENT_SDK_SPIKE=<path to the sidecar dir>`.
// No config field: nothing to migrate or clean up when the spike is deleted.

/// Where the sidecar is and what runs it. Nil (spike off) unless the env var is set.
struct AgentSDKSpikeConfig: Sendable, Equatable {
    static let envKey = "CROW_AGENT_SDK_SPIKE"
    static let nodeEnvKey = "CROW_AGENT_SDK_NODE"

    var sidecarScript: String
    var nodePath: String
    /// The operator's own `claude`, passed as `pathToClaudeCodeExecutable` so
    /// the sidecar needs none of the SDK's per-platform native binaries.
    var claudePath: String?

    /// Resolves the config, or explains in `problem` why the spike stays off.
    static func resolve(
        env: [String: String],
        findExecutable: (String) -> String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (config: AgentSDKSpikeConfig?, problem: String?) {
        guard let raw = env[envKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return (nil, nil)
        }
        let script = raw.hasSuffix(".mjs") ? raw : (raw as NSString).appendingPathComponent("sidecar.mjs")
        guard fileExists(script) else {
            return (nil, "\(envKey) is set but \(script) does not exist")
        }
        let node = env[nodeEnvKey].flatMap { $0.isEmpty ? nil : $0 } ?? findExecutable("node")
        guard let node else {
            return (nil, "\(envKey) is set but no `node` was found (set \(nodeEnvKey))")
        }
        return (AgentSDKSpikeConfig(sidecarScript: script, nodePath: node, claudePath: findExecutable("claude")), nil)
    }
}

/// What one sidecar is started with.
struct AgentSDKSidecarLaunch: Sendable, Equatable {
    var sessionID: UUID
    var cwd: String
    /// The SDK conversation to continue (`--resume`), after a stop or crash.
    var resume: String?
}

/// Output of a running sidecar, in order: its stdout lines, then its exit.
enum AgentSDKSidecarOutput: Sendable, Equatable {
    case line(String)
    case exit(Int32)
}

/// A running sidecar. `send` writes one line to its stdin.
protocol AgentSDKSidecarHandle: Sendable {
    func send(_ line: String) throws
    /// Close stdin (the sidecar shuts down on EOF), then terminate it.
    func stop()
}

/// Starts a sidecar. Injected so tests never spawn a process.
typealias AgentSDKSidecarLauncher = @Sendable (AgentSDKSidecarLaunch) throws
    -> (AgentSDKSidecarHandle, AsyncStream<AgentSDKSidecarOutput>)

enum AgentSDKSpikeError: Error, LocalizedError, Equatable {
    case notRunning
    case notPending(String)
    case badCommand(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The SDK conversation isn't running. Send a message to start it."
        case .notPending(let id): "Request \(id) isn't waiting for an answer any more."
        case .badCommand(let why): why
        }
    }
}

/// The per-session sidecars and their event logs.
actor AgentSDKSpike {
    /// One session's SDK conversation as crowd sees it.
    struct Log: Sendable {
        /// Numbered events (`seq` set), oldest first. `delta` events are pushed
        /// live but never kept: the `assistant` event that follows carries the
        /// whole text.
        var events: [JSONValue] = []
        var lastSeq = 0
        /// Permission and question requests still waiting on the operator.
        var pending: Set<String> = []
        var sdkSessionID: String?
        var running = false
    }

    struct Page: Sendable, Equatable {
        var events: [JSONValue]
        var cursor: Int
        var running: Bool
        var sdkSessionID: String?
        var pending: [String]
        /// The log was trimmed past the client's cursor: start over.
        var reset: Bool
    }

    static let maxEvents = 2_000
    static let pushMethod = "sdk-chat-event"

    let config: AgentSDKSpikeConfig?
    private let launcher: AgentSDKSidecarLauncher
    /// Frames for the browsers, drained in order by one task: a `Task` per
    /// frame could reorder two deltas.
    private let pushes: AsyncStream<String>.Continuation
    private var logs: [UUID: Log] = [:]
    private var handles: [UUID: AgentSDKSidecarHandle] = [:]
    /// Bumped per launch and per End, so a stopped or dead sidecar's late
    /// output can't land in its successor's log.
    private var generations: [UUID: Int] = [:]
    private var reaper: Task<Void, Never>?

    init(
        config: AgentSDKSpikeConfig?,
        launcher: @escaping AgentSDKSidecarLauncher,
        push: @escaping @Sendable (String) async -> Void
    ) {
        self.config = config
        self.launcher = launcher
        let (frames, pushes) = AsyncStream<String>.makeStream()
        self.pushes = pushes
        Task {
            for await frame in frames { await push(frame) }
        }
    }

    var enabled: Bool { config != nil }

    func page(session: UUID, after cursor: Int?) -> Page {
        let log = logs[session] ?? Log()
        let first = log.events.first.flatMap { Self.seq(of: $0) } ?? (log.lastSeq + 1)
        // A cursor older than what's kept (or from a crowd that restarted)
        // can't be continued: send everything kept and say so.
        let reset = cursor == nil || cursor! < first - 1 || cursor! > log.lastSeq
        let events = reset ? log.events : log.events.filter { (Self.seq(of: $0) ?? 0) > cursor! }
        return Page(
            events: events, cursor: log.lastSeq, running: log.running,
            sdkSessionID: log.sdkSessionID, pending: log.pending.sorted(), reset: reset)
    }

    /// One `sdk-chat-input` command. `cwd` is only used to start the sidecar.
    func input(session: UUID, cwd: String, command: [String: JSONValue]) async throws {
        guard enabled else { throw AgentSDKSpikeError.badCommand("The Agent SDK spike is off.") }
        let op = command["op"]?.stringValue ?? ""
        var line: [String: JSONValue] = ["op": .string(op)]
        switch op {
        case "message":
            guard let text = command["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentSDKSpikeError.badCommand("text required")
            }
            line["text"] = .string(text)
            if handles[session] == nil { try start(session: session, cwd: cwd) }
        case "respond":
            guard let id = command["request_id"]?.stringValue, !id.isEmpty else {
                throw AgentSDKSpikeError.badCommand("request_id required")
            }
            guard handles[session] != nil else { throw AgentSDKSpikeError.notRunning }
            guard logs[session]?.pending.contains(id) == true else { throw AgentSDKSpikeError.notPending(id) }
            let behavior = command["behavior"]?.stringValue ?? ""
            guard behavior == "allow" || behavior == "deny" else {
                throw AgentSDKSpikeError.badCommand("behavior must be allow or deny")
            }
            line["request_id"] = .string(id)
            line["behavior"] = .string(behavior)
            if let m = command["message"]?.stringValue { line["message"] = .string(m) }
            if let a = command["answers"] {
                guard case .object = a else { throw AgentSDKSpikeError.badCommand("answers must be an object") }
                line["answers"] = a
            }
        case "interrupt":
            guard handles[session] != nil else { throw AgentSDKSpikeError.notRunning }
        case "stop":
            guard handles[session] != nil else { throw AgentSDKSpikeError.notRunning }
            end(session, reason: "ended")
            return
        default:
            throw AgentSDKSpikeError.badCommand("unknown op \(op)")
        }
        guard let handle = handles[session] else { throw AgentSDKSpikeError.notRunning }
        try handle.send(Self.encode(.object(line)))
    }

    private func start(session: UUID, cwd: String) throws {
        let resume = logs[session]?.sdkSessionID
        let (handle, output) = try launcher(AgentSDKSidecarLaunch(sessionID: session, cwd: cwd, resume: resume))
        let generation = (generations[session] ?? 0) + 1
        generations[session] = generation
        handles[session] = handle
        logs[session, default: Log()].running = true
        if let resume {
            append(session, ["kind": .string("notice"), "text": .string("Resuming SDK conversation \(resume).")])
        }
        Task { [weak self] in
            for await item in output {
                guard let self else { return }
                switch item {
                case .line(let text): await self.ingest(session: session, generation: generation, line: text)
                case .exit(let status): await self.exited(session: session, generation: generation, status: status)
                }
            }
        }
    }

    /// One stdout line from the sidecar.
    func ingest(session: UUID, generation: Int, line: String) {
        guard generations[session] == generation,
              let data = line.data(using: .utf8),
              case .object(var event)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              let kind = event["kind"]?.stringValue else { return }
        var log = logs[session, default: Log()]
        switch kind {
        case "delta":
            // Pushed, not kept. Tagged with the last kept seq so a client can
            // tell which bubble it continues.
            event["seq"] = .int(log.lastSeq)
            pushes.yield(Self.frame(session: session, event: .object(event)))
            return
        case "ready":
            if let id = event["sdk_session_id"]?.stringValue { log.sdkSessionID = id }
        case "permission", "question":
            if let id = event["request_id"]?.stringValue { log.pending.insert(id) }
        case "resolved":
            if let id = event["request_id"]?.stringValue { log.pending.remove(id) }
        case "command_error":
            event["kind"] = .string("notice")
            event["is_error"] = .bool(true)
        default:
            break
        }
        logs[session] = log
        append(session, event)
    }

    /// End a session's sidecar now, without waiting for the process to exit.
    /// The generation moves on, so anything the old sidecar still prints
    /// (its last `resolved`, its exit) is dropped; nothing it asked stays
    /// answerable; and browsers get `stopped` at once, which closes their
    /// cards. Together with per-sidecar request ids, an answer can only reach
    /// the request its card was drawn for (review of #1525).
    private func end(_ session: UUID, reason: String) {
        guard let handle = handles.removeValue(forKey: session) else { return }
        generations[session, default: 0] += 1
        handle.stop()
        logs[session, default: Log()].running = false
        logs[session]?.pending.removeAll()
        append(session, ["kind": .string("stopped"), "reason": .string(reason)])
    }

    /// Stop the sidecars of sessions that may no longer run one (deleted,
    /// completed, archived), and forget the logs of sessions that are gone.
    func prune(running live: Set<UUID>, existing: Set<UUID>) {
        for id in Array(handles.keys) where !live.contains(id) { end(id, reason: "session closed") }
        for id in Array(logs.keys) where !existing.contains(id) && handles[id] == nil {
            logs[id] = nil
            generations[id] = nil
        }
    }

    func exited(session: UUID, generation: Int, status: Int32) {
        guard generations[session] == generation else { return }
        handles[session] = nil
        logs[session, default: Log()].running = false
        logs[session]?.pending.removeAll()
        append(session, ["kind": .string("stopped"), "status": .int(Int(status))])
    }

    /// Number, keep and push one event.
    private func append(_ session: UUID, _ event: [String: JSONValue]) {
        var log = logs[session, default: Log()]
        log.lastSeq += 1
        var numbered = event
        numbered["seq"] = .int(log.lastSeq)
        log.events.append(.object(numbered))
        if log.events.count > Self.maxEvents { log.events.removeFirst(log.events.count - Self.maxEvents) }
        logs[session] = log
        pushes.yield(Self.frame(session: session, event: .object(numbered)))
    }

    /// Stop every sidecar (daemon shutdown).
    func stopAll() {
        for id in Array(handles.keys) { end(id, reason: "crowd stopped") }
    }

    /// Every 30 seconds, stop the sidecars of sessions that no longer exist or
    /// were completed or archived. `sessions` reads the live session list.
    func startReaper(
        every interval: Duration = .seconds(30),
        sessions: @escaping @Sendable () async -> (running: Set<UUID>, existing: Set<UUID>)
    ) {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let current = await sessions()
                await self?.prune(running: current.running, existing: current.existing)
            }
        }
    }

    static func seq(of event: JSONValue) -> Int? {
        event.objectValue?["seq"]?.intValue
    }

    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// The `/rpc` WebSocket notification for one event (no `id`, like `changed`).
    static func frame(session: UUID, event: JSONValue) -> String {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(pushMethod),
            "params": .object(["session_id": .string(session.uuidString), "event": event]),
        ]))
    }
}

// MARK: - The real process

/// Splits a byte stream into lines. Fed by one readability handler, which
/// FileHandle calls serially.
final class AgentSDKLineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// Whatever followed the last newline, at EOF.
    func flush() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let rest = String(data: buffer, encoding: .utf8), !rest.isEmpty else { return nil }
        return rest
    }
}

/// A `node sidecar.mjs` child. Stdout is split into lines and yielded in
/// order; the exit is yielded only after stdout reaches EOF, so no line is
/// lost to a race with the termination handler.
final class AgentSDKProcessSidecar: AgentSDKSidecarHandle, @unchecked Sendable {
    private let process: Process
    private let stdin: FileHandle
    private let lock = NSLock()

    private init(process: Process, stdin: FileHandle) {
        self.process = process
        self.stdin = stdin
    }

    static func launcher(config: AgentSDKSpikeConfig) -> AgentSDKSidecarLauncher {
        { launch in try start(config: config, launch: launch) }
    }

    static func arguments(config: AgentSDKSpikeConfig, launch: AgentSDKSidecarLaunch) -> [String] {
        var args = [config.sidecarScript, "--cwd", launch.cwd]
        if let claude = config.claudePath { args += ["--claude", claude] }
        if let resume = launch.resume { args += ["--resume", resume] }
        return args
    }

    static func start(
        config: AgentSDKSpikeConfig, launch: AgentSDKSidecarLaunch
    ) throws -> (AgentSDKSidecarHandle, AsyncStream<AgentSDKSidecarOutput>) {
        // Normally already ignored by SocketServer.start, but a dev crowd that
        // skips the socket (another instance holds it) never calls that. A
        // write to a dead sidecar must throw EPIPE, not kill crowd.
        _ = signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.nodePath)
        process.arguments = arguments(config: config, launch: launch)
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        // The login-shell PATH, so the SDK finds what the terminal agent finds.
        process.environment = ShellEnvironment.shared.env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        let sidecar = AgentSDKProcessSidecar(process: process, stdin: inPipe.fileHandleForWriting)

        let (stream, continuation) = AsyncStream<AgentSDKSidecarOutput>.makeStream()
        let tag = "[AgentSDKSpike] \(launch.sessionID.uuidString.prefix(8))"
        let splitter = AgentSDKLineSplitter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                if let rest = splitter.flush() { continuation.yield(.line(rest)) }
                continuation.yield(.exit(sidecar.waitForExit()))
                continuation.finish()
                return
            }
            for line in splitter.feed(chunk) { continuation.yield(.line(line)) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            if let s = String(data: chunk, encoding: .utf8) {
                CrowLog.info("\(tag) stderr: \(s.prefix(500))")
            }
        }
        try process.run()
        CrowLog.info("\(tag) started sidecar pid \(process.processIdentifier) in \(launch.cwd)")
        return (sidecar, stream)
    }

    fileprivate func waitForExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    func send(_ line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        // SIGPIPE is ignored daemon-wide (SocketServer.start), so a dead child
        // surfaces here as a thrown EPIPE rather than killing crowd.
        try stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        lock.lock()
        try? stdin.close()
        lock.unlock()
        // The sidecar exits on stdin EOF; this is the backstop.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            if process.isRunning { process.terminate() }
        }
    }
}
