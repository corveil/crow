import Foundation
import Testing
@testable import CrowGrok

@Suite struct GrokHomeTests {
    @Test func honorsGrokHomeWhenSetAndNonEmpty() {
        let env = ["GROK_HOME": "/custom/grok"]
        #expect(GrokHome.path(environment: env) == "/custom/grok")
        #expect(GrokHome.sessionsDir(environment: env) == "/custom/grok/sessions")
    }

    @Test func emptyGrokHomeIsTreatedAsUnset() {
        // An empty `GROK_HOME=` must NOT yield a CWD-relative path — it falls back
        // to `~/.grok` like every other Crow ↔ Grok path.
        let home = NSString(string: "~/.grok").expandingTildeInPath
        #expect(GrokHome.path(environment: ["GROK_HOME": ""]) == home)
        #expect(GrokHome.sessionsDir(environment: ["GROK_HOME": ""]) == home + "/sessions")
    }

    @Test func fallsBackToTildeGrokWhenUnset() {
        let home = NSString(string: "~/.grok").expandingTildeInPath
        #expect(GrokHome.path(environment: [:]) == home)
        #expect(GrokHome.sessionsDir(environment: [:]) == home + "/sessions")
    }
}
