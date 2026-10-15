import Foundation

/// The Corveil palette from `theme.css` (CROW-1334): the values a skin falls
/// back to for every token it leaves out. Contrast checks and `crow skin get`
/// resolve a skin against it, because a skin's own JSON only holds overrides.
public struct WebSkinBase: Equatable, Sendable {
    /// The `:root` block (dark).
    public var dark: [String: String]
    /// The `[data-theme="light"]` block. Only the keys that differ in light.
    public var light: [String: String]

    public init(dark: [String: String], light: [String: String]) {
        self.dark = dark
        self.light = light
    }

    public static let empty = WebSkinBase(dark: [:], light: [:])

    /// Read the two token blocks out of `theme.css`. Comments are stripped
    /// first; only `--*` declarations are kept. Missing blocks parse as empty
    /// rather than failing: a check against an empty base reports less, it
    /// never reports wrong.
    public static func parse(themeCSS: String) -> WebSkinBase {
        let css = themeCSS.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return WebSkinBase(
            dark: declarations(after: ":root {", in: css),
            light: declarations(after: "[data-theme=\"light\"] {", in: css))
    }

    private static func declarations(after opener: String, in css: String) -> [String: String] {
        guard let start = css.range(of: opener) else { return [:] }
        let rest = css[start.upperBound...]
        guard let end = rest.firstIndex(of: "}") else { return [:] }
        var map: [String: String] = [:]
        for decl in rest[..<end].split(separator: ";") {
            let trimmed = decl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { continue }
            map[String(trimmed[..<colon])] = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    /// Every token as it applies in each mode `skin` has: this base, then (in
    /// light) the base's light block, then the skin's own values. Brand
    /// primitives stay in the map so a `var(--pink)` still resolves.
    public func resolved(_ skin: WebSkin) -> [(mode: String, tokens: [String: String])] {
        var modes: [(String, [String: String])] = [("dark", dark.merging(skin.dark) { $1 })]
        if let light = skin.light {
            modes.append(("light", dark.merging(self.light) { $1 }.merging(light) { $1 }))
        }
        return modes
    }

    /// `resolved(_:)` restricted to ``WebSkin/tokens``: a skin file that sets
    /// every token explicitly. What `crow skin get` and `export` hand back.
    public func flattened(_ skin: WebSkin) -> WebSkin {
        let known = Set(WebSkin.tokens)
        let modes = resolved(skin)
        func only(_ map: [String: String]) -> [String: String] { map.filter { known.contains($0.key) } }
        return WebSkin(
            id: skin.id, name: skin.name,
            dark: only(modes[0].tokens),
            light: modes.count > 1 ? only(modes[1].tokens) : nil,
            fonts: skin.fonts)
    }
}

/// Contrast checks for a skin (CROW-1334). These warn, never block: a skin
/// that misses a ratio is still saved and served, and the warning says which
/// pair, in which mode, by how much.
public enum WebSkinContrast {
    /// One pair below its floor.
    public struct Warning: Equatable, Sendable, CustomStringConvertible {
        public let mode: String
        public let foreground: String
        public let background: String
        /// The measured ratio, rounded to two places.
        public let ratio: Double
        public let minimum: Double

        public init(mode: String, foreground: String, background: String, ratio: Double, minimum: Double) {
            self.mode = mode
            self.foreground = foreground
            self.background = background
            self.ratio = ratio
            self.minimum = minimum
        }

        public var description: String {
            "\(mode): \(foreground) on \(background) is \(String(format: "%.2f", ratio)):1, below \(String(format: "%g", minimum)):1"
        }
    }

    /// Text and status colors that sit on the surfaces below.
    public static let textTokens = [
        "--text-primary", "--text-secondary", "--text-muted", "--accent", "--accent-muted",
        "--green", "--yellow", "--orange", "--red", "--blue", "--purple",
        "--grade-a", "--grade-b", "--grade-c", "--grade-d", "--grade-f",
    ]
    public static let backgroundTokens = ["--bg-deep", "--bg-surface", "--bg-card", "--bg-elev"]

    /// Every checked pair: (foreground, background, floor). Text is 4.5:1
    /// (WCAG 1.4.3); the terminal scroll thumb is a non-text control at 3:1
    /// (WCAG 2.2 §1.4.11).
    public static let pairs: [(foreground: String, background: String, minimum: Double)] = {
        var out: [(String, String, Double)] = []
        for bg in backgroundTokens {
            for fg in textTokens { out.append((fg, bg, 4.5)) }
        }
        out.append(("--on-accent", "--accent-fill", 4.5))
        out.append(("--on-green", "--green-fill", 4.5))
        out.append(("--on-red", "--red-fill", 4.5))
        out.append(("--term-fg", "--term-bg", 4.5))
        out.append(("--scroll-thumb", "--term-bg", 3))
        return out.map { (foreground: $0.0, background: $0.1, minimum: $0.2) }
    }()

    /// Pairs below their floor, in mode then ``pairs`` order. A pair whose
    /// colors cannot be resolved to sRGB (a `color-mix()`, a named color) is
    /// skipped rather than guessed at.
    public static func warnings(for skin: WebSkin, base: WebSkinBase) -> [Warning] {
        var out: [Warning] = []
        for (mode, tokens) in base.resolved(skin) {
            for pair in pairs {
                guard let bg = color(pair.background, in: tokens, over: nil),
                      let fg = color(pair.foreground, in: tokens, over: bg) else { continue }
                let ratio = contrast(fg, bg)
                if ratio < pair.minimum {
                    out.append(Warning(
                        mode: mode, foreground: pair.foreground, background: pair.background,
                        ratio: (ratio * 100).rounded() / 100, minimum: pair.minimum))
                }
            }
        }
        return out
    }

    // MARK: - Color math

    public struct RGB: Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// Resolve `token` to an opaque color: follow `var()` (with its fallback),
    /// read `#rgb`/`#rrggbb`/`#rrggbbaa` and `rgb()`/`rgba()`, and composite
    /// any alpha over `background` (an opaque color with alpha and no
    /// background is treated as unresolvable).
    public static func color(_ token: String, in map: [String: String], over background: RGB?) -> RGB? {
        guard let raw = map[token] else { return nil }
        return parse(raw, in: map, over: background, depth: 0)
    }

    static func parse(_ raw: String, in map: [String: String], over background: RGB?, depth: Int) -> RGB? {
        guard depth < 8 else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces)
        let lower = v.lowercased()
        if lower.hasPrefix("var("), lower.hasSuffix(")") {
            let inner = String(v.dropFirst(4).dropLast())
            let parts = inner.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if let name = parts.first, let value = map[name] {
                return parse(value, in: map, over: background, depth: depth + 1)
            }
            return parts.count == 2 ? parse(parts[1], in: map, over: background, depth: depth + 1) : nil
        }
        if v.hasPrefix("#") {
            let hex = Array(v.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            let digits: [Character]
            switch hex.count {
            case 3: digits = hex.flatMap { [$0, $0] } + ["f", "f"]
            case 6: digits = hex + ["f", "f"]
            case 8: digits = hex
            default: return nil
            }
            func byte(_ i: Int) -> Double { Double(Int(String(digits[i...i + 1]), radix: 16) ?? 0) }
            return composite(RGB(r: byte(0), g: byte(2), b: byte(4)), alpha: byte(6) / 255, over: background)
        }
        if lower.hasPrefix("rgb"), let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .compactMap { Double($0) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            return composite(RGB(r: parts[0], g: parts[1], b: parts[2]),
                             alpha: parts.count == 4 ? parts[3] : 1, over: background)
        }
        return nil
    }

    private static func composite(_ c: RGB, alpha: Double, over background: RGB?) -> RGB? {
        if alpha >= 1 { return c }
        guard let bg = background else { return nil }
        return RGB(r: c.r * alpha + bg.r * (1 - alpha),
                   g: c.g * alpha + bg.g * (1 - alpha),
                   b: c.b * alpha + bg.b * (1 - alpha))
    }

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// WCAG contrast ratio, 1…21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
