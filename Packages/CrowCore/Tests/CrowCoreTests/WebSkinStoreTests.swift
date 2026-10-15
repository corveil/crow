import Foundation
import Testing
@testable import CrowCore

/// CROW-1334: custom skins — the store, the color check, and contrast warnings.
@Suite struct WebSkinStoreTests {
    private static let webDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // CrowCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // CrowCore
        .deletingLastPathComponent()      // Packages
        .appendingPathComponent("CrowDaemon/Sources/CrowDaemon/Resources/web")

    private static func base() throws -> WebSkinBase {
        WebSkinBase.parse(themeCSS: try String(
            contentsOf: webDir.appendingPathComponent("theme.css"), encoding: .utf8))
    }

    private static func bundled(_ id: String) throws -> WebSkin {
        try WebSkinStore.read(path: webDir.appendingPathComponent("skins/\(id).json").path)
    }

    private func withStore(_ body: (WebSkinStore) throws -> Void) rethrows {
        let store = WebSkinStore.temporary()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try body(store)
    }

    // MARK: - Store

    @Test func saveListGetRemoveRoundTrip() throws {
        try withStore { store in
            #expect(store.skins().isEmpty, "a missing directory reads as empty")
            let skin = WebSkin(id: "dusty", name: "Dusty", dark: ["--accent": "#7AA2F7"])
            try store.save(skin)
            #expect(store.skins() == [skin])
            #expect(store.skin(id: "dusty") == skin)
            #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("dusty.json").path))
            #expect(throws: WebSkinStoreError.alreadyExists("dusty")) { try store.save(skin) }
            try store.remove(id: "dusty")
            #expect(store.skins().isEmpty)
            #expect(throws: WebSkinStoreError.missing("dusty")) { try store.remove(id: "dusty") }
        }
    }

