import Foundation
import Testing
@testable import CrowOpenCode

@Suite struct OpenCodeHomeTests {
    @Test func defaultsToLocalShareWhenXDGUnset() {
        let dir = OpenCodeHome.dataDir(environment: [:])
        #expect(dir.hasSuffix("/.local/share/opencode"))
        #expect(!dir.hasPrefix("~")) // tilde expanded
    }

    @Test func honorsXDGDataHome() {
        let env = ["XDG_DATA_HOME": "/custom/xdg"]
        #expect(OpenCodeHome.dataDir(environment: env) == "/custom/xdg/opencode")
        #expect(OpenCodeHome.databasePath(environment: env) == "/custom/xdg/opencode/opencode.db")
    }

    @Test func emptyXDGDataHomeTreatedAsUnset() {
        // An empty `XDG_DATA_HOME=` must fall through to ~/.local/share, never a
        // relative `opencode` path (XDG spec + parity with LaunchScaffold).
        let dir = OpenCodeHome.dataDir(environment: ["XDG_DATA_HOME": ""])
        #expect(dir.hasSuffix("/.local/share/opencode"))
    }

    @Test func databasePathComposesUnderDataDir() {
        let env = ["XDG_DATA_HOME": "/x"]
        #expect(OpenCodeHome.databasePath(environment: env)
                == (OpenCodeHome.dataDir(environment: env) as NSString).appendingPathComponent("opencode.db"))
    }
}
