import Foundation

/// Request rules for `create-manager --name / --prompt / --prompt-file`
/// (CROW-1474), shared by the `crow` CLI and the daemon handler so a bad
/// value fails the same way on either side.
public enum ManagerCreation {
    /// Largest first prompt `create-manager` accepts, in UTF-8 bytes.
    ///
    /// The prompt becomes a single argv string (`TodoRPC.seedLaunchCommand`),
    /// and a tagged Manager's workspace brief is prepended to it. Linux caps
    /// one argv string at 128 KiB (`MAX_ARG_STRLEN`), so this leaves room for
    /// the brief. A longer brief belongs in a file: pass a one-line pointer
    /// such as `Read and follow the instructions in <path>` instead.
    public static let maxPromptBytes = 64 * 1024

    public struct InvalidRequest: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// The explicit name, or nil to auto-name. Same rule as `rename-session`
    /// (`Validation.isValidSessionName`): non-empty, at most 256 characters,
    /// no control characters. A whitespace-only name is refused too — a
    /// missing shell variable should fail loudly, not name a Manager `" "`.
    public static func validatedName(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidRequest("--name must not be blank.")
        }
        guard Validation.isValidSessionName(raw) else {
            throw InvalidRequest(
                "Invalid --name (max \(Validation.maxSessionNameLength) characters, no control characters).")
        }
        return raw
    }

    /// The first prompt, or nil when none was given. Blank text is refused
    /// rather than silently launching an unseeded Manager.
    public static func validatedPrompt(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidRequest("The prompt is empty.")
        }
        let bytes = raw.utf8.count
        guard bytes <= maxPromptBytes else {
            throw InvalidRequest(
                "The prompt is \(bytes) bytes; the limit is \(maxPromptBytes). "
                + "Write it to a file and pass a one-line prompt such as "
                + "\"Read and follow the instructions in <path>\".")
        }
        return raw
    }

    /// The lowest unused `Manager N` (N ≥ 2), so a delete in the middle of the
    /// range doesn't collide. Matches the web `+` button.
    public static func defaultName(existing: Set<String>) -> String {
        var n = 2
        while existing.contains("Manager \(n)") { n += 1 }
        return "Manager \(n)"
    }

    /// Whether the caller's prompt rode the launch: one was given, its brief
    /// file was written, and the Manager's pane exists. A tagged Manager's
    /// launch is always seeded with its workspace brief, so `briefWritten`
    /// alone does not mean the caller's prompt arrived.
    public static func seeded(promptGiven: Bool, briefWritten: Bool, paneUp: Bool) -> Bool {
        promptGiven && briefWritten && paneUp
    }
}
