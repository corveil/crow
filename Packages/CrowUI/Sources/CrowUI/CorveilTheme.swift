import SwiftUI
import AppKit
import CrowCore

/// Corveil design tokens translated from corveil.com/styles.css
public enum CorveilTheme {
    // Backgrounds
    public static let bgDeep = Color(hex: 0x121416)
    public static let bgSurface = Color(hex: 0x1A1D20)
    public static let bgCard = Color(hex: 0x22262A)
    /// Tinted background for "done" / linked-session cards.
    public static let bgDone = Color(red: 0.15, green: 0.22, blue: 0.16)

    // Gold palette
    public static let gold = Color(hex: 0xDDC482)
    public static let goldDark = Color(hex: 0xB38E46)

    // Borders
    public static let borderSubtle = Color(hex: 0xDDC482, opacity: 0.12)
    public static let borderStrong = Color(hex: 0xDDC482, opacity: 0.25)

    // Text
    public static let textPrimary = Color.white
    public static let textSecondary = Color(hex: 0xA8A9AE)
    public static let textMuted = Color(hex: 0x6B6D72)
}

extension Color {
    public init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Parses a 6-character hex string (with or without "#" prefix) into a Color.
    /// Falls back to `CorveilTheme.gold` if the string is invalid.
    public init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt(hex, radix: 16) else {
            self = CorveilTheme.gold
            return
        }
        self.init(hex: value)
    }
}

extension CorveilTheme {
    /// Returns a text color that contrasts well against the given hex background,
    /// using the W3C relative luminance formula. Matches GitHub's label rendering.
    public static func contrastingTextColor(for hexString: String) -> Color {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt(hex, radix: 16) else {
            return textSecondary
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255

        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
        return luminance > 0.179 ? Color(hex: 0x1A1D20) : .white
    }

    /// Hue-preserving variant of `hexString` suitable for chip text + border
    /// against the neutral label-pill surface in the given color scheme.
    /// Saturation is clamped to a friendly band; lightness is clamped so any
    /// hue clears WCAG AA against the neutral fill.
    ///
    /// Tuning knobs:
    /// - Saturation `[0.40, 0.85]`: lower bound keeps near-grayscale labels
    ///   distinct as accents; upper bound calms down neon hues.
    /// - Dark lightness `≥ 0.78`: the binding constraint is pure blue
    ///   (H≈240°), which contributes only ~7% of relative luminance — this
    ///   bound puts even saturated blue comfortably above 4.5:1 vs `#21262D`.
    /// - Light lightness `≤ 0.22`: ensures dark text against `#EAEEF2`
    ///   for the worst hues (yellow ~50°, green ~124°), whose own relative
    ///   luminance crowds the AA threshold at higher L values.
    public static func accentColor(for hexString: String, in scheme: ColorScheme) -> Color {
        guard let rgb = accentRGB(for: hexString, in: scheme) else {
            return scheme == .dark ? .white : Color(hex: 0x1A1D20)
        }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Underlying RGB output of `accentColor`. Exposed at module scope so the
    /// CrowUI test target can verify WCAG contrast without round-tripping
    /// through SwiftUI `Color` → `NSColor`.
    static func accentRGB(for hexString: String, in scheme: ColorScheme) -> (r: Double, g: Double, b: Double)? {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255

        var (h, s, l) = rgbToHSL(r: r, g: g, b: b)
        s = min(max(s, 0.40), 0.85)
        l = scheme == .dark ? max(l, 0.78) : min(l, 0.22)

        return hslToRGB(h: h, s: s, l: l)
    }

    static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        let h: Double
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h / 6, s, l)
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        guard s != 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (hue2rgb(p, q, h + 1.0 / 3),
                hue2rgb(p, q, h),
                hue2rgb(p, q, h - 1.0 / 3))
    }

    private static func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
}

// MARK: - Status Color Extensions

extension TicketStatus {
    /// Canonical UI color for each pipeline stage.
    public var color: Color {
        switch self {
        case .backlog: .gray
        case .ready: .blue
        case .inProgress: .orange
        case .inReview: .purple
        case .done: .green
        case .unknown: .secondary
        }
    }

