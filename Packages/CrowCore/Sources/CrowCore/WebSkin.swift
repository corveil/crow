import Foundation

/// A web UI skin (CROW-1333): a palette, and optionally fonts, for the browser
/// UI `crowd` serves.
///
/// The on-disk format is one JSON object per skin:
///
/// ```json
/// { "id": "graphite", "name": "Graphite",
///   "dark":  { "--bg-deep": "#111214", ... },
///   "light": { "--bg-deep": "#F4F5F7", ... },
///   "fonts": { "ui": "system-ui, sans-serif", "mono": "ui-monospace, monospace" } }
/// ```
///
/// `light` is optional: a skin without it is dark only, and the web UI pins
/// the dark theme while it is selected. Every key must be one of
/// ``WebSkin/tokens``. A key the skin leaves out falls back to the Corveil
/// value in `theme.css`, because the generated CSS is scoped to
/// `:root[data-skin="<id>"]` and so outranks `theme.css` only where it says
/// something.
///
/// This lives in CrowCore rather than CrowDaemon so the CLI can validate a
/// user-made skin with the same rules the daemon serves it by.
public struct WebSkin: Codable, Equatable, Sendable {
    public struct Fonts: Codable, Equatable, Sendable {
        public var ui: String?
        public var mono: String?

        public init(ui: String? = nil, mono: String? = nil) {
            self.ui = ui
            self.mono = mono
        }
    }

    public var id: String
    public var name: String
    public var dark: [String: String]
    public var light: [String: String]?
    public var fonts: Fonts?

    public init(id: String, name: String, dark: [String: String],
                light: [String: String]? = nil, fonts: Fonts? = nil) {
        self.id = id
        self.name = name
        self.dark = dark
        self.light = light
        self.fonts = fonts
    }

    /// The skin `theme.css` already paints. It needs no generated CSS.
    public static let defaultID = "corveil"

    /// Whether the skin defines a light palette. A dark-only skin pins dark.
    public var supportsLight: Bool { light != nil }

    /// The documented token set, in `theme.css` order. A skin may set any of
    /// these and nothing else. The brand primitives (`--ink-900`, `--pink`, …)
    /// are not here: they are constants the Corveil palette is built from, not
    /// part of the skin contract. Fonts go through ``Fonts``.
    ///
    /// Keep in step with `theme.css`; `WebSkinTests` fails when the two differ.
    public static let tokens: [String] = [
        "--accent-fill", "--on-accent", "--green-fill", "--on-green", "--red-fill", "--on-red",
        "--overlay", "--overlay-strong",
        "--shadow-raised", "--shadow-card", "--shadow-popover", "--shadow-modal",
        "--bg-deep", "--bg-surface", "--bg-card", "--bg-elev", "--bg-elevated",
        "--bg-selected", "--bg-done",
        "--border-subtle", "--border-strong",
        "--text-primary", "--text-secondary", "--text-muted",
        "--accent", "--accent-muted", "--accent-soft", "--accent-wash", "--accent-line",
        "--attention-wash",
        "--skel-lo", "--skel-hi", "--skel-still", "--badge-wash",
        "--green", "--yellow", "--orange", "--red", "--blue", "--purple",
        "--grade-a", "--grade-b", "--grade-c", "--grade-d", "--grade-f",
        "--term-bg", "--term-fg", "--term-cursor", "--term-cursor-accent", "--term-selection",
        "--term-black", "--term-red", "--term-green", "--term-yellow",
        "--term-blue", "--term-magenta", "--term-cyan", "--term-white",
        "--term-bright-black", "--term-bright-red", "--term-bright-green", "--term-bright-yellow",
        "--term-bright-blue", "--term-bright-magenta", "--term-bright-cyan", "--term-bright-white",
        "--term-hud-bg",
        "--scroll-thumb", "--scroll-thumb-hover", "--scroll-thumb-active",
    ]

    /// Brand primitives `theme.css` declares as constants. Listed so the
    /// token-parity test can tell "a primitive" from "a token someone forgot".
    public static let brandPrimitives: Set<String> = [
        "--ink-900", "--ink-850", "--plum-900", "--pink", "--pink-bright", "--pink-deep",
        "--paper", "--paper-soft", "--brand-text", "--font-ui", "--font-mono",
    ]

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case badID(String)
        case emptyName
        case unknownToken(mode: String, token: String)
        case unsafeValue(mode: String, token: String)
        case terminalValueNotLiteral(mode: String, token: String)
        case notAColor(mode: String, token: String, value: String)

