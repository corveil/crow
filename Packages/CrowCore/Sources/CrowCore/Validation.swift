import Foundation

/// Shared validation helpers used by the app and socket server.
public enum Validation {
    /// Maximum allowed length for session names.
    public static let maxSessionNameLength = 256

    /// Check whether a path is within the given root directory (prevents path traversal).
    public static func isPathWithinRoot(_ path: String, root: String) -> Bool {
        let realPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let realRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return realPath.hasPrefix(realRoot + "/") || realPath == realRoot
    }

    /// Validate a session name contains no control characters and is within length limits.
    public static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= maxSessionNameLength
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    /// Detect provider from a ticket URL.
    public static func detectProviderFromURL(_ url: String) -> Provider? {
        if url.contains("github.com") {
            return .github
        } else if url.contains("atlassian.net") || url.contains("/browse/") {
            // Jira Cloud: https://<site>.atlassian.net/browse/PROJ-123.
            // Checked before the loose `gitlab` substring match below.
            return .jira
        } else if url.contains("gitlab.com") || url.contains("gitlab") || url.contains("/-/issues") || url.contains("/-/merge_requests") {
            return .gitlab
        }
        return nil
    }

    /// Extract a Jira work-item key (e.g. `PROJ-123`) from a browse URL
    /// (`https://<site>.atlassian.net/browse/PROJ-123`) or return the input
    /// unchanged when it's already a bare key. Strips any trailing path, query,
    /// or fragment. Used to build `acli` commands in launcher prompts.
    public static func jiraKey(from urlOrKey: String) -> String {
        var token = urlOrKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = token.range(of: "/browse/") {
            token = String(token[r.upperBound...])
        }
        if let stop = token.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            token = String(token[..<stop])
        }
        return token
    }
}
