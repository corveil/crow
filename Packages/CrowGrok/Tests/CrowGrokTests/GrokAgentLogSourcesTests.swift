import Foundation
import Testing
import CrowCore
@testable import CrowGrok

@Suite struct GrokAgentLogSourcesTests {
    @Test func perWorktreeUrlEncodedDirectorySource() {
        let worktree = "/Users/j/Dev/acme-1"
        let sources = GrokAgent().logSources(worktreePath: worktree, harnessSessionID: nil)
        #expect(sources.count == 1)
        let s = sources[0]
        // Partitioned by working directory, so a directory (not a file) — recursive
        // to reach the `<session-uuid>/` subdirs, filtered to `chat_history.jsonl`,
        // and NOT cwd-filtered (the directory name IS the cwd).
        #expect(s.selector == .directory)
        #expect(s.format == .jsonl)
        #expect(s.fileExtension == "jsonl")
        #expect(s.fileNamePrefix == "chat_history") // excludes events/hunk/prompt_history
        #expect(s.recursive == true)
        #expect(s.cwdFilter == nil)
        // Points at `<grokSessionsDir>/<url-encoded-cwd>` — honors $GROK_HOME and
        // encodes the worktree path the way Grok names the directory.
        let expected = (GrokHome.sessionsDir() as NSString)
            .appendingPathComponent(GrokSessionDir.encode(worktree))
        #expect(s.path == expected)
        // The encoded component round-trips back to the worktree — attribution is
        // exact by construction.
        #expect(GrokSessionDir.decode((s.path as NSString).lastPathComponent) == worktree)
    }

    @Test func harnessSessionIDIsIgnoredForAttribution() {
        // The session id names a subdirectory, not the file (the filename is always
        // `chat_history.jsonl`), so the source is identical whether or not an id is
        // passed — mirroring Codex.
        let withID = GrokAgent().logSources(worktreePath: "/a/b", harnessSessionID: "UUID-1")
        let withoutID = GrokAgent().logSources(worktreePath: "/a/b", harnessSessionID: nil)
        #expect(withID == withoutID)
    }
}
