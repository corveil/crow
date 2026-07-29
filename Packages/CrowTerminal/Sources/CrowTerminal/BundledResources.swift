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
    ///
    /// RETIRED (ADR 0010). The only caller is `XTermSurfaceView`, the macOS
    /// WKWebView surface, which nothing instantiates any more — `crowd` serves
    /// the browser terminal from `CrowDaemon/Resources/web/` instead, and
    /// `StaticAssets` takes only the xterm *library* files out of this bundle
    /// (see `xtermDirectoryURL`). Terminal fixes go to `Resources/web/app.js`
    /// and `Resources/web/terminal.html`; the page itself carries the same
    /// warning, and CROW-916 is the bug that earned it.
    public static var terminalHTMLURL: URL? {
        Bundle.module.url(
            forResource: "terminal",
            withExtension: "html",
            subdirectory: "xterm"
        )
    }

    /// Directory holding the bundled xterm.js assets (xterm.js, xterm.css,
    /// addons). The headless `crowd` daemon serves files from here over HTTP so
    /// the browser terminal reuses the exact same 6.0.0 assets as the macOS app
    /// (CROW-581) rather than duplicating them.
    public static var xtermDirectoryURL: URL? {
        Bundle.module.url(forResource: "xterm", withExtension: nil)
    }
}
