import Foundation
import Testing
@testable import CrowCore

/// CROW-1333: the skin contract. The token list, the bundled skins and the
/// Corveil palette in `theme.css` are three files that have to agree, and the
/// contrast floor in the ticket's acceptance is checked here per skin and mode.
@Suite struct WebSkinTests {
    // MARK: - Fixtures

    private static let webDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // CrowCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // CrowCore
        .deletingLastPathComponent()      // Packages
        .appendingPathComponent("CrowDaemon/Sources/CrowDaemon/Resources/web")

    private static func themeCSS() throws -> String {
        let raw = try String(contentsOf: webDir.appendingPathComponent("theme.css"), encoding: .utf8)
        return raw.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    }

    /// Declarations inside the first rule opened by `selector`.
    private static func declarations(after selector: String, in css: String) throws -> [String: String] {
        let start = try #require(css.range(of: selector + " {"), "theme.css lost its \(selector) block")
        let rest = css[start.upperBound...]
        let end = try #require(rest.firstIndex(of: "}"))
        var map: [String: String] = [:]
        for decl in rest[..<end].split(separator: ";") {
            let trimmed = decl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { continue }
            map[String(trimmed[..<colon])] = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    private static func corveil() throws -> (dark: [String: String], light: [String: String]) {
        let css = try themeCSS()
        return (try declarations(after: ":root", in: css),
                try declarations(after: "[data-theme=\"light\"]", in: css))
    }

    private static func bundledSkins() throws -> [(file: String, skin: WebSkin)] {
        let dir = webDir.appendingPathComponent("skins")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        return try files.map { file in
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            return (file, try JSONDecoder().decode(WebSkin.self, from: data))
        }
    }

    // MARK: - Contract

    @Test func tokenListMatchesThemeCSS() throws {
        let corveil = try Self.corveil()
        let declared = Set(corveil.dark.keys).union(corveil.light.keys)
            .subtracting(WebSkin.brandPrimitives)
        #expect(declared == Set(WebSkin.tokens),
                "theme.css and WebSkin.tokens disagree: only in CSS \(declared.subtracting(WebSkin.tokens).sorted()), only in Swift \(Set(WebSkin.tokens).subtracting(declared).sorted())")
        #expect(WebSkin.tokens.count == Set(WebSkin.tokens).count, "WebSkin.tokens has a duplicate")
    }

    @Test func bundledSkinsAreValidAndNamedByID() throws {
        let skins = try Self.bundledSkins()
        #expect(Set(skins.map(\.skin.id)) == ["corveil", "corveil-classic", "graphite"])
        for (file, skin) in skins {
            #expect(file == "\(skin.id).json", "\(file) must be named after its id")
            #expect(skin.validationErrors().isEmpty, "\(file): \(skin.validationErrors())")
        }
        let classic = try #require(skins.first { $0.skin.id == "corveil-classic" }?.skin)
        #expect(!classic.supportsLight, "Corveil Classic is dark only, like the pre-#1317 UI")
        #expect(classic.dark["--accent"] == "#DDC482", "Classic keeps the pre-#1317 gold")
    }

    /// Ticket acceptance: no color literal outside the skin variables, so a skin
    /// reaches every surface. theme.css is where the palette is written down;
    /// the only allowed literal elsewhere is the pre-CSS `theme-color` meta in
    /// the two HTML shells (theme.js replaces it from `--bg-deep` once styles
    /// load). Comments are stripped first: issue refs like `#637` are not colors.
    @Test func noHardCodedColorsOutsideTheSkinVariables() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.webDir.path)
            .filter { ($0.hasSuffix(".css") || $0.hasSuffix(".js") || $0.hasSuffix(".html")) && $0 != "theme.css" }
        #expect(files.contains("app.css") && files.contains("login.html"), "web dir moved?")
        let allowed = ["<meta name=\"theme-color\" content=\"#0A060B\">"]
        let color = #"(?<![&\w])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\w-])|\b(?:rgba?|hsla?)\("#
        for file in files.sorted() {
            var text = try String(contentsOf: Self.webDir.appendingPathComponent(file), encoding: .utf8)
            for pattern in [#"/\*[\s\S]*?\*/"#, #"<!--[\s\S]*?-->"#, #"(?<![:"'\\])//[^\n]*"#] {
                text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            for line in text.split(separator: "\n") where line.range(of: color, options: .regularExpression) != nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                #expect(allowed.contains(trimmed), "\(file): hard-coded color outside theme.css — use a skin token: \(trimmed)")
            }
        }
    }

    // MARK: - Contrast (ticket acceptance: status text ≥ 4.5:1 in every skin and mode)

    private static let textTokens = [
        "--text-primary", "--text-secondary", "--text-muted", "--accent", "--accent-muted",
        "--green", "--yellow", "--orange", "--red", "--blue", "--purple",
        "--grade-a", "--grade-b", "--grade-c", "--grade-d", "--grade-f",
    ]
    private static let backgroundTokens = ["--bg-deep", "--bg-surface", "--bg-card", "--bg-elev"]

    @Test func everySkinAndModeClearsTextContrast() throws {
        let corveil = try Self.corveil()
        for (file, skin) in try Self.bundledSkins() {
            var modes: [(String, [String: String])] = [
                ("dark", corveil.dark.merging(skin.dark) { $1 }),
            ]
            if let light = skin.light {
                modes.append(("light", corveil.dark.merging(corveil.light) { $1 }.merging(light) { $1 }))
            }
            for (mode, map) in modes {
                for bgToken in Self.backgroundTokens {
                    let bg = try #require(Self.color(bgToken, in: map, over: nil), "\(file) \(mode) \(bgToken)")
                    for fgToken in Self.textTokens {
                        let fg = try #require(Self.color(fgToken, in: map, over: bg), "\(file) \(mode) \(fgToken)")
                        let ratio = Self.contrast(fg, bg)
                        #expect(ratio >= 4.5,
                                "\(file) \(mode): \(fgToken) on \(bgToken) is \(String(format: "%.2f", ratio)):1, needs 4.5")
                    }
                }
                let fill = try #require(Self.color("--accent-fill", in: map, over: nil))
                let onFill = try #require(Self.color("--on-accent", in: map, over: fill))
                #expect(Self.contrast(onFill, fill) >= 4.5, "\(file) \(mode): --on-accent on --accent-fill")
                // WCAG 2.2 §1.4.11: the terminal scroll thumb is a 3:1 control.
                let term = try #require(Self.color("--term-bg", in: map, over: nil))
                let thumb = try #require(Self.color("--scroll-thumb", in: map, over: term))
                #expect(Self.contrast(thumb, term) >= 3, "\(file) \(mode): --scroll-thumb over --term-bg")
            }
        }
    }

    // MARK: - Validation + CSS generation

    @Test func terminalTokensMustBeLiteralColors() {
        let skin = WebSkin(id: "x", name: "X", dark: ["--term-bg": "var(--bg-deep)", "--term-fg": "#fff"])
        #expect(skin.validationErrors() == [.terminalValueNotLiteral(mode: "dark", token: "--term-bg")])
        #expect(WebSkin.isLiteralColor("rgba(1, 2, 3, 0.5)"))
        #expect(WebSkin.isLiteralColor("#11223344"))
        #expect(!WebSkin.isLiteralColor("#12345"))
        #expect(!WebSkin.isLiteralColor("color-mix(in srgb, red 10%, transparent)"))
    }

    @Test func rejectsUnknownTokensUnsafeValuesAndBadIDs() {
        let skin = WebSkin(
            id: "Bad Id", name: " ",
            dark: ["--ink-900": "#000", "--accent": "red; } body { display: none",
                   "--bg-deep": "url(https://evil.example/x.png)"],
            fonts: .init(ui: "Inter</style><script>"))
        #expect(skin.validationErrors() == [
            .badID("Bad Id"), .emptyName,
            .unsafeValue(mode: "dark", token: "--accent"),
            .unsafeValue(mode: "dark", token: "--bg-deep"),
            .unknownToken(mode: "dark", token: "--ink-900"),
            .unsafeValue(mode: "fonts", token: "fonts.ui"),
        ])
    }

    @Test func cssScopesDarkAwayFromLightSoMissingLightKeysFallBack() {
        let skin = WebSkin(id: "demo", name: "Demo",
                           dark: ["--accent": "#111111", "--bg-deep": "#000000"],
                           light: ["--accent": "#222222"],
                           fonts: .init(ui: "system-ui, sans-serif"))
        let css = skin.css()
        #expect(css.contains(":root[data-skin=\"demo\"]:not([data-theme=\"light\"]) {"))
        #expect(css.contains(":root[data-skin=\"demo\"][data-theme=\"light\"] {"))
        #expect(css.contains("--font-ui: system-ui, sans-serif;"))
        // --bg-deep only in the dark block, so light falls back to theme.css.
        let lightBlock = css.components(separatedBy: "[data-theme=\"light\"] {").last ?? ""
        #expect(!lightBlock.contains("--bg-deep"))
        #expect(lightBlock.contains("--accent: #222222;"))
        let darkOnly = WebSkin(id: "d", name: "D", dark: ["--accent": "#111111"])
        #expect(!darkOnly.css().contains("[data-theme=\"light\"] {"))
    }

    // MARK: - Color math

    private typealias RGB = (r: Double, g: Double, b: Double)

    /// Resolve a token to an opaque color, following `var()` and compositing
    /// `rgba()` over `background`.
    private static func color(_ token: String, in map: [String: String], over background: RGB?, depth: Int = 0) -> RGB? {
        guard depth < 8, let raw = map[token]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if raw.hasPrefix("var("), raw.hasSuffix(")") {
            let inner = String(raw.dropFirst(4).dropLast())
            let name = inner.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? inner
            return color(name, in: map, over: background, depth: depth + 1)
        }
        if raw.hasPrefix("#"), raw.count == 7, let v = Int(raw.dropFirst(), radix: 16) {
            return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        }
        if raw.lowercased().hasPrefix("rgba("), let bg = background {
            let parts = raw.dropFirst(5).dropLast().split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { return nil }
            let a = parts[3]
            return (parts[0] * a + bg.r * (1 - a), parts[1] * a + bg.g * (1 - a), parts[2] * a + bg.b * (1 - a))
        }
        return nil
    }

    private static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
