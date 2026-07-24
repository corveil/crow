import Foundation
import Testing
@testable import CrowCursor

@Suite("CursorMCPConfigWriter")
struct CursorMCPConfigWriterTests {
    private func tempFile(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-mcp-\(UUID().uuidString)")
            .appendingPathComponent(name).path
    }

    private func write(_ obj: [String: Any], to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    }

    private let jiraEntry: [String: Any] = [
        "command": "jira-mcp",
        "args": ["--stdio"],
        "env": ["JIRA_TOKEN": "secret"],
    ]

    @Test func bridgesJiraFromClaude() throws {
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["mcpServers": ["jira": jiraEntry]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        let servers = try read(cursor)["mcpServers"] as! [String: Any]
        let bridged = servers["jira"] as! [String: Any]
        #expect(bridged["command"] as? String == "jira-mcp")
        #expect((bridged["env"] as? [String: Any])?["JIRA_TOKEN"] as? String == "secret")

        // Token-bearing file is owner-only.
        let perms = try FileManager.default.attributesOfItem(atPath: cursor)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func noOpWhenClaudeHasNoJira() throws {
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["mcpServers": ["other": ["command": "x"]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        #expect(FileManager.default.fileExists(atPath: cursor) == false)
    }

    @Test func noOpWhenClaudeConfigAbsent() {
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }
        // Missing claude.json → nothing written, no crash.
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: tempFile(".claude.json"), cursorMCPPath: cursor)
        #expect(FileManager.default.fileExists(atPath: cursor) == false)
    }

    @Test func preservesOtherCursorServers() throws {
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["mcpServers": ["jira": jiraEntry]], to: claude)
        try write(["mcpServers": ["playwright": ["command": "pw-mcp"]]], to: cursor)

        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        let servers = try read(cursor)["mcpServers"] as! [String: Any]
        #expect(servers["playwright"] != nil, "existing Cursor server preserved")
        #expect(servers["jira"] != nil, "jira bridged in")
    }

    @Test func bridgesJiraFromProjectLocalScope() throws {
        // `claude mcp add` defaults to LOCAL scope: projects[<path>].mcpServers,
        // not the root block. The bridge must find it there too.
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["projects": ["/Users/x/repo": ["mcpServers": ["jira": jiraEntry]]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        let servers = try read(cursor)["mcpServers"] as! [String: Any]
        #expect((servers["jira"] as? [String: Any])?["command"] as? String == "jira-mcp")
    }

    @Test func rootScopePreferredOverProjectScope() throws {
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write([
            "mcpServers": ["jira": ["command": "user-scope-jira"]],
            "projects": ["/Users/x/repo": ["mcpServers": ["jira": ["command": "project-scope-jira"]]]],
        ], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        let servers = try read(cursor)["mcpServers"] as! [String: Any]
        #expect((servers["jira"] as? [String: Any])?["command"] as? String == "user-scope-jira")
    }
}
