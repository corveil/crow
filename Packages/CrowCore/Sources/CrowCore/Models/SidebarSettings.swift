import Foundation

/// The color of the particle crow brandmark (CROW-1469). Gold is Crow's own
/// accent (`--gold-dark` → `--gold`); pink is Corveil's (#E60073 → #FF4AA2).
/// It recolors only the mark: the favicon, the login card, the sidebar and
/// empty-state animation, the PWA manifest's SVG and About. The UI accent and
/// the desktop app icon stay gold.
public enum BrandmarkColor: String, Codable, Sendable, Equatable, CaseIterable {
    case gold
    case pink

    public static let `default`: BrandmarkColor = .gold

    /// Accepted values, for error messages and CLI help.
    public static let choices = allCases.map(\.rawValue).joined(separator: ", ")
}

/// Sidebar display preferences.
public struct SidebarSettings: Codable, Sendable, Equatable {
    public var hideSessionDetails: Bool
    public var brandmarkColor: BrandmarkColor

    public init(hideSessionDetails: Bool = false, brandmarkColor: BrandmarkColor = .default) {
        self.hideSessionDetails = hideSessionDetails
        self.brandmarkColor = brandmarkColor
    }

    /// Per-key defaults, matching `ConfigDefaults` and `TerminalSettings`.
    /// `AppConfig`'s `decodeIfPresent` only tolerates a wholly *absent* block —
    /// a present-but-partial one (`{"sidebar": {}}`) would throw `keyNotFound`
    /// and fail the entire config decode (CROW-814).
    ///
    /// `brandmarkColor` is read as a string and an unknown value falls back to
    /// gold: a hand-edited `"purple"` must not fail the whole config decode
    /// over a cosmetic key. `ui set` rejects anything but gold or pink, so the
    /// fallback only meets hand edits.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideSessionDetails = try c.decodeIfPresent(Bool.self, forKey: .hideSessionDetails) ?? false
        let rawColor = (try? c.decodeIfPresent(String.self, forKey: .brandmarkColor)) ?? nil
        brandmarkColor = rawColor.flatMap(BrandmarkColor.init(rawValue:)) ?? .default
    }

    enum CodingKeys: String, CodingKey { case hideSessionDetails, brandmarkColor }
}
