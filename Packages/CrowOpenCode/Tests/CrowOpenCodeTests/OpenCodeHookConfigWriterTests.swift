import Foundation
import Testing
@testable import CrowOpenCode

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
            configHome: tmp.path, crowPath: "/bin/crow")

        let pluginPath = tmp.appendingPathComponent("plugins/crow-hooks.js")
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
        let content = try String(contentsOf: pluginPath, encoding: .utf8)
        #expect(content.contains("export const CrowHooks"))
        // Global variant carries no session UUID.
        #expect(content.contains("const SESSION = \"\""))

        // Idempotent: a second install overwrites cleanly.
        try OpenCodeHookConfigWriter.installGlobalConfig(
            configHome: tmp.path, crowPath: "/bin/crow")
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
    }

    @Test func writeHookConfigInstallsPerProjectPluginWithSessionUUID() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let sessionID = UUID()
        let writer = OpenCodeHookConfigWriter()
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

        let writer = OpenCodeHookConfigWriter()
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

        let writer = OpenCodeHookConfigWriter()
        try writer.writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)

        // Ours is gone; theirs (and the non-empty dir) survive.
        #expect(!FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("crow-hooks.js").path))
        #expect(FileManager.default.fileExists(atPath: userPlugin.path))
    }
}
