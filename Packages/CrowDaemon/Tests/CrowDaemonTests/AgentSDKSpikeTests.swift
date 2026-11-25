import CrowCore
import CrowEngine
import CrowIPC
import Foundation
import Testing

@testable import CrowDaemon

/// The Agent SDK chat spike (CROW-1524, ADR 0033): crowd's half. A fake
/// launcher stands in for `node sidecar.mjs`, so nothing is spawned and no
/// model is called (ADR 0012). The sidecar itself is tested with `node --test`
/// in `spikes/agent-sdk-sidecar/`.
@Suite("Agent SDK spike")
struct AgentSDKSpikeTests {

    // MARK: - Fakes

    /// One fake sidecar: records what crowd writes, and lets the test speak for it.
    final class FakeSidecar: AgentSDKSidecarHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [String] = []
        private var _stopped = false
        let launch: AgentSDKSidecarLaunch
        let output: AsyncStream<AgentSDKSidecarOutput>.Continuation
        let onWait: @Sendable () -> Void

        init(launch: AgentSDKSidecarLaunch, output: AsyncStream<AgentSDKSidecarOutput>.Continuation,
             onWait: @escaping @Sendable () -> Void = {}) {
            self.launch = launch
            self.output = output
            self.onWait = onWait
        }

        var sent: [[String: JSONValue]] {
            lock.withLock { _sent }.compactMap {
                (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?.objectValue
            }
        }
        var stopped: Bool { lock.withLock { _stopped } }

        func send(_ line: String) throws { lock.withLock { _sent.append(line) } }
        func stop() { lock.withLock { _stopped = true } }
        func waitForExit(timeout: Duration) async { onWait() }

        func say(_ json: String) { output.yield(.line(json)) }
        func exit(_ status: Int32) { output.yield(.exit(status)); output.finish() }
    }

    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [FakeSidecar] = []
        private var _log: [String] = []
        var all: [FakeSidecar] { lock.withLock { _all } }
        var last: FakeSidecar? { all.last }
        /// "launch N" / "wait N", in order (N counts launches from 1).
        var log: [String] { lock.withLock { _log } }

