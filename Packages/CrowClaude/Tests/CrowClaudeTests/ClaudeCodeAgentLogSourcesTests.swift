import Foundation
import Testing
import CrowCore
import CrowClaude

@Suite struct ClaudeCodeAgentLogSourcesTests {
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    @Test func directorySourceWhenNoSessionID() {
        let sources = ClaudeCodeAgent().logSources(
            worktreePath: "/Users/j/Dev/acme-1", harnessSessionID: nil)
        #expect(sources.count == 1)
        let s = sources[0]
        #expect(s.selector == .directory)
        #expect(s.format == .jsonl)
        #expect(s.fileExtension == "jsonl")
        #expect(s.path == home + "/.claude/projects/-Users-j-Dev-acme-1")
    }

    @Test func exactFileWhenSessionIDKnown() {
        let sources = ClaudeCodeAgent().logSources(
            worktreePath: "/a/b", harnessSessionID: "UUID-123")
        #expect(sources.count == 1)
        #expect(sources[0].selector == .file)
        #expect(sources[0].format == .jsonl)
        #expect(sources[0].path == home + "/.claude/projects/-a-b/UUID-123.jsonl")
    }

    @Test func blankSessionIDFallsBackToDirectory() {
        let sources = ClaudeCodeAgent().logSources(worktreePath: "/a/b", harnessSessionID: "   ")
        #expect(sources[0].selector == .directory)
    }
}
