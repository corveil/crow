import Foundation
import Testing
import CrowCore
@testable import CrowCursor

@Suite struct CursorAgentLogSourcesTests {
    @Test func cwdFilteredRecursiveSqliteSource() {
        let sources = CursorAgent().logSources(
            worktreePath: "/Users/j/Dev/acme-1", harnessSessionID: nil)
        #expect(sources.count == 1)
        let s = sources[0]
        // Globally stored (a directory, not a file), scanned recursively over the
        // `<chatId>/<subId>/` tree, filtered to `store.db` and attributed by the
        // worktree it ran in.
        #expect(s.selector == .directory)
        #expect(s.format == .sqlite)
        #expect(s.fileExtension == "db")   // excludes store.db-wal / store.db-shm
        #expect(s.fileNamePrefix == "store") // exact `store.db`, in lockstep with backfill
        #expect(s.recursive == true)
        #expect(s.cwdFilter == "/Users/j/Dev/acme-1")
        // Points at the resolved Cursor chats tree (honors $CURSOR_CONFIG_DIR).
        #expect(s.path == CursorHome.chatsDir())
    }

    @Test func harnessSessionIDIsIgnoredForAttribution() {
        // The store is named by a content-hash tree, not a session id, so cwd
        // matching is the selector — the source is identical with or without an id.
        let withID = CursorAgent().logSources(worktreePath: "/a/b", harnessSessionID: "UUID-1")
        let withoutID = CursorAgent().logSources(worktreePath: "/a/b", harnessSessionID: nil)
        #expect(withID == withoutID)
        #expect(withID[0].cwdFilter == "/a/b")
    }
}
