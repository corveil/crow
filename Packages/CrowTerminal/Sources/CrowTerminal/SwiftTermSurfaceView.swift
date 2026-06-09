#if CROW_RENDERER_SWIFTTERM
import AppKit
import SwiftTerm

/// SwiftTerm-side analog of `GhosttySurfaceView` (CROW-466 spike).
///
/// Hosts a `LocalProcessTerminalView` and forwards the small public API the
/// rest of Crow expects: `init(frame:workingDirectory:command:)`,
/// `writeText(_:)`, `destroy()`, `terminalID`, `hasSurface`,
/// `onSurfaceCreated`, `onSurfaceCreationFailed`.
///
/// OSC 8 hyperlinks — the whole reason for trying SwiftTerm — are wired by
/// flipping `linkReporting = .explicit` on the inner view. SwiftTerm's
/// default `requestOpenLink` implementation on macOS already hands the URL
/// to `NSWorkspace`, so the spike picks up clickable links for free. The
/// libghostty embed silently drops every link today
/// (`GhosttyApp.handleAction()` only dispatches `SHOW_CHILD_EXITED`).
@MainActor
public final class SwiftTermSurfaceView: NSView {
    private var inner: LocalProcessTerminalView?
    private var pendingText: [String] = []

    public var terminalID: UUID?
    public var workingDirectory: String?
    public var command: String?

    public var onSurfaceCreated: (() -> Void)?
    public var onSurfaceCreationFailed: (() -> Void)?

    public var hasSurface: Bool { inner != nil }

    public init(
        frame: NSRect,
        workingDirectory: String? = nil,
        command: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && inner == nil {
            createSurface()
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(inner)
        return inner != nil
    }

    private func createSurface() {
        let view = LocalProcessTerminalView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.processDelegate = self
        view.linkReporting = .explicit
        addSubview(view)
        inner = view

        // Crow's cockpit command is a flat
        //   tmux -S <socket> attach-session -t <session>
        // built in TmuxBackend.cockpitSurface(). Splitting on whitespace is
        // safe because shellQuote() only wraps strings that contain special
        // chars, and the cockpit socket path lives in $TMPDIR with no spaces.
        let raw = command ?? "/bin/zsh"
        let parts = raw
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let executable = parts.first ?? "/bin/zsh"
        let args = Array(parts.dropFirst())

        let env = Terminal.getEnvironmentVariables()
        view.startProcess(
            executable: executable,
            args: args,
            environment: env,
            execName: nil,
            currentDirectory: workingDirectory
        )

        if !pendingText.isEmpty {
            let pending = pendingText
            pendingText = []
            for text in pending { writeText(text) }
        }
        onSurfaceCreated?()
    }

    /// Write text to the PTY — mirror of `GhosttySurfaceView.writeText`.
    ///
    /// Newlines are translated to `\r`, matching tmux/PTY canonical line
    /// discipline. The Ghostty path sends a Return key-event for each
    /// newline; we send `\r` directly because SwiftTerm exposes a raw PTY
    /// write rather than a key-event API.
    public func writeText(_ text: String) {
        guard let inner else {
            NSLog("[SwiftTermSurfaceView] writeText: no surface yet, buffering \(text.count) chars")
            pendingText.append(text)
            return
        }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        let bytes = Array(normalized.utf8)
        inner.process.send(data: ArraySlice(bytes))
    }

    public func destroy() {
        onSurfaceCreated = nil
        onSurfaceCreationFailed = nil
        inner?.terminate()
        inner?.removeFromSuperview()
        inner = nil
    }
}

// MARK: - LocalProcessTerminalViewDelegate
//
// `@preconcurrency` is required because the protocol is nonisolated but our
// view (and its NSView superclass) is main-actor-isolated. SwiftTerm always
// invokes these on the main thread in practice.

extension SwiftTermSurfaceView: @preconcurrency LocalProcessTerminalViewDelegate {
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let id = terminalID else { return }
        SwiftTermApp.shared.onChildExited?(id, exitCode ?? -1)
    }
}
#endif
