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

    @Test func reapsBridgedJiraWhenSourceRemoved() throws {
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        // Bridge once, alongside a user's own server.
        try write(["mcpServers": ["jira": jiraEntry]], to: claude)
        try write(["mcpServers": ["playwright": ["command": "pw"]]], to: cursor)
        // Re-seed cursor by bridging (so both jira + playwright coexist).
        try write(["mcpServers": ["jira": jiraEntry, "existing": [:]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        #expect((try read(cursor)["mcpServers"] as! [String: Any])["jira"] != nil)

        // Source removed from Claude → our bridged copy is withdrawn, the user's
        // own server survives.
        try write(["mcpServers": ["existing": [:]]], to: claude)  // no jira
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        let servers = try read(cursor)["mcpServers"] as! [String: Any]
        #expect(servers["jira"] == nil, "stale bridged jira reaped")
        #expect(servers["playwright"] != nil, "user's own server preserved")
    }

    @Test func doesNotReapUserAuthoredJiraWhenSourceRemoved() throws {
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        // User's own jira (no marker); Claude has none.
        try write(["mcpServers": ["other": [:]]], to: claude)
        try write(["mcpServers": ["jira": ["url": "https://x", "type": "http"]]], to: cursor)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        let servers = try read(cursor)["mcpServers"] as! [String: Any]
        #expect(servers["jira"] != nil, "unmarked user jira not reaped")
    }

    @Test func doesNotReapWhenClaudeUnparseable() throws {
        // #829 Yellow 3: a truncated/interleaved read of the (large, live)
        // ~/.claude.json returns unparseable — that must NOT be treated as
        // "jira removed" and delete a valid bridged entry.
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        // Bridge once so cursor has a Crow-marked jira.
        try write(["mcpServers": ["jira": jiraEntry]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        #expect((try read(cursor)["mcpServers"] as! [String: Any])["jira"] != nil)

        // Corrupt ~/.claude.json (truncated JSON) → source unavailable, not absent.
        try "{ \"mcpServers\": {".write(toFile: claude, atomically: true, encoding: .utf8)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        #expect((try read(cursor)["mcpServers"] as! [String: Any])["jira"] != nil,
                "bridged jira survives an unparseable claude.json")
    }

    @Test func doesNotClobberUserAuthoredJira() throws {
        // A user's own Cursor `jira` server (no Crow marker) must survive — even
        // though ~/.claude.json has a different jira entry, and the bridge runs
        // every launch.
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["mcpServers": ["jira": jiraEntry]], to: claude)
        let userJira: [String: Any] = ["url": "https://mcp.atlassian.com/v1/sse", "type": "http"]
        try write(["mcpServers": ["jira": userJira]], to: cursor)

        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        let bridged = (try read(cursor)["mcpServers"] as! [String: Any])["jira"] as! [String: Any]
        #expect(bridged["url"] as? String == "https://mcp.atlassian.com/v1/sse", "user's remote jira untouched")
        #expect(bridged["command"] == nil, "not replaced with Claude's stdio entry")
    }

    @Test func refreshesCrowManagedJira() throws {
        // An entry Crow previously bridged (recorded in the top-level marker) IS
        // refreshed when Claude's config changes.
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["mcpServers": ["jira": ["command": "old-jira"]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        let root1 = try read(cursor)
        let first = (root1["mcpServers"] as! [String: Any])["jira"] as! [String: Any]
        #expect(first["command"] as? String == "old-jira")
        // Marker lives at the top level; the entry itself is byte-identical to
        // Claude's (no foreign `x-crow-managed` key inside the server def).
        #expect((root1["x-crow-managed"] as? [String])?.contains("jira") == true)
        #expect(first["x-crow-managed"] == nil, "marker must not pollute the entry Cursor parses")

        // Claude's jira changes; the marked entry is refreshed.
        try write(["mcpServers": ["jira": ["command": "new-jira"]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        let second = (try read(cursor)["mcpServers"] as! [String: Any])["jira"] as! [String: Any]
        #expect(second["command"] as? String == "new-jira", "our own bridge is refreshed")
    }

    @Test func doesNotClobberUnparseableCursorConfig() throws {
        // #829 Red 1: an unparseable ~/.cursor/mcp.json (torn concurrent write,
        // hand-edit syntax error) must NOT be replaced with jira-alone, dropping
        // the user's other MCP servers.
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        try write(["mcpServers": ["jira": jiraEntry]], to: claude)
        // Truncated mid-object → unparseable, but with recognizable content.
        let torn = "{ \"mcpServers\": { \"playwright\": {}, \"postgres\": {"
        try FileManager.default.createDirectory(
            atPath: (cursor as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try torn.write(toFile: cursor, atomically: true, encoding: .utf8)

        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)

        let after = try String(contentsOfFile: cursor, encoding: .utf8)
        #expect(after == torn, "unparseable cursor config left untouched")
        #expect(after.contains("playwright") && after.contains("postgres"))
    }

    @Test func bridgedFileIsOwnerOnlyEvenOverAWorldReadableDest() throws {
        // #829 Yellow 1: the token-bearing file must end owner-only even when a
        // pre-existing destination was world-readable (0644).
        let claude = tempFile(".claude.json")
        let cursor = tempFile("mcp.json")
        defer { try? FileManager.default.removeItem(atPath: (claude as NSString).deletingLastPathComponent) }
        defer { try? FileManager.default.removeItem(atPath: (cursor as NSString).deletingLastPathComponent) }

        // Bridge once (fresh dest → must be 0600 from the 0600 temp).
        try write(["mcpServers": ["jira": ["command": "old-jira"]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        let fresh = try FileManager.default.attributesOfItem(atPath: cursor)[.posixPermissions] as? NSNumber
        #expect(fresh?.int16Value == 0o600, "fresh bridge is owner-only")

        // Externally loosen perms, then refresh → must be tightened back.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cursor)
        try write(["mcpServers": ["jira": ["command": "new-jira"]]], to: claude)
        CursorMCPConfigWriter.bridgeJiraMCP(claudeJSONPath: claude, cursorMCPPath: cursor)
        let after = try FileManager.default.attributesOfItem(atPath: cursor)[.posixPermissions] as? NSNumber
        #expect(after?.int16Value == 0o600, "refresh re-tightens to owner-only")
    }
}
