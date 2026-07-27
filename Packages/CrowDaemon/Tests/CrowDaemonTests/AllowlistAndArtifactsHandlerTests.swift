import Foundation
import Testing
import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// #819: the `promote-allowlist` and `list-artifacts` handlers behind the new
/// `crow` verbs. The promote path is the interesting one — it used to answer
/// `{"ok":true}` unconditionally, so a script had no way to tell a granted
/// permission from a failed write.
@Suite("Allowlist + artifacts handlers")
struct AllowlistAndArtifactsHandlerTests {

    @MainActor
    private static func router(allowList: AllowListService?) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, allowList: allowList)
    }

    private static func tempSettingsURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-819-daemon-\(UUID().uuidString)")
            .appendingPathComponent(".claude/settings.json")
    }

    @MainActor
    private static func service(at settings: URL) -> AllowListService {
        AllowListService(appState: AppState(), devRoot: NSTemporaryDirectory(),
                         globalSettingsURL: settings)
    }

    private static func promote(_ patterns: JSONValue?) -> JSONRPCRequest {
        JSONRPCRequest(id: 1, method: "promote-allowlist",
                       params: patterns.map { ["patterns": $0] })
    }

    // MARK: - promote-allowlist: param validation

    @Test @MainActor func rejectsMalformedPatterns() async {
        let settings = Self.tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let router = Self.router(allowList: Self.service(at: settings))

        let bad: [JSONValue?] = [
            nil,                                            // missing
            .string("Read"),                                // not an array
            .array([]),                                     // empty
            .array([.string("  ")]),                        // all blank
            .array([.string("Read"), .int(42)]),            // non-string element
        ]
        for params in bad {
            let resp = await router.handle(request: Self.promote(params))
            #expect(resp.error?.code == RPCErrorCode.invalidParams,
                    "expected \(String(describing: params)) to be rejected")
            #expect(resp.result == nil)
        }
        // A rejected payload must not have created the file either.
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }

    // MARK: - promote-allowlist: honest reporting

    @Test @MainActor func reportsAddedAndAlreadyGlobal() async throws {
        let settings = Self.tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"permissions": {"allow": ["Read"]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        let resp = await Self.router(allowList: Self.service(at: settings))
            .handle(request: Self.promote(.array([.string("Read"), .string("Write")])))

        #expect(resp.error == nil)
        #expect(resp.result?["ok"]?.boolValue == true)
        #expect(resp.result?["added"] == .array([.string("Write")]))
        #expect(resp.result?["already_global"] == .array([.string("Read")]))
        #expect(resp.result?["global_settings_path"]?.stringValue == settings.path)
    }

    /// The headline fix for #819: a write that can't land must not answer ok.
    @Test @MainActor func errorsWhenTheWriteFails() async throws {
        let settings = Self.tempSettingsURL()
        let parent = settings.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try #"{"permissions": {"allow": []}}"#.write(to: settings, atomically: true, encoding: .utf8)
        // Traversable but not writable → the atomic replace fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)

        let resp = await Self.router(allowList: Self.service(at: settings))
            .handle(request: Self.promote(.array([.string("Write")])))

        #expect(resp.error?.code == RPCErrorCode.applicationError)
        #expect(resp.result == nil)
    }

    /// A malformed global settings file is refused, not overwritten.
    @Test @MainActor func errorsRatherThanClobberMalformedSettings() async throws {
        let settings = Self.tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = "{ not json"
        try malformed.write(to: settings, atomically: true, encoding: .utf8)

        let resp = await Self.router(allowList: Self.service(at: settings))
            .handle(request: Self.promote(.array([.string("Read")])))

        #expect(resp.error?.code == RPCErrorCode.applicationError)
        #expect(try String(contentsOf: settings, encoding: .utf8) == malformed)
    }

    @Test @MainActor func errorsWithoutTheAllowlistService() async {
        let resp = await Self.router(allowList: nil)
            .handle(request: Self.promote(.array([.string("Read")])))
        #expect(resp.error?.code == RPCErrorCode.applicationError)
        // The message no longer claims a provider is required — it isn't.
        #expect(resp.error?.message.contains("provider") == false)
    }

    // MARK: - list-artifacts

    @Test @MainActor func includesOnDiskPathAndDir() async throws {
        let sessionID = UUID().uuidString
        let dir = try #require(Artifacts.dir(sessionID: sessionID))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x00]).write(to: dir.appendingPathComponent("shot.png"))

        let resp = await Self.router(allowList: nil).handle(
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
        let resp = await Self.router(allowList: nil).handle(
            request: JSONRPCRequest(id: 1, method: "list-artifacts",
                                    params: ["session_id": .string("not-a-uuid")]))
        #expect(resp.error == nil)
        #expect(resp.result?["images"] == .array([]))
        #expect(resp.result?["dir"] == nil)
    }

    @Test @MainActor func requiresSessionID() async {
        let resp = await Self.router(allowList: nil)
            .handle(request: JSONRPCRequest(id: 1, method: "list-artifacts"))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }
}
