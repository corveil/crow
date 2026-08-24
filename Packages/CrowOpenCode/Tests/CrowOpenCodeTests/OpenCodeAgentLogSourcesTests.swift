import Foundation
import Testing
import CrowCore
@testable import CrowOpenCode

@Suite struct OpenCodeAgentLogSourcesTests {
    @Test func cwdFilteredDatabaseSource() {
        let sources = OpenCodeAgent().logSources(
            worktreePath: "/Users/j/Dev/acme-1", harnessSessionID: nil)
        #expect(sources.count == 1)
        let s = sources[0]
        // One SQLite database holds every session across every worktree, so a single
        // `.file` source at `opencode.db`, attributed by row (cwd) inside
        // `OpenCodeStore` — not a per-file path filter.
        #expect(s.selector == .file)
        #expect(s.format == .openCodeStore)
        #expect(s.cwdFilter == "/Users/j/Dev/acme-1")
        // Points at the resolved OpenCode database (honors $XDG_DATA_HOME).
        #expect(s.path == OpenCodeHome.databasePath())
    }

    @Test func harnessSessionIDIsIgnoredForAttribution() {
        // cwd-matching is the selector — a known id doesn't name a single file in
        // the shared database, so the source is identical either way.
        let withID = OpenCodeAgent().logSources(worktreePath: "/a/b", harnessSessionID: "ses_x")
        let withoutID = OpenCodeAgent().logSources(worktreePath: "/a/b", harnessSessionID: nil)
        #expect(withID == withoutID)
        #expect(withID[0].cwdFilter == "/a/b")
    }
}
