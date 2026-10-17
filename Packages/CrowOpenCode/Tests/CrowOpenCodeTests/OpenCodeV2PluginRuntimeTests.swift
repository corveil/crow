import Foundation
import Testing
@testable import CrowOpenCode

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
/// `ctx.tool.hook(name, fn)`. Skipped when no `node` is installed.
@Suite("OpenCode V2 plugin runtime", .enabled(if: openCodeTestNodePath != nil))
struct OpenCodeV2PluginRuntimeTests {

    /// Run the plugin with `events` (JS array literal of `{type, data}`),
    /// optional `sessions` (JS object: id → info for `session.get`), and an
    /// optional `ctxOverride` JS expression replacing the whole ctx. Returns
    /// the `--event` names the fake `crow` received, in order.
    private func run(
        events: String,
        sessions: String = "{}",
        ctxOverride: String? = nil,
        sessionID: UUID? = UUID(),
        exerciseToolHooks: Bool = false
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
        let ctx = ctxOverride ?? """
        {
          location: { directory: \(jsString(dir.path)) },
          event: {
            subscribe({ signal }) {
              return (async function* () {
                for (const e of EVENTS) { yield e; await new Promise((r) => setTimeout(r, 5)); }
              })();
            },
          },
          session: {
            async get({ sessionID }) {
              if (!(sessionID in SESSIONS)) throw new Error("not found");
              return SESSIONS[sessionID];
            },
          },
          tool: { async hook(name, fn) { HOOKS[name] = fn; } },
        }
        """
        try """
        import plugin from \(jsString(plugin.path));
        const EVENTS = \(events);
        const SESSIONS = \(sessions);
        const HOOKS = {};
        // Wait until the fake crow's log stops growing — spawns are slow when
        // the suite runs in parallel, so a fixed sleep is flaky.
        const { statSync } = await import("node:fs");
        const size = () => { try { return statSync(\(jsString(log))).size; } catch (_) { return 0; } };
        async function quiet() {
          let last = -1, stable = 0;
          for (let i = 0; i < 200 && stable < 6; i++) {
            await new Promise((r) => setTimeout(r, 50));
            const now = size();
            stable = now === last ? stable + 1 : 0;
            last = now;
          }
        }
        const cleanup = await plugin.setup(\(ctx));
        await quiet();
        if (\(exerciseToolHooks) && HOOKS["execute.before"]) await HOOKS["execute.before"]({ tool: "bash" });
        if (\(exerciseToolHooks) && HOOKS["execute.after"]) await HOOKS["execute.after"]({ tool: "bash" });
        await quiet();
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
}
