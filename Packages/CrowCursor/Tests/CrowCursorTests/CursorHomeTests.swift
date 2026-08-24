import Foundation
import Testing
@testable import CrowCursor

@Suite struct CursorHomeTests {
    @Test func honorsCursorConfigDirWhenSetAndNonEmpty() {
        let env = ["CURSOR_CONFIG_DIR": "/custom/cursor"]
        #expect(CursorHome.path(environment: env) == "/custom/cursor")
        #expect(CursorHome.chatsDir(environment: env) == "/custom/cursor/chats")
    }

    @Test func emptyCursorConfigDirIsTreatedAsUnset() {
        // An empty `CURSOR_CONFIG_DIR=` must NOT yield a CWD-relative path — it
        // falls back to `~/.cursor` like every other Crow ↔ Cursor path.
        let home = NSString(string: "~/.cursor").expandingTildeInPath
        #expect(CursorHome.path(environment: ["CURSOR_CONFIG_DIR": ""]) == home)
        #expect(CursorHome.chatsDir(environment: ["CURSOR_CONFIG_DIR": ""]) == home + "/chats")
    }

    @Test func fallsBackToTildeCursorWhenUnset() {
        let home = NSString(string: "~/.cursor").expandingTildeInPath
        #expect(CursorHome.path(environment: [:]) == home)
        #expect(CursorHome.chatsDir(environment: [:]) == home + "/chats")
    }
}