        var launcher: AgentSDKSidecarLauncher {
            { [self] launch in
                let (stream, cont) = AsyncStream<AgentSDKSidecarOutput>.makeStream()
                let n = lock.withLock { _all.count + 1 }
                let fake = FakeSidecar(launch: launch, output: cont, onWait: { [self] in
                    lock.withLock { _log.append("wait \(n)") }
                })
                lock.withLock { _all.append(fake); _log.append("launch \(n)") }
                return (fake, stream)
            }
        }
    }

    actor Frames {
        var all: [String] = []
        func add(_ f: String) { all.append(f) }
    }

    static let config = AgentSDKSpikeConfig(
        sidecarScript: "/spike/sidecar.mjs", nodePath: "/usr/bin/node", claudePath: "/bin/claude")

    private func make(enabled: Bool = true) -> (AgentSDKSpike, Launches, Frames) {
        let launches = Launches()
        let frames = Frames()
        let spike = AgentSDKSpike(
            config: enabled ? Self.config : nil,
            launcher: launches.launcher,
            push: { await frames.add($0) })
        return (spike, launches, frames)
    }

    /// Wait (bounded) for the spike's consumer task to catch up.
    private func until(_ what: String = "condition", _ pred: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await pred() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func kinds(_ events: [JSONValue]) -> [String] {
        events.compactMap { $0.objectValue?["kind"]?.stringValue }
    }

    // MARK: - Config

    @Test("Off unless the env var names a sidecar that exists")
    func configResolution() {
        let none = AgentSDKSpikeConfig.resolve(env: [:], findExecutable: { _ in "/x" })
        #expect(none.config == nil && none.problem == nil)

        let missing = AgentSDKSpikeConfig.resolve(
            env: ["CROW_AGENT_SDK_SPIKE": "/spike"], findExecutable: { _ in "/x" }, fileExists: { _ in false })
        #expect(missing.config == nil)
        #expect(missing.problem?.contains("/spike/sidecar.mjs") == true)

        let noNode = AgentSDKSpikeConfig.resolve(
            env: ["CROW_AGENT_SDK_SPIKE": "/spike"], findExecutable: { _ in nil }, fileExists: { _ in true })
        #expect(noNode.config == nil)
        #expect(noNode.problem?.contains("node") == true)

        let ok = AgentSDKSpikeConfig.resolve(
            env: ["CROW_AGENT_SDK_SPIKE": " /spike ", "CROW_AGENT_SDK_NODE": "/opt/node"],
            findExecutable: { $0 == "claude" ? "/bin/claude" : nil }, fileExists: { _ in true })
        #expect(ok.config == AgentSDKSpikeConfig(
            sidecarScript: "/spike/sidecar.mjs", nodePath: "/opt/node", claudePath: "/bin/claude"))

        let script = AgentSDKSpikeConfig.resolve(
            env: ["CROW_AGENT_SDK_SPIKE": "/elsewhere/run.mjs"], findExecutable: { _ in "/n" }, fileExists: { _ in true })
        #expect(script.config?.sidecarScript == "/elsewhere/run.mjs")

        // No `claude` on PATH: only on when the SDK's own binary is installed.
        let nodeOnly: (String) -> String? = { $0 == "node" ? "/n" : nil }
        let neither = AgentSDKSpikeConfig.resolve(
            env: ["CROW_AGENT_SDK_SPIKE": "/spike"], findExecutable: nodeOnly, fileExists: { _ in true },
            listDirectory: { _ in ["claude-agent-sdk", "sdk"] })
        #expect(neither.config == nil)
        #expect(neither.problem?.contains("no `claude`") == true)
        var listed: [String] = []
        let bundled = AgentSDKSpikeConfig.resolve(
            env: ["CROW_AGENT_SDK_SPIKE": "/spike"], findExecutable: nodeOnly, fileExists: { _ in true },
            listDirectory: { listed.append($0); return ["claude-agent-sdk", "claude-agent-sdk-darwin-arm64"] })
        #expect(bundled.config?.claudePath == nil && bundled.config?.nodePath == "/n")
        #expect(listed == ["/spike/node_modules/@anthropic-ai"])
    }

    @Test("Sidecar arguments carry the cwd, the operator's claude and a resume id")
    func arguments() {
        let id = UUID()
        #expect(AgentSDKProcessSidecar.arguments(
            config: Self.config, launch: AgentSDKSidecarLaunch(sessionID: id, cwd: "/w", resume: nil))
            == ["/spike/sidecar.mjs", "--cwd", "/w", "--claude", "/bin/claude"])
        var bundled = Self.config
        bundled.claudePath = nil
        #expect(AgentSDKProcessSidecar.arguments(
            config: bundled, launch: AgentSDKSidecarLaunch(sessionID: id, cwd: "/w", resume: "abc"))
            == ["/spike/sidecar.mjs", "--cwd", "/w", "--resume", "abc"])
    }

    @Test("Stdout is split into whole lines across chunks")
    func lineSplitter() {
        let s = AgentSDKLineSplitter()
        #expect(s.feed(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(s.feed(Data(":2}\n\n".utf8)) == ["{\"b\":2}"])
        #expect(s.feed(Data("tail".utf8)).isEmpty)
        #expect(s.flush() == "tail")
        #expect(s.flush() == nil)
    }

    // MARK: - Conversation

    @Test("A message starts the sidecar, and its events are numbered, kept and pushed in order")
    func messageAndEvents() async throws {
        let (spike, launches, frames) = make()
        let session = UUID()
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("hi")])

        let fake = try #require(launches.last)
        #expect(fake.launch == AgentSDKSidecarLaunch(sessionID: session, cwd: "/w", resume: nil))
        #expect(fake.sent == [["op": .string("message"), "text": .string("hi")]])

        fake.say(#"{"kind":"user","text":"hi"}"#)
        fake.say(#"{"kind":"ready","sdk_session_id":"sdk-1"}"#)
        fake.say(#"{"kind":"delta","text":"Hel"}"#)
        fake.say("not json")
        fake.say(#"{"kind":"assistant","text":"Hello"}"#)
        // The delta and the bad line take no seq: three kept events.
        try await until("3 events") { await spike.page(session: session, after: nil).cursor == 3 }
        // Frames are pushed by a separate task; the delta's frame counts too.
        try await until("4 frames") { await frames.all.count == 4 }

        let page = await spike.page(session: session, after: nil)
        #expect(kinds(page.events) == ["user", "ready", "assistant"])
        #expect(page.events.compactMap { AgentSDKSpike.seq(of: $0) } == [1, 2, 3])
        #expect(page.running)
        #expect(page.sdkSessionID == "sdk-1")
        #expect(page.reset)

        // The delta is pushed (tagged with the seq it follows) but never kept.
        let pushed = await frames.all
        #expect(pushed.allSatisfy { $0.contains(#""method":"sdk-chat-event""#) })
        #expect(pushed.allSatisfy { $0.contains(session.uuidString) })
        #expect(pushed[2].contains(#""kind":"delta""#) && pushed[2].contains(#""seq":2"#))
        #expect(pushed[3].contains(#""kind":"assistant""#))

        let after = await spike.page(session: session, after: 2)
        #expect(kinds(after.events) == ["assistant"])
        #expect(!after.reset)
    }

    @Test("Answers go only to requests that are still waiting")
    func respondNeedsAPendingRequest() async throws {
        let (spike, launches, _) = make()
        let session = UUID()
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("go")])
        let fake = try #require(launches.last)
        fake.say(#"{"kind":"permission","request_id":"r1","tool_name":"Bash","text":"ls"}"#)
        fake.say(#"{"kind":"question","request_id":"r2","questions":[]}"#)
        try await until("2 pending") { await spike.page(session: session, after: nil).pending == ["r1", "r2"] }

        await #expect(throws: AgentSDKSpikeError.notPending("r9")) {
            try await spike.input(session: session, cwd: "/w", command: [
                "op": .string("respond"), "request_id": .string("r9"), "behavior": .string("allow")])
        }
        await #expect(throws: AgentSDKSpikeError.badCommand("behavior must be allow or deny")) {
            try await spike.input(session: session, cwd: "/w", command: [
                "op": .string("respond"), "request_id": .string("r1"), "behavior": .string("maybe")])
        }
        try await spike.input(session: session, cwd: "/w", command: [
            "op": .string("respond"), "request_id": .string("r2"), "behavior": .string("allow"),
            "answers": .object(["Which?": .string("Red")])])
        #expect(fake.sent.last == [
            "op": .string("respond"), "request_id": .string("r2"), "behavior": .string("allow"),
            "answers": .object(["Which?": .string("Red")])])

        fake.say(#"{"kind":"resolved","request_id":"r2","behavior":"allow"}"#)
        try await until("r2 resolved") { await spike.page(session: session, after: nil).pending == ["r1"] }

        // A sidecar complaint is kept as an error notice.
        fake.say(#"{"kind":"command_error","op":"respond","text":"unanswered: Which?"}"#)
        try await until("notice") {
            await kinds(spike.page(session: session, after: nil).events).last == "notice"
        }
        let last = await spike.page(session: session, after: nil).events.last?.objectValue
        #expect(last?["is_error"] == .bool(true))
    }

    @Test("Exit stops the conversation; the next message resumes the same SDK session")
    func exitAndResume() async throws {
        let (spike, launches, _) = make()
        let session = UUID()
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("one")])
        let first = try #require(launches.last)
        first.say(#"{"kind":"ready","sdk_session_id":"sdk-7"}"#)
        first.say(#"{"kind":"permission","request_id":"r1","tool_name":"Write"}"#)
        first.exit(1)
        try await until("stopped") { await !spike.page(session: session, after: nil).running }

        let page = await spike.page(session: session, after: nil)
        #expect(kinds(page.events) == ["ready", "permission", "stopped"])
        #expect(page.events.last?.objectValue?["status"] == .int(1))
        #expect(page.pending.isEmpty)
        await #expect(throws: AgentSDKSpikeError.notRunning) {
            try await spike.input(session: session, cwd: "/w", command: ["op": .string("interrupt")])
        }

        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("two")])
        let second = try #require(launches.last)
        #expect(launches.all.count == 2)
        #expect(second.launch.resume == "sdk-7")
        #expect(launches.log == ["launch 1", "launch 2"]) // it already exited: nothing to wait for
        // Late output from the dead sidecar can't land in the new log.
        await spike.ingest(session: session, generation: 1, line: #"{"kind":"assistant","text":"ghost"}"#)
        let resumed = await spike.page(session: session, after: nil)
        #expect(kinds(resumed.events).last == "notice")
        #expect(resumed.running)
    }

    @Test("Stop closes the sidecar; interrupt is forwarded")
    func stopAndInterrupt() async throws {
        let (spike, launches, _) = make()
        let session = UUID()
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("x")])
        let fake = try #require(launches.last)
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("interrupt")])
        #expect(fake.sent.last == ["op": .string("interrupt")])
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("stop")])
        #expect(fake.stopped)
        #expect(await kinds(spike.page(session: session, after: nil).events) == ["stopped"])
        await #expect(throws: AgentSDKSpikeError.notRunning) {
            try await spike.input(session: session, cwd: "/w", command: ["op": .string("stop")])
        }
    }

    @Test("End invalidates the old sidecar at once: no stale answer reaches its successor")
    func endThenRestart() async throws {
        let (spike, launches, _) = make()
        let session = UUID()
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("one")])
        let first = try #require(launches.last)
        first.say(#"{"kind":"ready","sdk_session_id":"sdk-3"}"#)
        first.say(#"{"kind":"permission","request_id":"aaaa-1","tool_name":"Bash","text":"rm -rf build"}"#)
        try await until("pending") { await spike.page(session: session, after: nil).pending == ["aaaa-1"] }

        // End while the approval is waiting: closed now, not when the process exits.
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("stop")])
        #expect(first.stopped)
        let ended = await spike.page(session: session, after: nil)
        #expect(!ended.running)
        #expect(ended.pending.isEmpty)
        #expect(kinds(ended.events).last == "stopped")
        #expect(ended.events.last?.objectValue?["reason"] == .string("ended"))

        // A message before the old process has gone: crowd waits for it to
        // exit, then starts a new sidecar that resumes the same SDK session.
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("two")])
        let second = try #require(launches.last)
        #expect(launches.all.count == 2 && second.launch.resume == "sdk-3")
        #expect(launches.log == ["launch 1", "wait 1", "launch 2"])
        second.say(#"{"kind":"permission","request_id":"bbbb-1","tool_name":"Write","text":"/w/x"}"#)
        try await until("new pending") { await spike.page(session: session, after: nil).pending == ["bbbb-1"] }

        // The stale card's answer is refused; the old sidecar's late output is dropped.
        await #expect(throws: AgentSDKSpikeError.notPending("aaaa-1")) {
            try await spike.input(session: session, cwd: "/w", command: [
                "op": .string("respond"), "request_id": .string("aaaa-1"), "behavior": .string("allow")])
        }
        #expect(second.sent.count == 1) // only the message reached the new sidecar
        let before = await spike.page(session: session, after: nil).cursor
        first.say(#"{"kind":"resolved","request_id":"aaaa-1","behavior":"cancelled"}"#)
        first.exit(0)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await spike.page(session: session, after: nil)
        #expect(after.cursor == before)
        #expect(after.running && after.pending == ["bbbb-1"])
    }

    @Test("Sidecars of closed sessions are stopped, and gone sessions forgotten")
    func prune() async throws {
        let (spike, launches, _) = make()
        let keep = UUID(), closed = UUID(), gone = UUID()
        for id in [keep, closed, gone] {
            try await spike.input(session: id, cwd: "/w", command: ["op": .string("message"), "text": .string("x")])
        }
        await spike.prune(running: [keep], existing: [keep, closed])
        #expect(launches.all.map(\.stopped) == [false, true, true])
        #expect(await spike.page(session: keep, after: nil).running)
        let closedPage = await spike.page(session: closed, after: nil)
        #expect(!closedPage.running)
        #expect(closedPage.events.last?.objectValue?["reason"] == .string("session closed"))
        // The deleted session's log goes with its sidecar; the closed one's stays.
        await spike.prune(running: [keep], existing: [keep, closed])
        #expect(await spike.page(session: gone, after: nil).events.isEmpty)
        #expect(await !spike.page(session: closed, after: nil).events.isEmpty)
    }

    @Test("Bad commands and a disabled spike are refused without launching")
    func refusals() async throws {
        let (off, offLaunches, _) = make(enabled: false)
        #expect(await off.enabled == false)
        await #expect(throws: AgentSDKSpikeError.self) {
            try await off.input(session: UUID(), cwd: "/w", command: ["op": .string("message"), "text": .string("x")])
        }
        #expect(offLaunches.all.isEmpty)

        let (spike, launches, _) = make()
        await #expect(throws: AgentSDKSpikeError.badCommand("text required")) {
            try await spike.input(session: UUID(), cwd: "/w", command: ["op": .string("message"), "text": .string("  ")])
        }
        await #expect(throws: AgentSDKSpikeError.badCommand("unknown op nope")) {
            try await spike.input(session: UUID(), cwd: "/w", command: ["op": .string("nope")])
        }
        await #expect(throws: AgentSDKSpikeError.notRunning) {
            try await spike.input(session: UUID(), cwd: "/w", command: [
                "op": .string("respond"), "request_id": .string("r1"), "behavior": .string("allow")])
        }
        #expect(launches.all.isEmpty)
    }

    @Test("A cursor the log no longer covers resets the page")
    func cursorBeyondTheLog() async throws {
        let (spike, launches, _) = make()
        let session = UUID()
        try await spike.input(session: session, cwd: "/w", command: ["op": .string("message"), "text": .string("x")])
        let fake = try #require(launches.last)
        fake.say(#"{"kind":"user","text":"x"}"#)
        try await until("1 event") { await spike.page(session: session, after: nil).cursor == 1 }
        // A crowd restart: the browser's cursor is ahead of the (new) log.
        let ahead = await spike.page(session: session, after: 40)
        #expect(ahead.reset)
        #expect(ahead.events.count == 1)
        let caughtUp = await spike.page(session: session, after: 1)
        #expect(!caughtUp.reset && caughtUp.events.isEmpty)
        let unknown = await spike.page(session: UUID(), after: nil)
        #expect(unknown.events.isEmpty && unknown.cursor == 0 && !unknown.running)
    }

    // MARK: - The real process

    /// `AgentSDKProcessSidecar` with `/bin/sh` standing in for node: arguments,
    /// cwd, stdin → stdout lines, a last line without a newline, and the exit
    /// arriving after every line.
    @Test("The process sidecar round-trips lines and reports its exit last")
    func processRoundTrip() async throws {
        let dir = NSTemporaryDirectory() + "crow-sdk-proc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/fake-sidecar.sh"
        try """
        echo "{\\"kind\\":\\"args\\",\\"argv\\":\\"$*\\",\\"pwd\\":\\"$(pwd -P)\\"}"
        IFS= read -r line; echo "{\\"kind\\":\\"echo\\",\\"len\\":${#line}}"
        printf '{"kind":"bye"}'
        exit 3
        """.write(toFile: script, atomically: true, encoding: .utf8)

        let config = AgentSDKSpikeConfig(sidecarScript: script, nodePath: "/bin/sh", claudePath: "/bin/claude")
        let (handle, output) = try AgentSDKProcessSidecar.start(
            config: config, launch: AgentSDKSidecarLaunch(sessionID: UUID(), cwd: dir, resume: "abc"))
        let message = #"{"op":"message","text":"hi"}"#
        try handle.send(message)

        var got: [AgentSDKSidecarOutput] = []
        for await item in output { got.append(item) }
        // `pwd -P` resolves /var → /private/var; the unique leaf is enough.
        let leaf = (dir as NSString).lastPathComponent
        #expect(got.count == 4)
        if case .line(let first)? = got.first {
            #expect(first.contains("--cwd \(dir) --claude /bin/claude --resume abc"))
            #expect(first.contains("/\(leaf)\"}"))
        } else {
            Issue.record("first output was not a line: \(got)")
        }
        #expect(got.dropFirst().first == .line(#"{"kind":"echo","len":\#(message.count)}"#))
        #expect(got.dropFirst(2).first == .line(#"{"kind":"bye"}"#))
        #expect(got.last == .exit(3))
        // The child exited on its own: a write now is EPIPE, thrown, not a SIGPIPE.
        #expect(throws: (any Error).self) { try handle.send("late") }
    }

    @Test("A sidecar that won't exit is terminated after the wait")
    func waitForExitTerminates() async throws {
        let dir = NSTemporaryDirectory() + "crow-sdk-hang-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/hang.sh"
        try "trap '' HUP; sleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        let config = AgentSDKSpikeConfig(sidecarScript: script, nodePath: "/bin/sh", claudePath: nil)
        let (handle, output) = try AgentSDKProcessSidecar.start(
            config: config, launch: AgentSDKSidecarLaunch(sessionID: UUID(), cwd: dir, resume: nil))
        let started = ContinuousClock.now
        await handle.waitForExit(timeout: .milliseconds(200))
        #expect(ContinuousClock.now - started < .seconds(5))
        var last: AgentSDKSidecarOutput?
        for await item in output { last = item }
        #expect(last == .exit(SIGTERM))
    }

    /// One real turn: node + `spikes/agent-sdk-sidecar` + the Agent SDK + the
    /// operator's `claude`, driven through `AgentSDKSpike` exactly as the RPCs
    /// drive it. Calls the model (a few cents), so it only runs when asked:
    ///
    ///     CROW_LIVE_AGENT_SDK=1 swift test --package-path Packages/CrowDaemon --filter AgentSDKSpike
    ///
    /// Needs `npm install --omit=optional` in the sidecar directory first, and
    /// whatever auth `claude` resolves (a gateway via ANTHROPIC_BASE_URL works).
    @Test("Live: a turn streams, asks a question and an approval, and ends",
          .enabled(if: ProcessInfo.processInfo.environment["CROW_LIVE_AGENT_SDK"] == "1"))
    func liveTurn() async throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let env = ProcessInfo.processInfo.environment.merging(
            ["CROW_AGENT_SDK_SPIKE": repo.appendingPathComponent("spikes/agent-sdk-sidecar").path]) { _, new in new }
        let config = try #require(AgentSDKSpikeConfig.resolve(
            env: env, findExecutable: { ShellEnvironment.shared.findExecutable($0) }).config)
        let cwd = NSTemporaryDirectory() + "crow-sdk-live-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let frames = Frames()
        let spike = AgentSDKSpike(
            config: config, launcher: AgentSDKProcessSidecar.launcher(config: config), push: { await frames.add($0) })
        let session = UUID()
        try await spike.input(session: session, cwd: cwd, command: ["op": .string("message"), "text": .string("""
            This is a test of a tool approval flow. First use the AskUserQuestion tool to ask me one question, \
            "Which color?", with exactly two options, "red" and "blue". Then use the Write tool to create \
            color.txt in the current directory containing just the color I picked. Finish with one short sentence.
            """)])

        var answered: Set<String> = []
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let page = await spike.page(session: session, after: nil)
            if kinds(page.events).contains("turn_end") || !page.running { break }
            for event in page.events {
                guard let o = event.objectValue, let id = o["request_id"]?.stringValue,
                      page.pending.contains(id), !answered.contains(id) else { continue }
                var cmd: [String: JSONValue] = [
                    "op": .string("respond"), "request_id": .string(id), "behavior": .string("allow")]
                if o["kind"]?.stringValue == "question", case .array(let qs)? = o["questions"] {
                    var answers: [String: JSONValue] = [:]
                    for q in qs {
                        guard let text = q.objectValue?["question"]?.stringValue,
                              let label = q.objectValue?["options"]?.arrayValue?.first?.objectValue?["label"]
                        else { continue }
                        answers[text] = label
                    }
                    cmd["answers"] = .object(answers)
                }
                try await spike.input(session: session, cwd: cwd, command: cmd)
                answered.insert(id)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let seen = kinds(await spike.page(session: session, after: nil).events)
        #expect(seen.contains("ready"))
        #expect(seen.contains("question"))
        #expect(seen.contains("permission"))
        #expect(seen.contains("turn_end"))
        #expect(await frames.all.contains { $0.contains(#""kind":"delta""#) })
        let written = try? String(contentsOfFile: cwd + "/color.txt", encoding: .utf8)
        #expect(written?.trimmingCharacters(in: .whitespacesAndNewlines) == "red")
        try await spike.input(session: session, cwd: cwd, command: ["op": .string("stop")])
    }

    // MARK: - RPCs

    @MainActor
    private func addSession(_ appState: AppState, kind: SessionKind = .work, agent: AgentKind = .claudeCode,
                            dir: String) -> Session {
        let session = Session(name: "sdk-\(kind.rawValue)", kind: kind, agentKind: agent)
        appState.sessions.append(session)
        appState.worktrees[session.id] = [
            SessionWorktree(sessionID: session.id, repoName: "repo", repoPath: dir,
                            worktreePath: dir, branch: "feature/x", isPrimary: true),
        ]
        return session
    }

    @Test("The RPCs say when the spike is off, and run only in Claude work sessions")
    @MainActor
    func rpcs() async throws {
        let tmp = NSTemporaryDirectory() + "crow-sdk-spike-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let appState = AppState()
        let work = addSession(appState, dir: tmp)
        let review = addSession(appState, kind: .review, dir: tmp)
        let codex = addSession(appState, agent: .codex, dir: tmp)

        let off = CommandRouter(handlers: makeAgentSDKSpikeHandlers(appState: appState, spike: nil))
        let offEvents = await off.handle(request: JSONRPCRequest(id: 1, method: "get-sdk-chat-events", params: [:]))
        #expect(offEvents.result?["enabled"] == .bool(false))
        let offInput = await off.handle(request: JSONRPCRequest(id: 2, method: "sdk-chat-input", params: [
            "session_id": .string(work.id.uuidString), "op": .string("message"), "text": .string("x")]))
        #expect(offInput.error?.message.contains("CROW_AGENT_SDK_SPIKE") == true)

        let (spike, launches, _) = make()
        let on = CommandRouter(handlers: makeAgentSDKSpikeHandlers(appState: appState, spike: spike))
        let probe = await on.handle(request: JSONRPCRequest(id: 3, method: "get-sdk-chat-events", params: [:]))
        #expect(probe.result == ["enabled": .bool(true)])

        for (session, why) in [(review, "review"), (codex, "Claude")] {
            let r = await on.handle(request: JSONRPCRequest(id: 4, method: "sdk-chat-input", params: [
                "session_id": .string(session.id.uuidString), "op": .string("message"), "text": .string("x")]))
            #expect(r.error?.message.contains(why) == true)
        }
        #expect(launches.all.isEmpty)

        let sent = await on.handle(request: JSONRPCRequest(id: 5, method: "sdk-chat-input", params: [
            "session_id": .string(work.id.uuidString), "op": .string("message"), "text": .string("hello")]))
        #expect(sent.result == ["ok": .bool(true)])
        #expect(launches.last?.launch.cwd == tmp)

        let bad = await on.handle(request: JSONRPCRequest(id: 6, method: "sdk-chat-input", params: [
            "session_id": .string(work.id.uuidString), "op": .string("bogus")]))
        #expect(bad.error?.code == RPCErrorCode.invalidParams)

        let page = await on.handle(request: JSONRPCRequest(id: 7, method: "get-sdk-chat-events", params: [
            "session_id": .string(work.id.uuidString)]))
        #expect(page.result?["enabled"] == .bool(true))
        #expect(page.result?["running"] == .bool(true))
    }
}
