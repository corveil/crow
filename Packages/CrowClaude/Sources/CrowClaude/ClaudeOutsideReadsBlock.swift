import Foundation

/// Detects `permissions.blockReadsOutsideWorkingDirectories: true` for a Claude
/// auto-mode launch, so Crow can warn about it (CROW-1527).
///
/// Since Claude Code 2.1.327, with that setting on, an auto-mode session
/// denies Read-tool calls outside its working directories
/// (`reasonCode: outsideReadsBlocked`). It also puts **an ask dialog** in front
/// of Bash commands that name an outside path (`cat $TMPDIR/…`, `git -C
/// <sibling>`), even over an allow rule. In an unattended `.job` / `.review`, or
/// a Manager nobody is watching, nobody answers it (CROW-1523; see the
/// Auto-permission prose in `docs/agent-harness-matrix.md`).
///
/// The setting is off by default, but nobody has to set it by hand. The
/// one-time auto-mode outside-read prompt (CROW-1176) offers a "block" choice,
/// and picking it writes the key into `~/.claude/settings.json`. One click in
/// any session switches every later Crow session into this mode.
///
/// **Read only.** Crow reports the setting and never changes it. Removing or
/// overriding the operator's choice, `--dangerously-skip-permissions` /
/// `bypassPermissions`, `--permission-prompts none` and a blanket `--add-dir`
/// are all out of scope (see `ClaudeLaunchArgs.argsSuffix`).
public enum ClaudeOutsideReadsBlock {
    /// The key under `permissions` in a Claude settings file.
    public static let settingKey = "blockReadsOutsideWorkingDirectories"

    /// The flag `ClaudeLaunchArgs.argsSuffix` appends for auto mode. Only
    /// launches that carry it are checked.
    public static let autoModeFlag = " --permission-mode auto"

    /// Whether `command` launches Claude in auto mode. The caller still has to
    /// make sure the session is a Claude session; this only reads the flag.
    public static func isAutoModeLaunch(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains(autoModeFlag)
    }

    /// The settings files that can set the key, **most specific first**: the
    /// cwd's `.claude/settings.local.json`, then its `.claude/settings.json`,
    /// then `~/.claude/settings.json`. Claude Code applies them in that order of
    /// precedence, so the first file that sets the key decides.
    public static func settingsFiles(home: String, cwd: String) -> [String] {
        let project = (cwd as NSString).appendingPathComponent(".claude")
        return [
            (project as NSString).appendingPathComponent("settings.local.json"),
            (project as NSString).appendingPathComponent("settings.json"),
            ((home as NSString).appendingPathComponent(".claude") as NSString)
                .appendingPathComponent("settings.json"),
        ]
    }

    /// What a check found: the setting is in effect, and `path` is the file
    /// that turns it on.
    public struct Finding: Equatable, Sendable {
        public let path: String

        public init(path: String) {
            self.path = path
        }

        /// The one-line warning shown to the operator.
        public var message: String {
            "permissions.\(ClaudeOutsideReadsBlock.settingKey) is on (\(path)). "
                + "In auto mode, Bash commands that name a path outside the session's "
                + "working directories will wait for approval, and Reads there are denied."
        }
    }

    /// The setting's effective value for a launch in `cwd`, as a finding when it
    /// is `true`, or nil when it is off, absent or unreadable.
    ///
    /// - Parameter readFile: Returns a file's bytes, or nil when it is missing
    ///   or unreadable. Injected so tests can use fixtures; production passes
    ///   ``readFileIfPresent(_:)``.
    ///
    /// A file that is missing, isn't valid JSON, or sets the key to anything but
    /// a boolean doesn't count, and the next file down decides. Never throws:
    /// a broken settings file must not stop a launch.
    public static func check(
        home: String,
        cwd: String,
        readFile: (String) -> Data? = readFileIfPresent
    ) -> Finding? {
        for path in settingsFiles(home: home, cwd: cwd) {
            guard let data = readFile(path), let value = value(in: data) else { continue }
            return value ? Finding(path: path) : nil
        }
        return nil
    }

    /// `permissions.blockReadsOutsideWorkingDirectories` in one settings file,
    /// or nil when the JSON is malformed or doesn't set it to a boolean.
    /// A `Decodable` reads the key, so a JSON `1` or `"true"` is not taken
    /// for `true`, the same on Linux as on macOS.
    public static func value(in data: Data) -> Bool? {
        (try? JSONDecoder().decode(SettingsFile.self, from: data))?.permissions?.block
    }

    private struct SettingsFile: Decodable {
        struct Permissions: Decodable {
            let block: Bool?
            enum CodingKeys: String, CodingKey {
                case block = "blockReadsOutsideWorkingDirectories"
            }
        }
        let permissions: Permissions?
    }

    /// Reads a settings file without following anything else. Nil when it is
    /// missing or unreadable.
    public static func readFileIfPresent(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }
}
