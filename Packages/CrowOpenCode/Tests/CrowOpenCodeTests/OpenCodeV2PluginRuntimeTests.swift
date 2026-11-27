import Foundation
import Testing
@testable import CrowOpenCode
@testable import CrowCore

/// The `node` binary for the V2 plugin runtime tests, or nil to skip them.
private let openCodeTestNodePath: String? = {
    let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/node" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}()

/// Runs the generated **V2** plugin under Node against a fake OpenCode 2
/// `ctx` and a fake `crow`, so the JS logic — child filtering, the
/// `superseded`/`shutdown` skips, the reload-safe parent lookup and the
/// fail-closed path — is exercised, not just string-matched (CROW-1332).
///
/// The fake `ctx` mirrors the v2.0.32 shapes the plugin depends on:
/// `{ type, data }` event payloads from `ctx.event.subscribe({ signal })`,
/// `ctx.session.get({ sessionID })` returning the session info, and
/// `ctx.tool.hook(name, fn)` — plus the v2.3.2 `ctx.session.hook(name, fn)`
/// (CROW-1464). An entry `{ hook: "<name>", data }` in the event list runs that
/// session hook between bus events, the way upstream runs `experimental.idle`
/// inside the drain before it publishes `session.execution.succeeded`.
/// Skipped when no `node` is installed.
@Suite("OpenCode V2 plugin runtime", .enabled(if: openCodeTestNodePath != nil))
struct OpenCodeV2PluginRuntimeTests {

    /// How the fake `ctx.session.hook` behaves.
    enum SessionHookAPI {
        /// Registers the callback (OpenCode ≥ 2.2.1).
        case available
        /// `ctx.session.hook` is absent.
        case missing
        /// Registration rejects (an unknown or renamed hook name).
        case throwing
    }

    /// Run the plugin with `events` (JS array literal of `{type, data}`),
    /// optional `sessions` (JS object: id → info for `session.get`), and an
    /// optional `ctxOverride` JS expression replacing the whole ctx. Returns
    /// the `--event` names the fake `crow` received, in order.
    private func run(
        events: String,
        sessions: String = "{}",
        ctxOverride: String? = nil,
        sessionID: UUID? = UUID(),
        exerciseToolHooks: Bool = false,
        sessionHookAPI: SessionHookAPI = .available
    ) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-oc2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("crow.log").path
        let crow = dir.appendingPathComponent("crow").path
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = "--event" ]; then echo "$2" >> \(OpenCodeLaunchArgs.shellQuote(log)); fi
          shift
        done
        cat > /dev/null
        """.write(toFile: crow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crow)

        // `.mjs` so Node treats the generated ESM as a module without a
        // package.json; OpenCode itself loads the same text from `.js`.
        let plugin = dir.appendingPathComponent("crow-hooks.mjs")
        try OpenCodeHookConfigWriter.pluginSource(
            crowPath: crow, sessionID: sessionID, generation: .v2
        ).write(to: plugin, atomically: true, encoding: .utf8)

        let harness = dir.appendingPathComponent("harness.mjs")
        let sessionHook: String
        switch sessionHookAPI {
        case .available: sessionHook = "async hook(name, fn) { SESSION_HOOKS[name] = fn; },"
        case .missing: sessionHook = ""
        case .throwing: sessionHook = "async hook(name) { throw new Error(\"unknown hook \" + name); },"
        }
        let ctx = ctxOverride ?? """
        {
          location: { directory: \(jsString(dir.path)) },
          event: {
            subscribe({ signal }) {
              return (async function* () {
                for (const e of EVENTS) {
                  // A session hook runs between bus events. The consumer has
                  // handled every earlier event by now (for-await awaits it).
                  if (e.hook) {
                    if (SESSION_HOOKS[e.hook]) await SESSION_HOOKS[e.hook](e.data);
                    continue;
                  }
                  yield e;
                  await new Promise((r) => setTimeout(r, 5));
                }
              })();
            },
          },
          session: {
            async get({ sessionID }) {
              if (!(sessionID in SESSIONS)) throw new Error("not found");
              return SESSIONS[sessionID];
            },
            \(sessionHook)
          },
          tool: { async hook(name, fn) { HOOKS[name] = fn; } },
        }
        """
        try """
        import plugin from \(jsString(plugin.path));
        const EVENTS = \(events);
        const SESSIONS = \(sessions);
        const HOOKS = {};
        const SESSION_HOOKS = {};
        // Every scenario ends with `BridgeUnavailable` (the fake stream ends,
        // or the API is missing), so wait for that line — deterministic even
        // when the suite's parallel spawns are slow — then for the tool hooks.
        const { readFileSync } = await import("node:fs");
        const lines = () => {
          try { return readFileSync(\(jsString(log)), "utf8").split("\\n").filter(Boolean); }
          catch (_) { return []; }
        };
        async function until(pred) {
          for (let i = 0; i < 400 && !pred(lines()); i++) await new Promise((r) => setTimeout(r, 25));
        }
        const cleanup = await plugin.setup(\(ctx));
        await until((l) => l.includes("BridgeUnavailable"));
        if (\(exerciseToolHooks) && HOOKS["execute.before"]) await HOOKS["execute.before"]({ tool: "bash" });
        if (\(exerciseToolHooks) && HOOKS["execute.after"]) await HOOKS["execute.after"]({ tool: "bash" });
        if (typeof cleanup === "function") cleanup();
        """.write(to: harness, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(openCodeTestNodePath))
        process.arguments = [harness.path]
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "node failed: \(err)")

        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Fold the emitted events through `OpenCodeSignalSource` from `.idle`,
    /// stopping at the trailing `BridgeUnavailable` (the fake stream ending),
    /// and return the card's activity state at that point.
    private func cardState(after names: [String]) -> AgentActivityState {
        let source = OpenCodeSignalSource()
        var state = AgentActivityState.idle
        for name in names {
            if name == "BridgeUnavailable" { break }
            let t = source.transition(
                for: AgentHookEvent(sessionID: UUID(), eventName: name, summary: name),
                currentActivityState: state,
                currentNotificationType: nil,
                currentLastTopLevelStopAt: nil)
            if let next = t.newActivityState { state = next }
        }
        return state
    }

    private func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @Test func rootTurnMapsToStartPromptStopAndToolHooks() throws {
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "permission.asked", data: { sessionID: "ses_root" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """, exerciseToolHooks: true)
        // The event stream then ends on its own — that is the fail-closed edge,
        // so it trails the turn.
        #expect(names.prefix(4) == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"])
        // Then the stream ends (fail-closed signal), then the tool hooks run.
        #expect(names.suffix(3) == ["BridgeUnavailable", "PreToolUse", "PostToolUse"])
    }

    @Test func childSessionNeverMovesTheParentCard() throws {
        // CROW-1082 on V2: the subagent finishes first; only the root's end
        // may emit Stop, and the child never re-announces SessionStart.
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_child" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(names.filter { $0 == "SessionStart" }.count == 1)
        #expect(names.filter { $0 == "UserPromptSubmit" }.count == 1)
        #expect(names.filter { $0 == "Stop" }.count == 1)
    }

    @Test func childCreatedBeforeReloadIsResolvedViaSessionGet() throws {
        // Crow rewrites the plugin on every launch and V2 reloads it, so a
        // child can predate this instance. `session.get` supplies the parent.
        let names = try run(
            events: """
            [
              { type: "session.execution.started", data: { sessionID: "ses_child" } },
              { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
              { type: "session.execution.started", data: { sessionID: "ses_root" } },
              { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
            ]
            """,
            sessions: """
            { ses_child: { id: "ses_child", parentID: "ses_root" }, ses_root: { id: "ses_root" } }
            """)
        #expect(names.prefix(2) == ["UserPromptSubmit", "Stop"])
        #expect(names.filter { $0 == "Stop" }.count == 1)
    }

    @Test func supersededAndShutdownInterruptionsAreNotDone() throws {
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.execution.interrupted", data: { sessionID: "ses_root", reason: "superseded" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.execution.interrupted", data: { sessionID: "ses_root", reason: "shutdown" } },
          { type: "session.execution.interrupted", data: { sessionID: "ses_root", reason: "user" } },
        ]
        """)
        // Exactly one Stop — from the `user` interruption.
        #expect(names.filter { $0 == "Stop" }.count == 1)
        #expect(names.firstIndex(of: "Stop") == names.lastIndex(of: "UserPromptSubmit").map { $0 + 1 })
    }

    @Test func endedEventStreamFailsClosedWithoutStop() throws {
        // The fake stream ends without Crow aborting it: the plugin must say
        // the bridge is gone, and must not claim the turn is done.
        let names = try run(events: "[]")
        #expect(names == ["BridgeUnavailable"])
    }

    @Test func missingEventApiFailsClosed() throws {
        let names = try run(events: "[]", ctxOverride: "{ location: { directory: \"/tmp\" } }")
        #expect(names == ["BridgeUnavailable"])
        #expect(!names.contains("Stop"))
    }

    // MARK: - Background subagents (CROW-1464, OpenCode ≥ 2.3.0)

    /// A background subagent the root is still waiting on, as
    /// `experimental.idle` lists it.
    private let subagentWork = """
    { kind: "subagent", sessionID: "ses_root", childSessionID: "ses_child", agent: "general", description: "survey" }
    """

    /// The opening of a 2.3.0 turn that delegates: the subagent tool returns at
    /// once, so the root goes idle while the child is still working.
    private var rootEndsWhileSubagentRuns: String {
        """
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_child" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [\(subagentWork)] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        """
    }

    @Test func rootExecutionEndWithOutstandingSubagentIsNotDone() throws {
        // The ticket's pin: the root's execution ends, its subagent is still
        // running, so the card must not reach `.done` (for a job, `.done` is
        // completion — ADR 0015).
        let names = try run(events: "[\(rootEndsWhileSubagentRuns)]")
        #expect(!names.contains("Stop"))
        #expect(cardState(after: names) == .working)
        #expect(cardState(after: names) != .done)
    }

    @Test func subagentReportWakesRootAndOnlyThatEndingIsDone() throws {
        // The child finishes; its report wakes the root for a new execution,
        // which ends with nothing outstanding. That ending is the one `Stop`.
        let names = try run(events: """
        [
        \(rootEndsWhileSubagentRuns)
          { hook: "experimental.idle", data: { sessionID: "ses_child", background: [] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(Array(names.prefix(4)) == ["SessionStart", "UserPromptSubmit", "UserPromptSubmit", "Stop"])
        #expect(names.filter { $0 == "Stop" }.count == 1)
        #expect(cardState(after: names) == .done)
    }

    @Test func backgroundShellDoesNotHoldDone() throws {
        // A shell may be a dev server that never exits; upstream's own TUI
        // "done" ignores shells, and so does Crow.
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [
            { kind: "shell", sessionID: "ses_root", shellID: "sh_1", command: "npm run dev" },
          ] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(names.filter { $0 == "Stop" }.count == 1)
        #expect(cardState(after: names) == .done)
    }

    @Test func nonShellAndUnknownBackgroundKindsHoldDone() throws {
        // `codemode` / `image` / `video` (2.4.0, CROW-1522) report back and
        // wake the session; a kind added later is assumed to as well — never
        // Stop on doubt.
        for kind in ["codemode", "image", "video", "something-new"] {
            let names = try run(events: """
            [
              { type: "session.created", data: { sessionID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_root" } },
              { hook: "experimental.idle", data: { sessionID: "ses_root", background: [
                { kind: "\(kind)", sessionID: "ses_root" },
              ] } },
              { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
            ]
            """)
            #expect(!names.contains("Stop"), "kind \(kind) must hold done")
        }
    }

    @Test func freshEmptyIdleReportOutranksChildTracking() throws {
        // A child was created but this plugin never saw it end (e.g. it ended
        // before a reload). Upstream's own report says nothing is outstanding,
        // so the root's ending is done.
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(names.filter { $0 == "Stop" }.count == 1)
    }

    @Test func idleReportOnlySpeaksForItsOwnExecution() throws {
        // Execution 1 is held by its report. Execution 2 ends with no report
        // (a control-only drain skips the hook): the stale hold must not strand
        // the card, so the child tracking decides — the child is done — Stop.
        let names = try run(events: """
        [
        \(rootEndsWhileSubagentRuns)
          { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(names.filter { $0 == "Stop" }.count == 1)
        #expect(cardState(after: names) == .done)
    }

    @Test func withoutIdleHookTrackedChildrenHoldDone() throws {
        // OpenCode < 2.2.1 (hook missing) or a renamed hook (registration
        // rejects): the stable-event fallback alone holds Stop while a child
        // created by this root is still running.
        for api in [SessionHookAPI.missing, .throwing] {
            let names = try run(events: """
            [
              { type: "session.created", data: { sessionID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_root" } },
              { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_root" } },
              { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_child" } },
              { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
              { type: "session.execution.started", data: { sessionID: "ses_root" } },
              { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
            ]
            """, sessionHookAPI: api)
            #expect(Array(names.prefix(4)) == ["SessionStart", "UserPromptSubmit", "UserPromptSubmit", "Stop"],
                    "api \(api)")
            #expect(names.filter { $0 == "Stop" }.count == 1, "api \(api)")
        }
    }

    @Test func failedOrInterruptedRootWithRunningChildIsNotDone() throws {
        // The hook does not run after a failure or an interruption, and on
        // 2.3.0 Escape no longer cancels children — they report later. A report
        // from earlier in the execution must not license a Stop either.
        for ending in [
            #"{ type: "session.execution.failed", data: { sessionID: "ses_root", error: { type: "x", message: "boom" } } }"#,
            #"{ type: "session.execution.interrupted", data: { sessionID: "ses_root", reason: "user" } }"#,
        ] {
            let names = try run(events: """
            [
              { type: "session.created", data: { sessionID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_root" } },
              { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_child" } },
              { hook: "experimental.idle", data: { sessionID: "ses_root", background: [] } },
              \(ending),
            ]
            """)
            #expect(!names.contains("Stop"), "ending \(ending)")
            #expect(cardState(after: names) == .working)
        }
    }

    // MARK: - Automations (CROW-1522, OpenCode ≥ 2.4.0)

    @Test func videoJobHoldsUntilItsNoticeWakesTheRoot() throws {
        // 2.4.0's `generate_video` returns at once and runs as a background
        // job; its completion notice wakes the root, and that turn's ending is
        // the one `Stop`.
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [
            { kind: "video", sessionID: "ses_root", path: "/tmp/videos/ses_root/vid_1.mp4" },
          ] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(Array(names.prefix(4)) == ["SessionStart", "UserPromptSubmit", "UserPromptSubmit", "Stop"])
        #expect(names.filter { $0 == "Stop" }.count == 1)
    }

    @Test func automationRunChildNeverHoldsTheRoot() throws {
        // An automation's `{ subagent }` run is a `ses_aut_*` child of the
        // creating session that reports to no one. The root's failed or
        // interrupted ending (decided by child tracking, not the hook) must
        // still be `Stop`: no report will ever wake the root to release it.
        for ending in [
            #"{ type: "session.execution.failed", data: { sessionID: "ses_root", error: { type: "x", message: "boom" } } }"#,
            #"{ type: "session.execution.interrupted", data: { sessionID: "ses_root", reason: "user" } }"#,
        ] {
            let names = try run(events: """
            [
              { type: "session.created", data: { sessionID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_root" } },
              { type: "session.created", data: { sessionID: "ses_aut_01J_1", parentID: "ses_root" } },
              { type: "session.execution.started", data: { sessionID: "ses_aut_01J_1" } },
              \(ending),
            ]
            """)
            #expect(names.filter { $0 == "Stop" }.count == 1, "ending \(ending)")
            #expect(names.filter { $0 == "UserPromptSubmit" }.count == 1, "ending \(ending)")
            #expect(cardState(after: names) == .done)
        }
    }

    @Test func automationPromptAfterDoneReopensThenEndsAgain() throws {
        // An automation that prompts the creating session wakes a root Crow
        // already parked on `.done`. The plugin reports it as it is — a new
        // turn, then a new ending — and does not hide the extra work.
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: [] } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(Array(names.prefix(5)) == ["SessionStart", "UserPromptSubmit", "Stop", "UserPromptSubmit", "Stop"])
    }

    @Test func malformedIdleReportFallsBackWithoutBreakingTheBridge() throws {
        // A hook that throws fails the execution upstream, so the callback
        // swallows bad input; the fallback then decides (child still running).
        let names = try run(events: """
        [
          { type: "session.created", data: { sessionID: "ses_root" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_root" } },
          { hook: "experimental.idle", data: null },
          { hook: "experimental.idle", data: { sessionID: "ses_root", background: "nope" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
          { type: "session.execution.started", data: { sessionID: "ses_root" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_root" } },
        ]
        """)
        #expect(names.filter { $0 == "Stop" }.count == 1)
        #expect(names.last == "BridgeUnavailable")
    }

    // MARK: - Automations off for .job/.review (CROW-1526)

    /// What the fake `crow get-session` does.
    enum KindLookup {
        /// Prints `{"kind": "<kind>"}` and exits 0.
        case answers(String)
        /// Exits 1 with no output (Crow not running).
        case fails
        /// Exits 0 with output that isn't JSON.
        case garbage
    }

    /// The tool registry the plugin's transform sees and what is left after it.
    struct AutomationGateResult: Decodable {
        /// Tool ids right after `setup` returns, before the kind lookup settles.
        let before: [String]
        /// Tool ids once the lookup has settled (and any reload has run).
        let after: [String]
        let reloads: Int
        let transforms: Int
    }

    /// Run the V2 plugin's `setup` against a fake registry holding two
    /// `automation`-namespace tools and two others, with a fake `crow` whose
    /// `get-session` behaves as `lookup`. `transformAPI: false` drops
    /// `ctx.tool.transform` (an OpenCode build without it).
    private func runAutomationGate(
        lookup: KindLookup,
        sessionID: UUID? = UUID(),
        transformAPI: Bool = true
    ) throws -> AutomationGateResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-oc2-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("crow.log").path
        let crow = dir.appendingPathComponent("crow").path
        let reply: String
        switch lookup {
        case .answers(let kind): reply = "echo '{\"id\" : \"x\", \"kind\" : \"\(kind)\"}'; status=0"
        case .fails: reply = "status=1"
        case .garbage: reply = "echo 'not json'; status=0"
        }
        try """
        #!/bin/sh
        if [ "$1" = "get-session" ]; then
          echo get-session >> \(OpenCodeLaunchArgs.shellQuote(log))
          \(reply)
          echo get-session-done >> \(OpenCodeLaunchArgs.shellQuote(log))
          exit $status
        fi
        while [ $# -gt 0 ]; do
          if [ "$1" = "--event" ]; then echo "$2" >> \(OpenCodeLaunchArgs.shellQuote(log)); fi
          shift
        done
        cat > /dev/null
        """.write(toFile: crow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crow)

        let plugin = dir.appendingPathComponent("crow-hooks.mjs")
        try OpenCodeHookConfigWriter.pluginSource(
            crowPath: crow, sessionID: sessionID, generation: .v2
        ).write(to: plugin, atomically: true, encoding: .utf8)

        let transform = transformAPI
            ? "async transform(fn) { TRANSFORMS.push(fn); return { async dispose() {} }; },"
            : ""
        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import plugin from \(jsString(plugin.path));
        const { readFileSync } = await import("node:fs");
        const TRANSFORMS = [];
        let RELOADS = 0;
        const TOOLS = [
          { id: "automation_create", options: { namespace: "automation", codemode: true } },
          { id: "automation_list", options: { namespace: "automation", codemode: true } },
          { id: "read" },
          { id: "shell", options: {} },
        ];
        // Rebuild the registry through every registered transform, the way
        // OpenCode re-runs them on each tool state change and on reload.
        function registry() {
          const tools = new Map(TOOLS.map((t) => [t.id, t]));
          const editor = { list: () => Array.from(tools.values()), remove: (id) => { tools.delete(id); } };
          for (const fn of TRANSFORMS) fn(editor);
          return Array.from(tools.keys());
        }
        const lines = () => {
          try { return readFileSync(\(jsString(log)), "utf8").split("\\n").filter(Boolean); }
          catch (_) { return []; }
        };
        async function until(pred) {
          for (let i = 0; i < 400 && !pred(); i++) await new Promise((r) => setTimeout(r, 25));
        }
        const cleanup = await plugin.setup({
          location: { directory: \(jsString(dir.path)) },
          event: { subscribe() { return (async function* () {})(); } },
          session: { async get() { throw new Error("not found"); } },
          tool: {
            async hook() {},
            \(transform)
            async reload() { RELOADS++; },
          },
        });
        const before = registry();
        if (\(sessionID != nil && transformAPI)) {
          // The fake crow logs `get-session-done` just before it exits; give
          // the plugin a moment to handle the exit after that.
          await until(() => RELOADS > 0 || lines().includes("get-session-done"));
          await new Promise((r) => setTimeout(r, 200));
        } else {
          await until(() => lines().includes("BridgeUnavailable"));
        }
        if (typeof cleanup === "function") cleanup();
        console.log(JSON.stringify({ before, after: registry(), reloads: RELOADS, transforms: TRANSFORMS.length }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(openCodeTestNodePath))
        process.arguments = [harness.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "node failed: \(err)")
        let line = try #require(String(data: out, encoding: .utf8)?
            .split(separator: "\n").last.map(String.init))
        return try JSONDecoder().decode(AutomationGateResult.self, from: Data(line.utf8))
    }

    private let automationTools: Set<String> = ["automation_create", "automation_list"]
    private let otherTools: Set<String> = ["read", "shell"]

    @Test(arguments: ["job", "review"])
    func jobAndReviewSessionsLoseTheAutomationTools(kind: String) throws {
        let result = try runAutomationGate(lookup: .answers(kind))
        #expect(Set(result.after) == otherTools)
        #expect(result.reloads == 0)
    }

    @Test(arguments: ["work", "manager"])
    func workAndManagerSessionsKeepTheAutomationTools(kind: String) throws {
        let result = try runAutomationGate(lookup: .answers(kind))
        #expect(Set(result.after) == automationTools.union(otherTools))
        #expect(result.reloads == 1)
    }

    @Test func toolsAreOffBeforeTheKindIsKnown() throws {
        // The removal is registered before the lookup runs, so even a `.work`
        // session starts without the tools and only gets them back on reload.
        // No first turn of a `.job` can see them.
        let result = try runAutomationGate(lookup: .answers("work"))
        #expect(Set(result.before) == otherTools)
    }

    @Test func failedOrUnreadableLookupKeepsTheToolsOff() throws {
        for lookup in [KindLookup.fails, .garbage, .answers("something-new")] {
            let result = try runAutomationGate(lookup: lookup)
            #expect(Set(result.after) == otherTools, "lookup \(lookup)")
            #expect(result.reloads == 0, "lookup \(lookup)")
        }
    }

    @Test func globalFallbackPluginNeverRemovesTheTools() throws {
        // Hand-started sessions carry no Crow session: nothing to look up.
        let result = try runAutomationGate(lookup: .answers("job"), sessionID: nil)
        #expect(result.transforms == 0)
        #expect(Set(result.after) == automationTools.union(otherTools))
    }

    @Test func buildWithoutToolTransformStillBridges() throws {
        // Below 2.4 there are no automation tools; a build without
        // `ctx.tool.transform` must not break setup.
        let result = try runAutomationGate(lookup: .answers("job"), transformAPI: false)
        #expect(result.transforms == 0)
    }
}
