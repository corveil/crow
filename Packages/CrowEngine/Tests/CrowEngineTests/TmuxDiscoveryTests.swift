import Foundation
import Testing
@testable import CrowEngine

@Suite("TmuxDiscovery version parsing")
struct TmuxDiscoveryTests {

    @Test func acceptsModernVersions() {
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 3.6a"))
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 3.5"))
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 3.3"))
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 4.0"))
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 10.0"))
    }

    @Test func rejectsTooOldVersions() {
        #expect(!TmuxDiscovery.meetsMinimumVersion("tmux 3.2"))
        #expect(!TmuxDiscovery.meetsMinimumVersion("tmux 3.0"))
        #expect(!TmuxDiscovery.meetsMinimumVersion("tmux 2.9"))
        #expect(!TmuxDiscovery.meetsMinimumVersion("tmux 1.8"))
    }

    @Test func rejectsUnparseableShapes() {
        #expect(!TmuxDiscovery.meetsMinimumVersion(""))
        #expect(!TmuxDiscovery.meetsMinimumVersion("tmux"))
        #expect(!TmuxDiscovery.meetsMinimumVersion("not-tmux 3.6"))
        #expect(!TmuxDiscovery.meetsMinimumVersion("tmux abc"))
    }

    @Test func toleratesSuffixesAndWhitespace() {
        // tmux occasionally appends a letter (3.6a) or a -next/-master tag.
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 3.6a"))
        #expect(TmuxDiscovery.meetsMinimumVersion("tmux 3.4-rc1"))
        #expect(TmuxDiscovery.meetsMinimumVersion("  tmux 3.6  "))
    }
}
