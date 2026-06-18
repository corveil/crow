import Foundation
import Testing
@testable import CrowClaude
@testable import CrowCore

// MARK: - writeAtlassianMcpConfig (CROW-522)

private func makeTempDir() -> String {
    let dir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("crow-mcp-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

@Test func writeAtlassianMcpConfigWritesServerEnvAndTrust() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let resolved = AtlassianMCPResolver.Resolved(
        endpoint: "https://mcp.atlassian.com/v1/mcp", authorization: "Basic abc123")

    ClaudeHookConfigWriter.writeAtlassianMcpConfig(dirPath: dir, resolved: resolved)

    // .mcp.json registers the http server with an env-reference header (no secret).
    let mcp = readJSON((dir as NSString).appendingPathComponent(".mcp.json"))
    let server = (mcp?["mcpServers"] as? [String: Any])?["atlassian"] as? [String: Any]
    #expect(server?["type"] as? String == "http")
    #expect(server?["url"] as? String == "https://mcp.atlassian.com/v1/mcp")
    let auth = (server?["headers"] as? [String: Any])?["Authorization"] as? String
    #expect(auth == "${ATLASSIAN_MCP_AUTHORIZATION}")

    // settings.local.json carries the resolved credential + the pre-trust entry.
    let settingsPath = (dir as NSString).appendingPathComponent(".claude/settings.local.json")
    let settings = readJSON(settingsPath)
    #expect((settings?["env"] as? [String: Any])?["ATLASSIAN_MCP_AUTHORIZATION"] as? String == "Basic abc123")
    #expect((settings?["enabledMcpjsonServers"] as? [String]) == ["atlassian"])

    // settings.local.json is owner-only (0600).
    let attrs = try FileManager.default.attributesOfItem(atPath: settingsPath)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func writeAtlassianMcpConfigPreservesUserServerOnWrite() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mcpPath = (dir as NSString).appendingPathComponent(".mcp.json")
    let userFile: [String: Any] = ["mcpServers": ["my-server": ["type": "http", "url": "https://x"]]]
    try JSONSerialization.data(withJSONObject: userFile).write(to: URL(fileURLWithPath: mcpPath))

    ClaudeHookConfigWriter.writeAtlassianMcpConfig(
        dirPath: dir,
        resolved: .init(endpoint: "https://mcp.atlassian.com/v1/mcp", authorization: "Basic z"))

    let servers = readJSON(mcpPath)?["mcpServers"] as? [String: Any]
    #expect(servers?["atlassian"] != nil)
    #expect(servers?["my-server"] != nil)  // user's server untouched
}

@Test func teardownRemovesOnlyOurServerAndKeepsUserServer() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mcpPath = (dir as NSString).appendingPathComponent(".mcp.json")

    // First write ours alongside a user-authored server.
    let userFile: [String: Any] = ["mcpServers": ["my-server": ["type": "http", "url": "https://x"]]]
    try JSONSerialization.data(withJSONObject: userFile).write(to: URL(fileURLWithPath: mcpPath))
    ClaudeHookConfigWriter.writeAtlassianMcpConfig(
        dirPath: dir,
        resolved: .init(endpoint: "https://mcp.atlassian.com/v1/mcp", authorization: "Basic z"))

    // Teardown (resolved nil) must drop ONLY our entry — the dangling-server bug.
    ClaudeHookConfigWriter.writeAtlassianMcpConfig(dirPath: dir, resolved: nil)

    let servers = readJSON(mcpPath)?["mcpServers"] as? [String: Any]
    #expect(servers?["atlassian"] == nil, "our server entry must be removed on teardown")
    #expect(servers?["my-server"] != nil, "user's server must survive teardown")

    // And our env var must be gone (so nothing references a missing secret).
    let settings = readJSON((dir as NSString).appendingPathComponent(".claude/settings.local.json"))
    #expect((settings?["env"] as? [String: Any])?["ATLASSIAN_MCP_AUTHORIZATION"] == nil)
    #expect((settings?["enabledMcpjsonServers"] as? [String])?.contains("atlassian") != true)
}

@Test func teardownDeletesMcpJsonWhenOnlyOursRemained() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mcpPath = (dir as NSString).appendingPathComponent(".mcp.json")

    ClaudeHookConfigWriter.writeAtlassianMcpConfig(
        dirPath: dir,
        resolved: .init(endpoint: "https://mcp.atlassian.com/v1/mcp", authorization: "Basic z"))
    #expect(FileManager.default.fileExists(atPath: mcpPath))

    ClaudeHookConfigWriter.writeAtlassianMcpConfig(dirPath: dir, resolved: nil)
    #expect(!FileManager.default.fileExists(atPath: mcpPath),
            "a .mcp.json that held only our server should be removed entirely")
}
