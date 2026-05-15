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
/// When labels include color data (GitHub), renders per-label colored pills.
/// Falls back to the gold theme for labels without color (GitLab).
public struct LabelPillsView: View {
    let labels: [LabelInfo]
    var maxVisible: Int
    var muted: Bool

    public init(labels: [LabelInfo], maxVisible: Int = 3, muted: Bool = false) {
        self.labels = labels
        self.maxVisible = maxVisible
        self.muted = muted
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.prefix(maxVisible))) { label in
                let bgColor = label.color.map { Color(hexString: $0) } ?? CorveilTheme.gold
                let fgColor: Color = muted
                    ? CorveilTheme.textMuted
                    : (label.color.map { CorveilTheme.contrastingTextColor(for: $0) }
                       ?? CorveilTheme.textSecondary)
                Text(label.name)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(bgColor.opacity(muted ? 0.05 : 0.15))
                    .foregroundStyle(fgColor)
                    .overlay(Capsule().strokeBorder(bgColor.opacity(0.3), lineWidth: 0.5))
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
