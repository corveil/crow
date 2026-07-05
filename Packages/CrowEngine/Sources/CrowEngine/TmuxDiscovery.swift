import CrowTerminal
import Foundation

/// Locates a tmux binary on the host and verifies it meets Crow's minimum
/// version requirement.
///
/// Crow needs tmux ≥ 3.3 because:
///   - `allow-passthrough on` (the option that lets DCS-tmux-wrapped OSC
///     sequences from `crow-shell-wrapper.sh` reach the embedded xterm.js surface)
///     was added in 3.3.
///   - `new-window -P -F` (used by `TmuxController.newWindow` to print
///     the new window index) is older but the print syntax stabilized in
///     3.x.
///
/// Returns nil from `discover()` if no usable tmux is found. The first-run
/// onboarding sheet (PROD #4) handles that case for the user.
public enum TmuxDiscovery {

    /// Crow's minimum tmux version. See file header for rationale.
    public static let minimumMajor = 3
    public static let minimumMinor = 3

    /// Search paths in priority order. /opt/homebrew is the default for
    /// Apple Silicon brew installs; /usr/local is Intel brew; /usr/bin
    /// is system-installed (rare on macOS).
    public static let searchPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    /// First usable tmux binary on the host, or nil. "Usable" means the
    /// binary exists, is executable, and `tmux -V` reports ≥ 3.3.
    public static func discover() -> String? {
        for path in searchPaths {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let version = TmuxController.versionString(tmuxBinary: path) else { continue }
            if meetsMinimumVersion(version) {
                return path
            }
        }
        return nil
    }

    /// `tmux -V` typically returns "tmux 3.6a" (or "tmux master", "tmux
    /// next-3.7"). We accept "tmux <int>.<int>..." with any trailing
    /// suffix, and reject other shapes. Parse failure → reject.
    public static func meetsMinimumVersion(_ versionString: String) -> Bool {
        let trimmed = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Require the canonical "tmux <ver>" shape so we don't misread e.g.
        // "not-tmux 3.6" or "fake 99.0".
        let prefix = "tmux "
        guard trimmed.hasPrefix(prefix) else { return false }
        let raw = trimmed.dropFirst(prefix.count)
        let numericPrefix = raw.prefix { "0123456789.".contains($0) }
        let parts = numericPrefix.split(separator: ".")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return false }
        if major > minimumMajor { return true }
        if major == minimumMajor { return minor >= minimumMinor }
        return false
    }
}
