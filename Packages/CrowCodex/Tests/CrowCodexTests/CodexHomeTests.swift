import Foundation
import Testing
@testable import CrowCodex

@Suite struct CodexHomeTests {
    @Test func honorsCodexHomeWhenSetAndNonEmpty() {
        let env = ["CODEX_HOME": "/custom/codex"]
        #expect(CodexHome.path(environment: env) == "/custom/codex")
        #expect(CodexHome.sessionsDir(environment: env) == "/custom/codex/sessions")
    }

    @Test func emptyCodexHomeIsTreatedAsUnset() {
        // An empty `CODEX_HOME=` must NOT yield a CWD-relative path — it falls
        // back to `~/.codex` like every other Crow ↔ Codex path.
        let home = NSString(string: "~/.codex").expandingTildeInPath
        #expect(CodexHome.path(environment: ["CODEX_HOME": ""]) == home)
        #expect(CodexHome.sessionsDir(environment: ["CODEX_HOME": ""]) == home + "/sessions")
    }

    @Test func fallsBackToTildeCodexWhenUnset() {
        let home = NSString(string: "~/.codex").expandingTildeInPath
        #expect(CodexHome.path(environment: [:]) == home)
        #expect(CodexHome.sessionsDir(environment: [:]) == home + "/sessions")
    }
}
