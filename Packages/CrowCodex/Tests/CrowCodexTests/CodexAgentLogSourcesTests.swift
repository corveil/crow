import Foundation
import Testing
import CrowCore
@testable import CrowCodex

@Suite struct CodexAgentLogSourcesTests {
    @Test func cwdFilteredRecursiveSessionsSource() {
        let sources = OpenAICodexAgent().logSources(
            worktreePath: "/Users/j/Dev/acme-1", harnessSessionID: nil)
        #expect(sources.count == 1)
        let s = sources[0]
        // Globally stored, so a directory (not a file) — recursive over the date
        // tree, filtered to `.jsonl`, attributed by the worktree it ran in.
        #expect(s.selector == .directory)
        #expect(s.format == .logDir)
        #expect(s.fileExtension == "jsonl")
        #expect(s.fileNamePrefix == "rollout-") // only Codex rollouts, in lockstep with backfill
        #expect(s.recursive == true)
        #expect(s.cwdFilter == "/Users/j/Dev/acme-1")
        // Points at the resolved Codex sessions tree (honors $CODEX_HOME), not a
        // hardcoded `~/.codex` — asserted against the shared resolver.
        #expect(s.path == CodexHome.sessionsDir())
    }

    @Test func harnessSessionIDIsIgnoredForAttribution() {
        // Unlike Claude, a known session id does not name the file (the rollout
        // filename also carries a timestamp) — cwd-matching is the selector, so
        // the source is identical whether or not an id is passed.
        let withID = OpenAICodexAgent().logSources(worktreePath: "/a/b", harnessSessionID: "UUID-1")
        let withoutID = OpenAICodexAgent().logSources(worktreePath: "/a/b", harnessSessionID: nil)
        #expect(withID == withoutID)
        #expect(withID[0].cwdFilter == "/a/b")
    }
}
