import Foundation
import Testing
@testable import CrowOpenCode
import CrowCore

@Suite("OpenCodeHookConfigWriter")
struct OpenCodeHookConfigWriterTests {

    @Test func pluginSourceBakesInCrowPathAndEventBridge() {
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/usr/local/bin/crow")

        // crowPath baked in as a JS string literal.
        #expect(js.contains("const CROW = \"/usr/local/bin/crow\""))
        // Exports a plugin function OpenCode auto-loads.
        #expect(js.contains("export const CrowHooks"))
        // Forwards via `crow hook-event --agent opencode` (global/cwd-match form).
        #expect(js.contains("hook-event --agent opencode --event"))
        // Subscribes to the event bus + tool hooks.
        #expect(js.contains("event: async"))
        #expect(js.contains("\"tool.execute.before\""))
        #expect(js.contains("\"tool.execute.after\""))
    }

    @Test func pluginSourceMapsOpenCodeEventsToCrowCanonicalNames() {
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow")
        // OpenCode event.type → Crow-canonical PascalCase.
        #expect(js.contains("case \"session.created\":"))
        #expect(js.contains("\"SessionStart\""))
        // Done detection rides `session.status` (CROW-1000), with the
        // deprecated `session.idle` kept only as an older-build fallback.
        #expect(js.contains("case \"session.status\":"))
        #expect(js.contains("case \"session.idle\":"))
        #expect(js.contains("\"Stop\""))
        // Permission detection uses the first-class `permission.ask` hook, not
        // a bus event.type — the SDK Event union has no `permission.asked`.
        #expect(js.contains("\"permission.ask\":"))
        #expect(js.contains("\"PermissionRequest\""))
        #expect(!js.contains("permission.asked"))
        #expect(js.contains("\"PreToolUse\""))
        #expect(js.contains("\"PostToolUse\""))
        // Prefers the git worktree path for cwd resolution.
        #expect(js.contains("worktree || directory"))
    }

    @Test func pluginSourceLatchesSessionStatusSoIdleDoesNotDoubleEmit() {
        // Upstream publishes BOTH `session.status {idle}` and the deprecated
        // `session.idle` at turn end (status first), so the plugin must ignore
        // the compat event once it has seen a `session.status`.
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow")
        #expect(js.contains("let sawSessionStatus = false;"))
        #expect(js.contains("sawSessionStatus = true;"))
        #expect(js.contains("if (!sawSessionStatus) await emit($, cwd, \"Stop\");"))
    }

    @Test func pluginSourceActsOnStatusTransitionsOnly() {
        // `session.status` is published on every internal status write, not
        // only on changes, so the plugin dedups per sessionID.
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow")
        #expect(js.contains("const lastStatus = new Map();"))
        #expect(js.contains("const prev = lastStatus.get(id) || \"idle\";"))
        #expect(js.contains("if (prev === state) break;"))
    }

    @Test func pluginSourceMapsBusyToWorkingAndNeverTreatsRetryAsDone() {
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow")
        // `busy` is the "turn started" edge — the card must leave `.done`
        // before the first tool call.
        #expect(js.contains("\"UserPromptSubmit\""))
        // `retry` is a busy sub-state: folded into busy, never mapped to Stop.
        #expect(js.contains("raw === \"retry\" ? \"busy\" : raw"))
        // Only these two normalized states produce an emit.
        #expect(js.contains("if (state === \"idle\") {"))
        #expect(js.contains("if (state === \"busy\") {"))
    }

    @Test func pluginSourceDropsSubagentChildSessions() {
        // CROW-1082: a subagent runs as a CHILD session on the same per-server
        // bus, but `session.status`/`session.idle` carry only a `sessionID`. The
        // plugin records child ids from `session.created`'s `info.parentID` and
        // drops that id's status/idle, so a child idling can't mark the parent's
        // card `.done` mid-turn.
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow")
        // A set of child session ids, populated from `session.created`.
        #expect(js.contains("const childSessions = new Set();"))
        #expect(js.contains("if (info.parentID) {"))
        #expect(js.contains("childSessions.add(info.id);"))
        // Both the modern and deprecated idle paths guard on membership.
        #expect(js.contains("if (childSessions.has(id)) break;"))
        // The deprecated fallback reads the sessionID it previously ignored.
        #expect(js.contains("event.properties.sessionID"))
    }

