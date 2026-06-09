#if CROW_RENDERER_SWIFTTERM
import AppKit
import SwiftTerm

/// SwiftTerm-side analog of `GhosttyApp` (CROW-466 spike).
///
/// libghostty needs a process-global app handle (`ghostty_app_t`) with a
/// 60 FPS tick timer that pumps the event loop. SwiftTerm has neither —
/// each `TerminalView` is self-contained and driven by AppKit's run
/// loop. The singleton survives only so call sites (AppDelegate init /
/// shutdown / child-exited wiring) can stay symmetric across the two
/// renderer flavors behind a thin compile-time fork.
@MainActor
public final class SwiftTermApp {
    public static let shared = SwiftTermApp()

    /// Fired when the cockpit's `tmux attach-session` child exits. Mirrors
    /// `GhosttyApp.onChildExited`. The view that hosts the local process
    /// invokes this from `processTerminated(source:exitCode:)`.
    public var onChildExited: ((UUID, Int32) -> Void)?

    private init() {}

    public func initialize() {
        NSLog("[SwiftTermApp] initialize() — SwiftTerm renderer active")
    }

    public func shutdown() {
        NSLog("[SwiftTermApp] shutdown()")
    }
}
#endif
