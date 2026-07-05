import AppKit
import Foundation
import CrowCore
import CrowEngine
import CrowIPC

/// The macOS app's real `HostBridge`: clipboard, editor/terminal launching, and
/// hook notifications. The engine (`CrowEngine`) reaches host-only affordances
/// through this so it can stay AppKit-free (CROW-581 headless-engine migration).
@MainActor
final class AppHostBridge: HostBridge {
    /// Late-bound because `SessionService` (which receives the bridge) is built
    /// earlier in launch than `NotificationManager`. Set once it exists.
    weak var notificationManager: NotificationManager?

    init(notificationManager: NotificationManager? = nil) {
        self.notificationManager = notificationManager
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openInEditor(path: String) {
        guard let codePath = Self.findVSCodeBinary() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codePath)
        process.arguments = [path]
        try? process.run()
    }

    func openTerminalWindow(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }

    func presentHookNotification(
        sessionID: UUID,
        eventName: String,
        payload: [String: JSONValue],
        summary: String
    ) {
        notificationManager?.handleEvent(
            sessionID: sessionID,
            eventName: eventName,
            payload: payload,
            summary: summary
        )
    }

    /// Find the VS Code `code` CLI binary (host-side launch helper). Mirrors
    /// `SessionService.findVSCodeBinary`, which stays there for the
    /// `vsCodeAvailable` capability flag.
    static func findVSCodeBinary() -> String? {
        let candidates = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/code").path,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