    @Test func globalPluginSourceSelfSuppressesWhenPerProjectExists() {
        // Global variant (no session UUID): SESSION empty, cwd-match emit, and
        // a guard that defers to a per-project plugin so events don't double-emit.
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow", sessionID: nil)
        #expect(js.contains("const SESSION = \"\""))
        #expect(js.contains("Bun.file(cwd + \"/.opencode/plugins/crow-hooks.js\").exists()"))
        #expect(js.contains("return {};"))
    }

    @Test func perProjectPluginSourceBakesInSessionUUID() {
        let sessionID = UUID()
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow", sessionID: sessionID)
        // The exact session UUID is baked in and used for resolution.
        #expect(js.contains("const SESSION = \"\(sessionID.uuidString)\""))
        #expect(js.contains("hook-event --session ${SESSION} --agent opencode --event"))
        // The self-suppress guard is a static template in both variants, but it
        // only runs for the global fallback — gated behind `if (!SESSION)`, so a
        // session-scoped plugin (non-empty SESSION) never suppresses itself.
        #expect(js.contains("if (!SESSION)"))
    }

    @Test func installGlobalConfigWritesPluginFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try OpenCodeHookConfigWriter.installGlobalConfig(
            configHome: tmp.path, crowPath: "/bin/crow", generation: .v1)

        let pluginPath = tmp.appendingPathComponent("plugins/crow-hooks.js")
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
        let content = try String(contentsOf: pluginPath, encoding: .utf8)
        #expect(content.contains("export const CrowHooks"))
        // Global variant carries no session UUID.
        #expect(content.contains("const SESSION = \"\""))