        public var description: String {
            switch self {
            case .badID(let id):
                return "skin id \"\(id)\" must be lowercase letters, digits and dashes (max 64)"
            case .emptyName:
                return "skin name must not be empty"
            case .unknownToken(let mode, let token):
                return "\(mode): \(token) is not a skin token (see docs/web-skins.md)"
            case .unsafeValue(let mode, let token):
                return "\(mode): \(token) has a value that is not a plain CSS value"
            case .terminalValueNotLiteral(let mode, let token):
                return "\(mode): \(token) must be a literal #hex or rgb()/rgba() color; xterm reads it from JS and cannot resolve var()"
            case .notAColor(let mode, let token, let value):
                return "\(mode): \(token) must be a color, got \"\(value)\""
            }
        }
    }

    /// Every problem with the skin, in a stable order. Empty means valid.
    public func validationErrors() -> [ValidationError] {
        var errors: [ValidationError] = []
        if !Self.isValidID(id) { errors.append(.badID(id)) }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.emptyName) }
        let known = Set(Self.tokens)
        var modes: [(String, [String: String])] = [("dark", dark)]
        if let light { modes.append(("light", light)) }
        for (mode, map) in modes {
            for token in map.keys.sorted() {
                let value = map[token] ?? ""
                if !known.contains(token) {
                    errors.append(.unknownToken(mode: mode, token: token))
                } else if !Self.isSafeValue(value) {
                    errors.append(.unsafeValue(mode: mode, token: token))
                } else if token.hasPrefix("--term-"), !Self.isLiteralColor(value) {
                    errors.append(.terminalValueNotLiteral(mode: mode, token: token))
                } else if !Self.nonColorTokens.contains(token), !Self.isColorValue(value) {
                    errors.append(.notAColor(
                        mode: mode, token: token, value: value.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        for (key, value) in [("fonts.ui", fonts?.ui), ("fonts.mono", fonts?.mono)] {
            if let value, !Self.isSafeValue(value) {
                errors.append(.unsafeValue(mode: "fonts", token: key))
            }
        }
        return errors
    }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, let first = id.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first)
        else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// A value that cannot escape its declaration or pull anything in: no
    /// statement or block delimiters, no markup, no comments, no `url()` /
    /// `@import`. Colors, `var()`, `color-mix()`, shadows and font stacks pass.
    static func isSafeValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.count > 300 { return false }
        let forbidden: Set<Character> = [";", "{", "}", "<", ">", "\\", "\n", "\r", "@"]
        if trimmed.contains(where: { forbidden.contains($0) }) { return false }
        let lower = trimmed.lowercased()
        return !lower.contains("/*") && !lower.contains("*/") && !lower.contains("url(")
            && !lower.contains("expression(") && !lower.contains("image(")
    }

    /// Tokens whose value is not a color (CROW-1334). Every other token must
    /// pass ``isColorValue(_:)``.
    public static let nonColorTokens: Set<String> = [
        "--shadow-raised", "--shadow-card", "--shadow-popover", "--shadow-modal",
    ]

    /// Whether `value` reads as a CSS color: a literal (``isLiteralColor(_:)``),
    /// a color function (`hsl()`, `color-mix()`, `oklch()`, …), a `var()`, or a
    /// named color. It catches the plain mistakes (`12px`, `bold`, a font stack)
    /// without parsing CSS Color 4 in full; the browser still judges a
    /// function's arguments.
    public static func isColorValue(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        if isLiteralColor(v) { return true }
        let lower = v.lowercased()
        if let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            return colorFunctions.contains(String(lower[..<open]).trimmingCharacters(in: .whitespaces))
        }
        return namedColors.contains(lower)
    }

    static let colorFunctions: Set<String> = [
        "var", "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch",
        "color", "color-mix", "light-dark",
    ]

    /// CSS named colors (CSS Color 4), plus `transparent` and `currentcolor`.
    static let namedColors: Set<String> = Set([
        "transparent", "currentcolor", "aliceblue", "antiquewhite", "aqua", "aquamarine",
        "azure", "beige", "bisque", "black", "blanchedalmond", "blue", "blueviolet", "brown",
        "burlywood", "cadetblue", "chartreuse", "chocolate", "coral", "cornflowerblue",
        "cornsilk", "crimson", "cyan", "darkblue", "darkcyan", "darkgoldenrod", "darkgray",
        "darkgreen", "darkgrey", "darkkhaki", "darkmagenta", "darkolivegreen", "darkorange",
        "darkorchid", "darkred", "darksalmon", "darkseagreen", "darkslateblue", "darkslategray",
        "darkslategrey", "darkturquoise", "darkviolet", "deeppink", "deepskyblue", "dimgray",
        "dimgrey", "dodgerblue", "firebrick", "floralwhite", "forestgreen", "fuchsia",
        "gainsboro", "ghostwhite", "gold", "goldenrod", "gray", "green", "greenyellow", "grey",
        "honeydew", "hotpink", "indianred", "indigo", "ivory", "khaki", "lavender",
        "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan",
        "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink",
        "lightsalmon", "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey",
        "lightsteelblue", "lightyellow", "lime", "limegreen", "linen", "magenta", "maroon",
        "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple", "mediumseagreen",
        "mediumslateblue", "mediumspringgreen", "mediumturquoise", "mediumvioletred",
        "midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite", "navy", "oldlace",
        "olive", "olivedrab", "orange", "orangered", "orchid", "palegoldenrod", "palegreen",
        "paleturquoise", "palevioletred", "papayawhip", "peachpuff", "peru", "pink", "plum",
        "powderblue", "purple", "rebeccapurple", "red", "rosybrown", "royalblue", "saddlebrown",
        "salmon", "sandybrown", "seagreen", "seashell", "sienna", "silver", "skyblue",
        "slateblue", "slategray", "slategrey", "snow", "springgreen", "steelblue", "tan", "teal",
        "thistle", "tomato", "turquoise", "violet", "wheat", "white", "whitesmoke", "yellow",
        "yellowgreen",
    ])

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, or `rgb()`/`rgba()` with plain numbers —
    /// the forms xterm's `css.toColor` parses.
    public static func isLiteralColor(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("#") {
            let hex = v.dropFirst()
            return [3, 6, 8].contains(hex.count) && hex.allSatisfy(\.isHexDigit)
        }
        let lower = v.lowercased()
        guard lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), lower.hasSuffix(")"),
              let open = lower.firstIndex(of: "(") else { return false }
        let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return false }
        return parts.allSatisfy { Double($0) != nil }
    }

    /// The CSS that applies this skin on top of `theme.css`. Valid skins only;
    /// call ``validationErrors()`` first.
    ///
    /// Dark rules use `:not([data-theme="light"])` rather than a bare
    /// `:root[data-skin]`: the bare form would outrank `theme.css`'s light
    /// block and leak a dark value into light for any key `light` omits.
    public func css() -> String {
        let scope = ":root[data-skin=\"\(id)\"]"
        var out = "/* Skin: \(Self.commentSafe(name)) (\(id)). Generated by crowd from skins/\(id).json (CROW-1333). */\n"
        if let fonts, fonts.ui != nil || fonts.mono != nil {
            out += "\(scope) {\n"
            if let ui = fonts.ui { out += "  --font-ui: \(ui);\n" }
            if let mono = fonts.mono { out += "  --font-mono: \(mono);\n" }
            out += "}\n"
        }
        out += Self.block("\(scope):not([data-theme=\"light\"])", dark, colorScheme: "dark")
        if let light {
            out += Self.block("\(scope)[data-theme=\"light\"]", light, colorScheme: "light")
        }
        return out
    }

    private static func block(_ selector: String, _ map: [String: String], colorScheme: String) -> String {
        var out = "\(selector) {\n  color-scheme: \(colorScheme);\n"
        for token in tokens {
            if let value = map[token] { out += "  \(token): \(value.trimmingCharacters(in: .whitespaces));\n" }
        }
        return out + "}\n"
    }

    private static func commentSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "*/", with: "* /")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