    /// Canonical SF Symbol for each pipeline stage.
    public var icon: String {
        switch self {
        case .backlog: "tray"
        case .ready: "flag.fill"
        case .inProgress: "bolt.fill"
        case .inReview: "eye.fill"
        case .done: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension SessionStatus {
    /// Human-readable display name (handles multi-word statuses like "In Review").
    public var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .inReview: "In Review"
        case .completed: "Completed"
        case .archived: "Archived"
        }
    }
}

// MARK: - Brandmark Image

/// Loads the Corveil brandmark from app bundles. Decorative — hidden from VoiceOver.
public struct BrandmarkImage: View {
    public init() {}

    public var body: some View {
        if let image = Self.load() {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }

    static func load() -> NSImage? {
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "CorveilBrandmark", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

// MARK: - Branch Formatting

/// Shortens a git branch name by stripping common prefixes.
public func shortenBranch(_ branch: String) -> String {
    branch
        .replacingOccurrences(of: "refs/heads/", with: "")
        .replacingOccurrences(of: "feature/", with: "")
}

// MARK: - Search Field

/// Themed search field with magnifying glass icon and clear button.
public struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(CorveilTheme.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(CorveilTheme.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CorveilTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(CorveilTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(CorveilTheme.borderSubtle, lineWidth: 1)
                )
        )
    }
}

// MARK: - Capsule Badge

/// Reusable capsule badge with colored background and border.
public struct CapsuleBadge: View {
    let label: String
    let color: Color

    public init(_ label: String, color: Color) {
        self.label = label
        self.color = color
    }

    public var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .overlay(
                Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

// MARK: - Label Pills

/// Reusable horizontal row of label capsules with overflow count.
/// Renders each label as a neutral-fill chip with a hue-preserving border and
/// text drawn from the GitHub label color (saturation + lightness clamped per
/// color scheme so every hue clears WCAG AA against the fill). GitLab labels
/// without color data fall back to the gold theme accent.
public struct LabelPillsView: View {
    @Environment(\.colorScheme) private var colorScheme
    let labels: [LabelInfo]
    var maxVisible: Int
    var muted: Bool

    public init(labels: [LabelInfo], maxVisible: Int = 3, muted: Bool = false) {
        self.labels = labels
        self.maxVisible = maxVisible
        self.muted = muted
    }

    public var body: some View {
        let fill = colorScheme == .dark ? Color(hex: 0x21262D) : Color(hex: 0xEAEEF2)
        HStack(spacing: 4) {
            ForEach(Array(labels.prefix(maxVisible))) { label in
                let accent: Color = label.color
                    .map { CorveilTheme.accentColor(for: $0, in: colorScheme) }
                    ?? CorveilTheme.gold
                let fg: Color = muted ? CorveilTheme.textMuted : accent
                let stroke: Color = muted ? CorveilTheme.textMuted.opacity(0.35) : accent
                Text(label.name)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(fill)
                    .foregroundStyle(fg)
                    .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                    .clipShape(Capsule())
            }
            if labels.count > maxVisible {
                Text("+\(labels.count - maxVisible)")
                    .font(.system(size: 10))
                    .foregroundStyle(CorveilTheme.textMuted)
            }
        }
    }
}

#if DEBUG
#Preview("Label Pills — Dark & Light") {
    let samples: [LabelInfo] = [
        LabelInfo(name: "medium",       color: "FBCA04"),
        LabelInfo(name: "multi-tenant", color: "0E8A16"),
        LabelInfo(name: "high",         color: "D93F0B"),
        LabelInfo(name: "near-white",   color: "F5F5F5"),
        LabelInfo(name: "near-black",   color: "111111"),
    ]
    return VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dark on bgSurface").font(.caption).foregroundStyle(.white)
            LabelPillsView(labels: samples, maxVisible: 5)
            LabelPillsView(labels: samples, maxVisible: 5, muted: true)
        }
        .padding()
        .background(CorveilTheme.bgSurface)
        .environment(\.colorScheme, .dark)

        VStack(alignment: .leading, spacing: 8) {
            Text("Light on white").font(.caption)
            LabelPillsView(labels: samples, maxVisible: 5)
            LabelPillsView(labels: samples, maxVisible: 5, muted: true)
        }
        .padding()
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
    .padding()
}
#endif