        // Idempotent: a second install overwrites cleanly.
        try OpenCodeHookConfigWriter.installGlobalConfig(
            configHome: tmp.path, crowPath: "/bin/crow", generation: .v1)
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
    }

    @Test func writeHookConfigInstallsPerProjectPluginWithSessionUUID() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let sessionID = UUID()
        let writer = OpenCodeHookConfigWriter(generation: { .v1 })
        try writer.writeHookConfig(
            worktreePath: worktree.path, sessionID: sessionID, crowPath: "/bin/crow")

        // Lands in the worktree's `.opencode/plugins/`, not the global dir.
        let pluginPath = worktree
            .appendingPathComponent(".opencode/plugins/crow-hooks.js")
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
        let content = try String(contentsOf: pluginPath, encoding: .utf8)
        #expect(content.contains("const SESSION = \"\(sessionID.uuidString)\""))
        #expect(content.contains("hook-event --session ${SESSION} --agent opencode"))
    }

    @Test func removeHookConfigDeletesPluginAndPrunesEmptyDirs() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let writer = OpenCodeHookConfigWriter(generation: { .v1 })
        try writer.writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        writer.removeHookConfig(worktreePath: worktree.path)
        let pluginPath = worktree.appendingPathComponent(".opencode/plugins/crow-hooks.js")
        #expect(!FileManager.default.fileExists(atPath: pluginPath.path))
        // Crow-created empty dirs are pruned.
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".opencode").path))
        // Removing again is a safe no-op.
        writer.removeHookConfig(worktreePath: worktree.path)
    }

    @Test func removeHookConfigPreservesUserPluginsInDir() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        let pluginsDir = worktree.appendingPathComponent(".opencode/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        // A user's own plugin sits alongside ours.
        let userPlugin = pluginsDir.appendingPathComponent("my-plugin.js")
        try "export const Mine = () => ({})".write(to: userPlugin, atomically: true, encoding: .utf8)

        let writer = OpenCodeHookConfigWriter(generation: { .v1 })
        try writer.writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)

        // Ours is gone; theirs (and the non-empty dir) survive.
        #expect(!FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("crow-hooks.js").path))
        #expect(FileManager.default.fileExists(atPath: userPlugin.path))
    }

    @Test func writeHookConfigPreservesUserGitignore() throws {
        // `.opencode/plugins/` is the user's dir — a hand-written `.gitignore`
        // there must never be clobbered by our self-scoped one.
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        let pluginsDir = worktree.appendingPathComponent(".opencode/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let userGitignore = pluginsDir.appendingPathComponent(".gitignore")
        try "my-local-only.js\n".write(to: userGitignore, atomically: true, encoding: .utf8)

        let writer = OpenCodeHookConfigWriter(generation: { .v1 })
        try writer.writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        // Our plugin is written, but the user's ignore rules are untouched.
        #expect(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("crow-hooks.js").path))
        #expect(try String(contentsOf: userGitignore, encoding: .utf8) == "my-local-only.js\n")

        // And removeHookConfig must not delete a `.gitignore` that isn't ours.
        writer.removeHookConfig(worktreePath: worktree.path)
        #expect(try String(contentsOf: userGitignore, encoding: .utf8) == "my-local-only.js\n")
    }

    @Test func writeHookConfigWritesOwnGitignoreIntoEmptyDir() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        try OpenCodeHookConfigWriter(generation: { .v1 }).writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        let gitignore = worktree.appendingPathComponent(".opencode/plugins/.gitignore")
        let body = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(body == OpenCodeHookConfigWriter.gitignoreBody)
        #expect(body.contains("crow-hooks.js"))
    }

    @Test func removeHookConfigCleansOrphanedGitignoreAfterManualPluginDelete() throws {
        // A user who takes the "safe to delete" header at its word and removes
        // `crow-hooks.js` by hand must not be left with an orphaned, self-ignoring
        // `.gitignore` that `git status` can't surface — removeHookConfig no
        // longer early-returns just because the plugin is already gone.
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let writer = OpenCodeHookConfigWriter(generation: { .v1 })
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        let pluginsDir = worktree.appendingPathComponent(".opencode/plugins")
        try FileManager.default.removeItem(at: pluginsDir.appendingPathComponent("crow-hooks.js"))
        #expect(FileManager.default.fileExists(atPath: pluginsDir.appendingPathComponent(".gitignore").path))

        writer.removeHookConfig(worktreePath: worktree.path)
        #expect(!FileManager.default.fileExists(atPath: pluginsDir.appendingPathComponent(".gitignore").path))
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".opencode").path))
    }

    // MARK: - OpenCode 2 (CROW-1332)

    @Test func generationGatesOnProbedV2Floor() {
        typealias G = OpenCodePluginGeneration
        #expect(G.forVersion(AgentSemVer(1, 18, 15)) == .v1)
        #expect(G.forVersion(AgentSemVer(1, 19, 3)) == .v1)
        #expect(G.forVersion(AgentSemVer(2, 0, 0)) == .v2)
        #expect(G.forVersion(AgentSemVer(2, 0, 32)) == .v2)
        // A failed probe keeps today's V1 body rather than guessing.
        #expect(G.forVersion(nil) == .v1)
        #expect(G.detect(binary: nil).generation == .v1)
    }

    @Test func pluginSourceDispatchesOnGeneration() {
        let v1 = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow", generation: .v1)
        let v2 = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow", generation: .v2)
        #expect(v1.contains("export const CrowHooks"))
        #expect(!v1.contains("export default"))
        // V2 decodes the default export's `{ id, setup }`; no V1 entrypoint,
        // and no `$` (V2 removed it).
        #expect(v2.contains("export default {"))
        #expect(v2.contains("id: \"crow-hooks\""))
        #expect(v2.contains("async setup(ctx)"))
        #expect(!v2.contains("export const CrowHooks"))
        #expect(!v2.contains("await $`"))
        // Defaults to V1 so existing callers keep their body.
        #expect(OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow") == v1)
    }

    @Test func v2PluginKeysOffExecutionLifecycleNotSessionIdle() {
        // V2 core never publishes `session.status`/`session.idle`; the TUI
        // reads `session.execution.*`, so a `session.idle` port would never
        // emit Stop.
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow", generation: .v2)
        #expect(js.contains("case \"session.execution.started\":"))
        #expect(js.contains("case \"session.execution.succeeded\":"))
        #expect(js.contains("case \"session.execution.failed\":"))
        #expect(js.contains("case \"session.execution.interrupted\":"))
        #expect(!js.contains("case \"session.idle\":"))
        #expect(!js.contains("case \"session.status\":"))
        // V2 payloads carry `data`, not V1's `properties`.
        #expect(js.contains("event.data"))
        #expect(!js.contains("event.properties"))
        // Permission rides the bus event, not the every-evaluation hook.
        #expect(js.contains("case \"permission.asked\":"))
        #expect(!js.contains("permission.hook"))
        #expect(js.contains("ctx.tool.hook(\"execute.before\""))
        #expect(js.contains("ctx.tool.hook(\"execute.after\""))
    }

    @Test func v2PluginFailsClosedWithoutStop() {
        let js = OpenCodeHookConfigWriter.pluginSource(crowPath: "/bin/crow", generation: .v2)
        #expect(js.contains("\"BridgeUnavailable\""))
        #expect(js.contains("typeof ctx.event.subscribe !== \"function\""))
        #expect(js.contains("if (!controller.signal.aborted) await unavailable("))
    }

    @Test func v2PluginScopesBySessionOrSelfSuppressesGlobally() {
        let sessionID = UUID()
        let scoped = OpenCodeHookConfigWriter.pluginSource(
            crowPath: "/bin/crow", sessionID: sessionID, generation: .v2)
        #expect(scoped.contains("const SESSION = \"\(sessionID.uuidString)\""))
        #expect(scoped.contains("[\"hook-event\", \"--session\", SESSION,"))
        let global = OpenCodeHookConfigWriter.pluginSource(
            crowPath: "/bin/crow", sessionID: nil, generation: .v2)
        #expect(global.contains("const SESSION = \"\""))
        #expect(global.contains("existsSync(cwd + \"/.opencode/plugins/crow-hooks.js\")"))
    }

    @Test func writeHookConfigWritesTheProbedGeneration() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let pluginPath = worktree.appendingPathComponent(".opencode/plugins/crow-hooks.js")

        // Same file, re-probed on every write: a v1 → v2 upgrade swaps the body.
        try OpenCodeHookConfigWriter(generation: { .v1 }).writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        #expect(try String(contentsOf: pluginPath, encoding: .utf8).contains("export const CrowHooks"))
        try OpenCodeHookConfigWriter(generation: { .v2 }).writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        let v2 = try String(contentsOf: pluginPath, encoding: .utf8)
        #expect(v2.contains("export default {"))
        #expect(!v2.contains("export const CrowHooks"))

        // Teardown is generation-agnostic.
        OpenCodeHookConfigWriter(generation: { .v2 }).removeHookConfig(worktreePath: worktree.path)
        #expect(!FileManager.default.fileExists(atPath: pluginPath.path))
    }

    @Test func installGlobalConfigWritesRequestedGeneration() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try OpenCodeHookConfigWriter.installGlobalConfig(
            configHome: tmp.path, crowPath: "/bin/crow", generation: .v2)
        let content = try String(
            contentsOf: tmp.appendingPathComponent("plugins/crow-hooks.js"), encoding: .utf8)
        #expect(content.contains("export default {"))
        #expect(content.contains("const SESSION = \"\""))
    }
}
