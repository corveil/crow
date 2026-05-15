import Foundation

/// A label with an optional color, sourced from GitHub/GitLab issue or PR metadata.
public struct LabelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// Display name of the label (e.g. "bug", "enhancement").
    public let name: String
    /// Hex color without "#" prefix (e.g. "d73a4a"). Nil for providers that
    /// don't supply color (GitLab REST API).
    public let color: String?

    public init(name: String, color: String? = nil) {
        self.name = name
        self.color = color
    }
}
