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

    @Test func configHomeHonorsXDGConfigHomeWhenSetAndNonEmpty() {
        let env = ["XDG_CONFIG_HOME": "/custom/config"]
        #expect(MuseHome.configHome(environment: env) == "/custom/config/muse")
        #expect(MuseHome.settingsPath(environment: env) == "/custom/config/muse/settings.json")
    }

    @Test func emptyXDGConfigHomeIsTreatedAsUnset() {
        let home = NSString(string: "~/.config/muse").expandingTildeInPath
        #expect(MuseHome.configHome(environment: ["XDG_CONFIG_HOME": ""]) == home)
        #expect(MuseHome.settingsPath(environment: ["XDG_CONFIG_HOME": ""]) == home + "/settings.json")
    }

    @Test func configHomeFallsBackToTildeConfigWhenUnset() {
        let home = NSString(string: "~/.config/muse").expandingTildeInPath
        #expect(MuseHome.configHome(environment: [:]) == home)
        #expect(MuseHome.settingsPath(environment: [:]) == home + "/settings.json")
    }

    @Test func configHomeIsDistinctFromDataHome() {
        let env = ["XDG_DATA_HOME": "/data", "XDG_CONFIG_HOME": "/cfg"]
        #expect(MuseHome.path(environment: env) == "/data/muse")
        #expect(MuseHome.configHome(environment: env) == "/cfg/muse")
    }
}
