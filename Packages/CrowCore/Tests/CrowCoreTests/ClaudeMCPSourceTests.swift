import Foundation
import Testing
@testable import CrowCore

/// CROW-1214: one parse of `~/.claude.json` for every harness Jira bridge.
/// Fixtures live under a throwaway temp dir — never the live `~/.claude.json`
/// (ADR 0012).
@Suite("ClaudeMCPSource")
struct ClaudeMCPSourceTests {

    private func tempJSON(_ name: String = ".claude.json") -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-mcp-source-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent(name).path)
    }

    private func write(_ obj: [String: Any], to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
    }

    private let jira: [String: Any] = [
        "command": "jira-mcp",
        "args": ["--stdio"],
        "env": ["JIRA_TOKEN": "secret"],
    ]

    @Test func defaultPathIsDotClaudeJSON() {
        #expect(ClaudeMCPSource.defaultPath().hasSuffix("/.claude.json"))
    }

    @Test func findsUserScopedJira() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["mcpServers": ["jira": jira, "other": ["command": "x"]]], to: path)

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .found(let entry, origin: .user):
            #expect(entry["command"] as? String == "jira-mcp")
            #expect((entry["env"] as? [String: Any])?["JIRA_TOKEN"] as? String == "secret")
        default:
            Issue.record("expected user-scoped jira")
        }
    }

    @Test func userScopeWinsOverProjectScope() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([
            "mcpServers": ["jira": ["command": "user-jira"]],
            "projects": [
                "/z/repo": ["mcpServers": ["jira": ["command": "project-jira"]]],
            ],
        ], to: path)

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .found(let entry, origin: .user):
            #expect(entry["command"] as? String == "user-jira")
        default:
            Issue.record("user-scope jira must win")
        }
    }

    @Test func fallsBackToFirstProjectInSortedKeyOrder() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([
            "projects": [
                "/z/repo": ["mcpServers": ["jira": ["command": "z-jira"]]],
                "/a/repo": ["mcpServers": ["jira": ["command": "a-jira"]]],
            ],
        ], to: path)

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .found(let entry, origin: .project(let projectPath)):
            #expect(projectPath == "/a/repo", "sorted-key order, not insertion order")
            #expect(entry["command"] as? String == "a-jira")
        default:
            Issue.record("expected project-scoped jira from /a/repo")
        }
    }

    @Test func parsedButNoJiraIsAbsent() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["mcpServers": ["other": ["command": "x"]]], to: path)

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .absent:
            break
        default:
            Issue.record("parsed config with no jira must be .absent")
        }
    }

    @Test func missingFileIsSourceUnavailable() {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .sourceUnavailable:
            break
        default:
            Issue.record("missing file must not look like absent")
        }
    }

    @Test func unparseableFileIsUnparseable() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{ \"mcpServers\": {".write(toFile: path, atomically: true, encoding: .utf8)

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .unparseable:
            break
        default:
            Issue.record("truncated JSON must be .unparseable, not .absent")
        }
    }

    @Test func jsonArrayIsUnparseable() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "[1, 2, 3]".write(toFile: path, atomically: true, encoding: .utf8)

        switch ClaudeMCPSource.load(from: path) {
        case .unparseable:
            break
        default:
            Issue.record("a JSON array is not a Claude config object")
        }
    }

    @Test func rootOnlyIgnoresProjectScopedServers() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([
            "projects": [
                "/some/repo": ["mcpServers": ["jira": jira]],
            ],
        ], to: path)

        switch ClaudeMCPSource.lookupJira(includeProjectScope: false, from: path) {
        case .absent:
            break
        default:
            Issue.record("Codex root-only narrowing must skip project-scoped jira")
        }

        switch ClaudeMCPSource.lookupJira(includeProjectScope: true, from: path) {
        case .found(_, origin: .project):
            break
        default:
            Issue.record("default lookup still finds project-scoped jira")
        }
    }

    @Test func loadExposesAllUserServersForCodex() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([
            "mcpServers": [
                "jira": ["command": "npx"],
                "remote": ["type": "http", "url": "https://mcp.example.com"],
            ],
            "projects": [
                "/repo": ["mcpServers": ["github": ["command": "gh-mcp"]]],
            ],
        ], to: path)

        guard case .parsed(let snapshot) = ClaudeMCPSource.load(from: path) else {
            Issue.record("expected parsed snapshot")
            return
        }
        let rootOnly = snapshot.servers(includeProjectScope: false)
        #expect(rootOnly.map(\.name) == ["jira", "remote"])
        #expect(rootOnly.allSatisfy { $0.origin == .user })

        let withProjects = snapshot.servers(includeProjectScope: true)
        #expect(withProjects.map(\.name) == ["jira", "remote", "github"])
    }

    @Test func emptyObjectIsAbsentNotUnavailable() throws {
        let (dir, path) = tempJSON()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([:], to: path)

        switch ClaudeMCPSource.lookupJira(from: path) {
        case .absent:
            break
        default:
            Issue.record("{} parsed cleanly with no jira")
        }
    }
}
