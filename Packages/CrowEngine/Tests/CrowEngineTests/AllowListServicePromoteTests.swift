import CrowCore
import Foundation
import Testing
@testable import CrowEngine

/// Coverage for `AllowListService.promoteToGlobal` (#819). Promoting used to
/// swallow every write failure into an `NSLog` — so the `promote-allowlist` RPC
/// answered `{"ok":true}` for a write that never landed — and, worse, a
/// `settings.json` that existed but didn't parse was treated as an empty
/// dictionary and written back containing only `permissions.allow`, destroying
/// the user's hooks / env / model / mcpServers. Both paths now throw.
///
/// Every test injects `globalSettingsURL` into a temp dir; none of them touch
/// the real `~/.claude/settings.json`.
@Suite("AllowListService promote")
@MainActor
struct AllowListServicePromoteTests {

    /// A fresh temp directory plus the settings path inside it. The file is not
    /// created — callers seed it (or don't) per case.
    private static func makeTempSettingsURL(
        createParent: Bool = true
    ) throws -> (dir: URL, settings: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-819-\(UUID().uuidString)")
        if createParent {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (dir, dir.appendingPathComponent(".claude/settings.json"))
    }

    private static func makeService(settings: URL) -> AllowListService {
        AllowListService(appState: AppState(), devRoot: "/tmp", globalSettingsURL: settings)
    }

    private static func seed(_ url: URL, _ json: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The data-loss guard (#819)

    @Test func preservesUnrelatedGlobalSettingsKeys() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.seed(settings, """
        {
          "model": "opus",
          "hooks": { "Stop": [{ "command": "say done" }] },
          "permissions": { "allow": ["Read"], "deny": ["Bash(rm:*)"] }
        }
        """)

        try Self.makeService(settings: settings).promoteToGlobal(patterns: ["Write"])

        let json = try Self.readJSON(settings)
        #expect(json["model"] as? String == "opus")
        #expect(json["hooks"] != nil)
        let permissions = try #require(json["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Read", "Write"])
        // Sibling keys inside `permissions` survive too, not just siblings of it.
        #expect(permissions["deny"] as? [String] == ["Bash(rm:*)"])
    }

    @Test func throwsRatherThanClobberMalformedSettings() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let malformed = "{ not json"
        try Self.seed(settings, malformed)

        let service = Self.makeService(settings: settings)
        #expect(throws: (any Error).self) {
            try service.promoteToGlobal(patterns: ["Read"])
        }

        // The point of the fix: the file is untouched, not rewritten as
        // `{"permissions":{"allow":["Read"]}}`.
        #expect(try String(contentsOf: settings, encoding: .utf8) == malformed)
    }

    @Test func throwsWhenTopLevelJSONIsNotAnObject() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Valid JSON, wrong shape — `as? [String: Any]` fails, and the old
        // `try?` + `as?` combination degraded this to `[:]` just the same.
        try Self.seed(settings, "[1, 2, 3]")

        let service = Self.makeService(settings: settings)
        #expect(throws: (any Error).self) {
            try service.promoteToGlobal(patterns: ["Read"])
        }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "[1, 2, 3]")
    }

    // MARK: - Honest success / failure reporting

    @Test func reportsAddedVersusAlreadyGlobal() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.seed(settings, #"{"permissions": {"allow": ["Read"]}}"#)

        let promotion = try Self.makeService(settings: settings)
            .promoteToGlobal(patterns: ["Read", "Write"])

        #expect(promotion.added == ["Write"])
        #expect(promotion.alreadyGlobal == ["Read"])
        #expect(promotion.globalSettingsPath == settings.path)
    }

    @Test func promotingAnAlreadyGlobalPatternIsIdempotent() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.seed(settings, #"{"permissions": {"allow": ["Read"]}}"#)

        let service = Self.makeService(settings: settings)
        let promotion = try service.promoteToGlobal(patterns: ["Read"])

        #expect(promotion.added.isEmpty)
        #expect(promotion.alreadyGlobal == ["Read"])
        let permissions = try #require(try Self.readJSON(settings)["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Read"])
    }

    @Test func throwsWhenWriteFails() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: settings.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: dir)
        }
        try Self.seed(settings, #"{"permissions": {"allow": ["Read"]}}"#)
        // Read+execute only: the parent directory can be traversed but not
        // written, so the atomic replace fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: settings.deletingLastPathComponent().path)

        let service = Self.makeService(settings: settings)
        #expect(throws: (any Error).self) {
            try service.promoteToGlobal(patterns: ["Write"])
        }
    }

    // MARK: - Fresh-install and wiring

    @Test func createsMissingParentDirectory() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Neither the temp dir's `.claude/` nor the file exists yet.
        #expect(!FileManager.default.fileExists(atPath: settings.path))

        let promotion = try Self.makeService(settings: settings)
            .promoteToGlobal(patterns: ["Read"])

        #expect(promotion.added == ["Read"])
        let permissions = try #require(try Self.readJSON(settings)["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Read"])
    }

    @Test func treatsAnEmptyFileAsNoSettings() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A zero-byte file isn't valid JSON, but it carries nothing to lose —
        // starting from `[:]` is right here, unlike the malformed case.
        try Self.seed(settings, "")

        let promotion = try Self.makeService(settings: settings)
            .promoteToGlobal(patterns: ["Read"])

        #expect(promotion.added == ["Read"])
    }

    @Test func scanReadsTheInjectedGlobalPath() throws {
        let (dir, settings) = try Self.makeTempSettingsURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.seed(settings, #"{"permissions": {"allow": ["Bash(npm test:*)"]}}"#)

        let appState = AppState()
        let service = AllowListService(
            appState: appState, devRoot: "/tmp", globalSettingsURL: settings)
        service.scan()

        // Proves `scan()` uses the injected URL rather than the real $HOME.
        let entry = try #require(appState.allowEntries.first { $0.pattern == "Bash(npm test:*)" })
        #expect(entry.isInGlobal)
    }
}
