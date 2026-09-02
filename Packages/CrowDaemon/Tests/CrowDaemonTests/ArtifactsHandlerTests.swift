import Foundation
import Testing
import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// #819: the `list-artifacts` handler behind the `crow list-artifacts` verb —
/// it returns each image's absolute on-disk `path` plus the session's `dir` so
/// an agent that wrote via `$CROW_ARTIFACTS_DIR` can verify what landed.
@Suite("Artifacts handler")
struct ArtifactsHandlerTests {

    @MainActor
    private static func router() -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)
    }

    // MARK: - list-artifacts

    @Test @MainActor func includesOnDiskPathAndDir() async throws {
        let sessionID = UUID().uuidString
        let dir = try #require(Artifacts.dir(sessionID: sessionID))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x00]).write(to: dir.appendingPathComponent("shot.png"))

        let resp = await Self.router().handle(
            request: JSONRPCRequest(id: 1, method: "list-artifacts",
                                    params: ["session_id": .string(sessionID)]))

        #expect(resp.error == nil)
        #expect(resp.result?["dir"]?.stringValue == dir.path)
        let image = try #require(resp.result?["images"]?.arrayValue?.first?.objectValue)
        #expect(image["name"]?.stringValue == "shot.png")
        #expect(image["path"]?.stringValue == dir.appendingPathComponent("shot.png").path)
        // The web caller's existing keys are untouched.
        #expect(image["url"]?.stringValue == "/artifacts/\(sessionID)/shot.png")
    }

    /// A non-UUID keeps the pre-#819 shape (empty list, no error) so the web
    /// caller is unaffected; `dir`/`path` are simply absent.
    @Test @MainActor func omitsDirForNonUUIDSession() async {
        let resp = await Self.router().handle(
            request: JSONRPCRequest(id: 1, method: "list-artifacts",
                                    params: ["session_id": .string("not-a-uuid")]))
        #expect(resp.error == nil)
        #expect(resp.result?["images"] == .array([]))
        #expect(resp.result?["dir"] == nil)
    }

    @Test @MainActor func requiresSessionID() async {
        let resp = await Self.router()
            .handle(request: JSONRPCRequest(id: 1, method: "list-artifacts"))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }
}
