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
        // Forwards via `crow hook-event --agent opencode`.
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

        // Idempotent: a second install overwrites cleanly.
        try OpenCodeHookConfigWriter.installGlobalConfig(
            configHome: tmp.path, crowPath: "/bin/crow")
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
    }

    @Test func perSessionMethodsAreNoOps() throws {
        // Global model — per-session writes are no-ops and must not throw.
        let writer = OpenCodeHookConfigWriter()
        try writer.writeHookConfig(
            worktreePath: "/tmp/does-not-matter",
            sessionID: UUID(),
            crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: "/tmp/does-not-matter")
    }
}
