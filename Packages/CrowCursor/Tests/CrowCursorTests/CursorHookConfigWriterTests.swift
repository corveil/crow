import Foundation
import Testing
@testable import CrowCursor
@testable import CrowCore

@Suite("CursorHookConfigWriter")
struct CursorHookConfigWriterTests {
    private func makeTempCursorHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeHookConfigIsNoOp() throws {
        // Per-session writes are no-ops — Cursor hooks are global.
        let writer = CursorHookConfigWriter()
        let tmp = try makeTempCursorHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writer.writeHookConfig(
            worktreePath: tmp.path,
            sessionID: UUID(),
            crowPath: "/usr/local/bin/crow"
        )
        // No file should have been created in the worktree.
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        #expect(files.isEmpty)
    }

    @Test func installGlobalConfigWritesAllEvents() throws {
        let cursorHome = try makeTempCursorHome()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        try CursorHookConfigWriter.installGlobalConfig(
            cursorHome: cursorHome.path,
            crowPath: "/opt/homebrew/bin/crow"
        )

        let hooksPath = cursorHome.appendingPathComponent("hooks.json")
        let data = try Data(contentsOf: hooksPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        // Cursor keys are camelCase.
        #expect(hooks.count == 6)
        for event in ["sessionStart", "preToolUse", "postToolUse", "beforeSubmitPrompt", "stop", "afterAgentResponse"] {
            #expect(hooks[event] != nil, "missing hook entry for \(event)")
        }

        // Spot-check the command shape — the `--event` arg is the
        // Crow-canonical PascalCase name, not the Cursor camelCase key.
        let entries = hooks["preToolUse"] as! [[String: Any]]
        let inner = entries.first!["hooks"] as! [[String: Any]]
        let command = inner.first!["command"] as! String
        #expect(command == "/opt/homebrew/bin/crow hook-event --agent cursor --event PreToolUse")
    }

    @Test func installGlobalConfigMapsAfterAgentResponseToNotification() throws {
        let cursorHome = try makeTempCursorHome()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        try CursorHookConfigWriter.installGlobalConfig(
            cursorHome: cursorHome.path,
            crowPath: "/usr/local/bin/crow"
        )

        let hooksPath = cursorHome.appendingPathComponent("hooks.json")
        let data = try Data(contentsOf: hooksPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        let entries = hooks["afterAgentResponse"] as! [[String: Any]]
        let inner = entries.first!["hooks"] as! [[String: Any]]
        let command = inner.first!["command"] as! String
        #expect(command.contains("--event Notification"))
    }

    @Test func installGlobalConfigPreservesUserEntries() throws {
        let cursorHome = try makeTempCursorHome()
        defer { try? FileManager.default.removeItem(at: cursorHome) }

        // Pre-seed a user-managed hook for a non-Crow event.
        let hooksPath = cursorHome.appendingPathComponent("hooks.json")
        let preExisting: [String: Any] = [
            "hooks": [
                "beforeShellExecution": [
                    ["hooks": [["type": "command", "command": "/usr/local/bin/my-shell-guard"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: preExisting)
        try data.write(to: hooksPath)

        try CursorHookConfigWriter.installGlobalConfig(
            cursorHome: cursorHome.path,
            crowPath: "/usr/local/bin/crow"
        )

        let after = try Data(contentsOf: hooksPath)
        let json = try JSONSerialization.jsonObject(with: after) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        #expect(hooks["beforeShellExecution"] != nil, "user-managed hook entry should be preserved")
        #expect(hooks["stop"] != nil, "Crow's stop hook should still be installed")
    }

    @Test func installGlobalConfigIsIdempotent() throws {
        let cursorHome = try makeTempCursorHome()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        try CursorHookConfigWriter.installGlobalConfig(cursorHome: cursorHome.path, crowPath: "/bin/crow")
        let first = try Data(contentsOf: cursorHome.appendingPathComponent("hooks.json"))
        try CursorHookConfigWriter.installGlobalConfig(cursorHome: cursorHome.path, crowPath: "/bin/crow")
        let second = try Data(contentsOf: cursorHome.appendingPathComponent("hooks.json"))
        #expect(first == second)
    }

    @Test func postToolUseAndNotificationAreAsync() throws {
        let cursorHome = try makeTempCursorHome()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        try CursorHookConfigWriter.installGlobalConfig(
            cursorHome: cursorHome.path,
            crowPath: "/bin/crow"
        )

        let data = try Data(contentsOf: cursorHome.appendingPathComponent("hooks.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        for asyncKey in ["postToolUse", "afterAgentResponse"] {
            let entries = hooks[asyncKey] as! [[String: Any]]
            let inner = entries.first!["hooks"] as! [[String: Any]]
            let asyncFlag = inner.first!["async"] as? Bool
            #expect(asyncFlag == true, "\(asyncKey) should be async")
        }

        // Spot-check that `stop` stays synchronous — its timing matters.
        let stopEntries = hooks["stop"] as! [[String: Any]]
        let stopInner = stopEntries.first!["hooks"] as! [[String: Any]]
        #expect(stopInner.first!["async"] == nil, "stop should be synchronous")
    }
}
