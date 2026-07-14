import Foundation
import CrowIPC

/// The seam through which the headless engine reaches host-only affordances
/// (clipboard, editor/terminal launching, user notifications). The macOS app
/// provides a real `AppHostBridge`; the `crowd` daemon and tests use
/// `NoopHostBridge`. Keeping these off the engine is what lets `CrowEngine`
/// link no AppKit (CROW-581 headless-engine migration).
///
/// `@MainActor` because the engine that calls it is main-actor isolated; a
/// headless process runs the MainActor executor fine (no AppKit run loop
/// required to *call* these).
@MainActor
public protocol HostBridge: AnyObject, Sendable {
    /// Put text on the host clipboard (backs `SessionService.copyDiagnostics`).
    func copyToClipboard(_ text: String)

    /// Open a directory in the host's code editor (backs `openInVSCode`).
    func openInEditor(path: String)

    /// Open a host terminal window at a directory (backs `openTerminal`).
    func openTerminalWindow(path: String)

    /// Present a hook-driven user notification — the engine's single
    /// `NotificationManager.handleEvent` touchpoint.
    func presentHookNotification(
        sessionID: UUID,
        eventName: String,
        payload: [String: JSONValue],
        summary: String
    )
}

/// Headless-safe `HostBridge` that does nothing — used by the daemon and tests
/// so the engine can be constructed and driven without a GUI host.
public final class NoopHostBridge: HostBridge {
    public init() {}
    public func copyToClipboard(_ text: String) {}
    public func openInEditor(path: String) {}
    public func openTerminalWindow(path: String) {}
    public func presentHookNotification(
        sessionID: UUID,
        eventName: String,
        payload: [String: JSONValue],
        summary: String
    ) {}
}
