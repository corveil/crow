import SwiftUI
import AppKit
import CrowCore
import GhosttyKit

/// SwiftUI wrapper that reuses the shared tmux cockpit `GhosttySurfaceView`.
///
/// All visible-tab views share the same `GhosttySurfaceView` from
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
        if let surface = cockpitSurface() {
            attach(surface: surface, to: container)
        }
        // makeActive is fired from updateNSView — issuing it here too can
        // double-fire `tmux select-window` on the same tab activation when
        // SwiftUI calls update right after make on .id() recreation.
        return container
    }

    /// Re-parent the surface if SwiftUI replaced the container, and acquire
    /// first responder once the view is in a window. Also fire makeActive —
    /// this is the "tab switched to a different tmux terminal" hook in the
    /// shared-surface model.
    @MainActor
    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let surface = TmuxBackend.shared.existingCockpitSurface else { return }

        try? TmuxBackend.shared.makeActive(id: terminalID)

        if surface.superview !== nsView {
            // addSubview re-parents atomically — no need for an explicit
            // removeFromSuperview, which would trigger an extra
            // viewDidMoveToWindow(nil) round-trip and a redundant
            // ghostty_surface_set_focus(false) on the shared surface.
            attach(surface: surface, to: nsView)
        }

        // Acquire first responder after AppKit has had a chance to add the
        // container to the window hierarchy. Scheduling via Task @MainActor
        // hops to the next main-actor execution without an arbitrary delay,
        // so rapid tab switches don't stack stale closures against the
        // (shared, in tmux mode) surface.
        Task { @MainActor [weak surface] in
            guard let surface,
                  let window = nsView.window,
                  surface.superview === nsView,
                  surface.window === window else { return }
            window.makeFirstResponder(surface)
        }
    }

    /// Re-parent `surface` into `container` and pin to its edges. Idempotent
    /// constraint setup: relies on `addSubview` to atomically re-parent and
    /// on autolayout to drive subsequent `setFrameSize` calls — manual
    /// `setFrameSize` here races with autolayout and is unnecessary.
    @MainActor
    private func attach(surface: GhosttySurfaceView, to container: NSView) {
        container.addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @MainActor
    private func cockpitSurface() -> GhosttySurfaceView? {
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
