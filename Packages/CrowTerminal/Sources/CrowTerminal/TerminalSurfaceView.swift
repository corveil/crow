import SwiftUI
import AppKit
import CrowCore

/// SwiftUI wrapper that reuses the shared tmux cockpit `XTermSurfaceView`.
///
/// All visible-tab views share the same `XTermSurfaceView` from
/// `TmuxBackend.shared.cockpitSurface()` (#198 → only backend since #303).
/// Switching tabs re-parents the same NSView and fires
/// `TmuxBackend.shared.makeActive(id:)` so the attached tmux client jumps
/// to the right window. The shared-surface model means at most one terminal
/// is on-screen at a time — fine today (Crow has no split view). When tmux
/// is unavailable the view renders blank rather than crashing.
public struct TerminalSurfaceView: NSViewRepresentable {
    let terminalID: UUID
    let workingDirectory: String?
    let command: String?

    public init(
        terminalID: UUID = UUID(),
        workingDirectory: String? = nil,
        command: String? = nil
    ) {
        self.terminalID = terminalID
        self.workingDirectory = workingDirectory
        self.command = command
    }

    @MainActor
    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // Attach the shared cockpit surface on the NEXT run-loop turn, never
        // synchronously here. Both `cockpitSurface()` (→ `ensureRunningServer`,
        // a blocking tmux subprocess) and WKWebView setup can pump the main
        // run loop while they wait. NSHostingView builds this representable
        // *inside* the main window's first synchronous layout (the
        // `window.contentView = hostingView` assignment in AppDelegate), so
        // pumping the run loop there re-enters layout and live-locks before the
        // window is ever ordered on-screen — the window stays 0×0/off-screen
        // and no UI appears. Deferring lets that layout pass finish and the
        // window show first; the surface then attaches a tick later.
        syncSurface(into: container)
        return container
    }

    /// Re-parent the surface if SwiftUI replaced the container, switch the
    /// attached tmux client to this terminal's window, and take first
    /// responder. Same deferral rationale as `makeNSView`: `makeActive` shells
    /// out to `tmux select-window` (which pumps the run loop), and updateNSView
    /// is itself invoked during layout, so doing this work synchronously here
    /// re-enters layout.
    @MainActor
    public func updateNSView(_ nsView: NSView, context: Context) {
        syncSurface(into: nsView)
    }

    /// Create-if-needed, re-parent, activate, and focus the shared cockpit
    /// surface — all hopped to the next run-loop turn so none of the
    /// run-loop-pumping backend calls execute inside a SwiftUI layout pass.
    /// Idempotent: no-ops the re-parent when the surface already lives here.
    @MainActor
    private func syncSurface(into container: NSView) {
        let id = terminalID
        DispatchQueue.main.async {
            guard let surface = Self.cockpitSurface() else { return }
            if surface.superview !== container {
                Self.attach(surface: surface, to: container)
            }
            surface.createSurface()
            try? TmuxBackend.shared.makeActive(id: id)
            if let window = container.window,
               surface.window === window,
               window.firstResponder !== surface {
                window.makeFirstResponder(surface)
            }
        }
    }

    /// Re-parent `surface` into `container` and pin to its edges. Idempotent
    /// constraint setup: relies on `addSubview` to atomically re-parent and
    /// on autolayout to drive subsequent `setFrameSize` calls — manual
    /// `setFrameSize` here races with autolayout and is unnecessary.
    @MainActor
    private static func attach(surface: XTermSurfaceView, to container: NSView) {
        container.addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Float the Cmd+F search bar over the surface (#471 gap 2). Only
        // install one per container; later re-parents keep the same bar.
        if container.subviews.contains(where: { $0 is TerminalSearchBar }) == false {
            let bar = TerminalSearchBar(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.setHostSurface(surface)
            container.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            ])
        }
    }

    @MainActor
    private static func cockpitSurface() -> XTermSurfaceView? {
        // The cockpit surface is created lazily on first call; subsequent
        // call sites (other tabs) get the same NSView. Returns nil when tmux
        // is unavailable so the container renders blank instead of crashing.
        do {
            return try TmuxBackend.shared.cockpitSurface()
        } catch {
            NSLog("[TerminalSurfaceView] tmux cockpitSurface failed: \(error). Rendering blank — tmux is required.")
            return nil
        }
    }
}
