import Foundation

/// Looks up paths to resources bundled with `CrowTerminal`.
///
/// Used by the tmux backend to locate `crow-shell-wrapper.sh` and
/// `crow-tmux.conf` at runtime. SwiftPM's `Bundle.module` is the canonical
/// way to reach package resources from Swift code in the same target.
public enum BundledResources {

    /// Path to the bundled shell wrapper script. Returns `nil` only if the
    /// resource was excluded at build time, which would be a build-config
    /// bug, not a runtime condition. Callers may treat `nil` as fatal.
    public static var shellWrapperScriptURL: URL? {
        Bundle.module.url(forResource: "crow-shell-wrapper", withExtension: "sh")
    }

    /// Path to the bundled tmux configuration file. Same nil-vs-fatal rule.
    public static var tmuxConfURL: URL? {
        Bundle.module.url(forResource: "crow-tmux", withExtension: "conf")
    }

    /// Path to the xterm.js host page bundled with the terminal surface.
    public static var terminalHTMLURL: URL? {
        Bundle.module.url(
            forResource: "terminal",
            withExtension: "html",
            subdirectory: "xterm"
        )
    }
}
