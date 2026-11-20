import Foundation
import Testing
import CrowClaude
import CrowCore
import CrowPersistence
@testable import CrowEngine

/// CROW-1484: the tool env script every gateway-routed Claude session names in
/// `CLAUDE_ENV_FILE` lives beside `store.json`. That keeps it out of every
/// worktree in production and inside the injected temp directory in tests, so
/// no launch path a test drives can write the live app-support dir (ADR 0012).
@Suite("Tool env script location")
@MainActor
struct ToolEnvScriptPathTests {
    @Test func scriptSitsBesideTheInjectedStore() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-1484-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = SessionService(store: JSONStore(directory: tmp), appState: AppState())

        let path = service.toolEnvScriptPath
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            == tmp.standardizedFileURL)
        #expect(ClaudeToolEnvScript.isCrowScript(path))
    }
}