    @Test func saveRefusesAnInvalidSkin() throws {
        try withStore { store in
            let skin = WebSkin(id: "x", name: "X", dark: ["--accent": "12px", "--nope": "#fff"])
            #expect(throws: WebSkinStoreError.invalid([
                "dark: --accent must be a color, got \"12px\"",
                "dark: --nope is not a skin token (see docs/web-skins.md)",
            ])) { try store.save(skin) }
            #expect(!store.fileExists(id: "x"))
        }
    }

    @Test func unusableFilesAreListedWithTheirProblemsButNotServed() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            func put(_ name: String, _ text: String) throws {
                try Data(text.utf8).write(to: store.directory.appendingPathComponent(name))
            }
            try put("good.json", #"{"id":"good","name":"Good","dark":{}}"#)
            try put("misnamed.json", #"{"id":"other","name":"Other","dark":{}}"#)
            try put("broken.json", "{ not json")
            try put("notes.txt", "ignored")
            #expect(store.skins().map(\.id) == ["good"])
            let problems = Dictionary(uniqueKeysWithValues: store.entries().map { ($0.file, $0.problems) })
            #expect(problems["misnamed.json"] == ["file must be named other.json"])
            #expect(problems["broken.json"] == ["Not a skin file: not valid JSON"])
            #expect(problems["notes.txt"] == nil)
        }
    }

    /// `add` must reject malformed files with a reason that names the field.
    @Test(arguments: [
        (#"{"name":"X","dark":{}}"#, "Not a skin file: missing required key \"id\""),
        (#"{"id":"x","name":"X","dark":[]}"#, "Not a skin file: \"dark\" must be an object"),
        (#"{"id":"x","name":"X","dark":{"--accent":7}}"#, "Not a skin file: \"dark.--accent\" must be a string"),
        ("[]", "Not a skin file: the top level must be an object"),
    ])
    func malformedFilesExplainThemselves(text: String, message: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("skin-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try WebSkinStore.read(path: file.path)
            Issue.record("expected \(text) to be rejected")
        } catch let error as WebSkinStoreError {
            #expect(error.localizedDescription == message)
        }
    }

    @Test func readRefusesMissingAndOversizedFiles() throws {
        #expect(throws: WebSkinStoreError.fileNotFound("/no/such/skin.json")) {
            try WebSkinStore.read(path: "/no/such/skin.json")
        }
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).json")
        try Data(repeating: 0x20, count: WebSkinStore.maxBytes + 1).write(to: big)
        defer { try? FileManager.default.removeItem(at: big) }
        #expect(throws: WebSkinStoreError.tooLarge(maxBytes: WebSkinStore.maxBytes)) {
            try WebSkinStore.read(path: big.path)
        }
    }

    @Test func slugsAndAssignments() {
        #expect(WebSkinStore.slug("Dusty") == "dusty")
        #expect(WebSkinStore.slug("  Dusty Rose 2! ") == "dusty-rose-2")
        #expect(WebSkinStore.slug("✨✨") == nil)
        #expect(WebSkinStore.slug(String(repeating: "a", count: 63) + " b") == String(repeating: "a", count: 63))
        #expect(WebSkinStore.assignment("accent=#7AA2F7")! == ("--accent", "#7AA2F7"))
        #expect(WebSkinStore.assignment("--term-bg = rgb(1, 2, 3)")! == ("--term-bg", "rgb(1, 2, 3)"))
        #expect(WebSkinStore.assignment("accent") == nil)
        #expect(WebSkinStore.assignment("=#fff") == nil)
    }

    // MARK: - Color check

    @Test func colorTokensMustHoldColors() {
        for good in ["#fff", "#7AA2F7", "rgba(1, 2, 3, 0.5)", "rgb(1 2 3 / 50%)", "hsl(200 50% 40%)",
                     "var(--pink)", "color-mix(in srgb, var(--accent) 20%, transparent)",
                     "RebeccaPurple", "transparent", "oklch(70% 0.1 250)"] {
            #expect(WebSkin.isColorValue(good), "\(good)")
        }
        for bad in ["12px", "bold", "Inter, sans-serif", "calc(1px + 2px)", "#12", "none"] {
            #expect(!WebSkin.isColorValue(bad), "\(bad)")
        }
        let skin = WebSkin(id: "x", name: "X", dark: [
            "--accent": "bold", "--shadow-card": "0 1px 2px var(--overlay)", "--bg-deep": "navy",
        ])
        #expect(skin.validationErrors() == [.notAColor(mode: "dark", token: "--accent", value: "bold")],
                "shadows are not colors; named colors are")
    }

    /// The new color rule must not reject anything the built-ins (or Corveil
    /// flattened out of theme.css) already ship.
    @Test func builtInsAndFlattenedCorveilStillValidate() throws {
        let base = try Self.base()
        for id in ["corveil", "corveil-classic", "graphite"] {
            let skin = try Self.bundled(id)
            #expect(skin.validationErrors().isEmpty, "\(id): \(skin.validationErrors())")
            let flat = base.flattened(skin)
            #expect(flat.validationErrors().isEmpty, "\(id) flattened: \(flat.validationErrors())")
            #expect(Set(flat.dark.keys) == Set(WebSkin.tokens), "\(id): get must list every token")
        }
    }

    // MARK: - Contrast

    @Test func builtInsHaveNoContrastWarnings() throws {
        let base = try Self.base()
        for id in ["corveil", "corveil-classic", "graphite"] {
            #expect(WebSkinContrast.warnings(for: try Self.bundled(id), base: base).isEmpty, "\(id)")
        }
    }

    @Test func lowContrastTextWarnsWithTheMeasuredRatio() throws {
        let skin = WebSkin(id: "murky", name: "Murky",
                           dark: ["--bg-deep": "#000000", "--text-muted": "#333333"])
        let warnings = WebSkinContrast.warnings(for: skin, base: try Self.base())
        let muted = try #require(warnings.first {
            $0.foreground == "--text-muted" && $0.background == "--bg-deep"
        })
        #expect(muted.mode == "dark")
        #expect(muted.ratio == 1.66)
        #expect(muted.minimum == 4.5)
        #expect(muted.description == "dark: --text-muted on --bg-deep is 1.66:1, below 4.5:1")
    }

    @Test func scrollThumbIsANonTextPairAtThreeToOne() throws {
        // #555 over #1E1E1E is ~2.2:1 — a text failure would also be a 3:1 failure,
        // so pick a thumb between the two floors to prove it's held to 3, not 4.5.
        let passes = WebSkin(id: "a", name: "A", dark: ["--term-bg": "#000000", "--scroll-thumb": "#5A5A5A"])
        let fails = WebSkin(id: "b", name: "B", dark: ["--term-bg": "#1E1E1E", "--scroll-thumb": "#333333"])
        let base = try Self.base()
        #expect(!WebSkinContrast.warnings(for: passes, base: base).contains { $0.foreground == "--scroll-thumb" })
        let thumb = try #require(WebSkinContrast.warnings(for: fails, base: base).first {
            $0.foreground == "--scroll-thumb"
        })
        #expect(thumb.minimum == 3)
        #expect(thumb.ratio < 3)
    }

    @Test func lightModeIsCheckedOnItsOwnPalette() throws {
        let skin = WebSkin(id: "l", name: "L", dark: [:], light: ["--text-primary": "#EEEEEE"])
        let warnings = WebSkinContrast.warnings(for: skin, base: try Self.base())
        #expect(!warnings.isEmpty)
        #expect(warnings.allSatisfy { $0.mode == "light" })
    }

    /// Ticket acceptance: `crow skin create --from corveil-classic --name "Dusty"
    /// --set accent=#7AA2F7` yields a valid skin (the daemon builds it this way).
    @Test func ticketExampleSkinIsValid() throws {
        let classic = try Self.bundled("corveil-classic")
        let id = try #require(WebSkinStore.slug("Dusty"))
        let (token, value) = try #require(WebSkinStore.assignment("accent=#7AA2F7"))
        let dusty = WebSkin(id: id, name: "Dusty", dark: classic.dark.merging([token: value]) { $1 },
                            light: classic.light, fonts: classic.fonts)
        #expect(dusty.id == "dusty")
        #expect(dusty.validationErrors().isEmpty)
        #expect(dusty.css().contains("--accent: #7AA2F7;"))
        try withStore { store in
            try store.save(dusty)
            #expect(store.skin(id: "dusty")?.dark["--accent"] == "#7AA2F7")
        }
    }

    @Test func colorParsingFollowsVarsAndCompositesAlpha() {
        let map = ["--bg": "#000", "--fg": "var(--missing, rgba(255, 255, 255, 0.5))", "--a": "#ffffff80"]
        let bg = WebSkinContrast.color("--bg", in: map, over: nil)
        #expect(bg == .init(r: 0, g: 0, b: 0))
        #expect(WebSkinContrast.color("--fg", in: map, over: bg) == .init(r: 127.5, g: 127.5, b: 127.5))
        #expect(WebSkinContrast.color("--a", in: map, over: nil) == nil, "alpha needs a background")
        #expect(WebSkinContrast.color("--a", in: map, over: bg)!.r > 127)
    }
}
