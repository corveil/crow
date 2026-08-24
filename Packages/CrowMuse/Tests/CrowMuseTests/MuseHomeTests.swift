import Foundation
import Testing
@testable import CrowMuse

@Suite struct MuseHomeTests {
    @Test func honorsXDGDataHomeWhenSetAndNonEmpty() {
        let env = ["XDG_DATA_HOME": "/custom/data"]
        #expect(MuseHome.path(environment: env) == "/custom/data/muse")
        #expect(MuseHome.sessionsDir(environment: env) == "/custom/data/muse/sessions")
    }

    @Test func emptyXDGDataHomeIsTreatedAsUnset() {
        // An empty `XDG_DATA_HOME=` must NOT yield a CWD-relative path — it falls
        // back to `~/.local/share/muse` like every other Crow ↔ harness home path.
        let home = NSString(string: "~/.local/share/muse").expandingTildeInPath
        #expect(MuseHome.path(environment: ["XDG_DATA_HOME": ""]) == home)
        #expect(MuseHome.sessionsDir(environment: ["XDG_DATA_HOME": ""]) == home + "/sessions")
    }

    @Test func fallsBackToTildeLocalShareWhenUnset() {
        let home = NSString(string: "~/.local/share/muse").expandingTildeInPath
        #expect(MuseHome.path(environment: [:]) == home)
        #expect(MuseHome.sessionsDir(environment: [:]) == home + "/sessions")
    }
}
