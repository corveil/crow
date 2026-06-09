#if !CROW_RENDERER_SWIFTTERM
import AppKit
import GhosttyKit

/// Manages the Ghostty app instance (singleton per process).
@MainActor
public final class GhosttyApp {
    public static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    /// Fired when a surface's child process exits (Ghostty's
    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED`). Delivers the terminal UUID and the
    /// child's exit code. Used to detect a dead Manager `claude` process so the
    /// UI can offer a restart. Always invoked on the main actor.
    public var onChildExited: ((UUID, Int32) -> Void)?

    private init() {}

    public func initialize() {
        guard app == nil else {
            NSLog("[GhosttyApp] Already initialized, skipping duplicate initialize() call")
            return
        }

        // Initialize ghostty
        ghostty_init(0, nil)

        // Create and load config
        guard let cfg = ghostty_config_new() else {
            NSLog("[GhosttyApp] Failed to create config")
            return
        }
        ghostty_config_load_default_files(cfg)

        // Load our app-specific overrides
        loadAppConfig(cfg)

        ghostty_config_finalize(cfg)
        self.config = cfg

        // Create runtime config with callbacks
        var rtConfig = ghostty_runtime_config_s()
        rtConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        rtConfig.supports_selection_clipboard = false
        rtConfig.wakeup_cb = { userdata in
            // Schedule a tick on the main thread
            DispatchQueue.main.async {
                guard let userdata else { return }
                let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                app.tick()
            }
        }
        rtConfig.action_cb = { app, target, action in
            // Handle ghostty actions (new_tab, close, etc.)
            return GhosttyApp.handleAction(app: app, target: target, action: action)
        }
        rtConfig.read_clipboard_cb = { userdata, clipboard, state in
            // Clipboard paste is handled in GhosttySurfaceView.keyDown via Cmd+V interception
            return false
        }
        rtConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        rtConfig.write_clipboard_cb = { userdata, clipboard, contents, count, confirm in
            guard count > 0, let contents else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let str = contents.pointee.data.flatMap({ String(cString: $0) }) {
                pasteboard.setString(str, forType: .string)
            }
        }
        rtConfig.close_surface_cb = { _, _ in }

        self.app = ghostty_app_new(&rtConfig, cfg)

        // Start tick timer
        startTickTimer()
    }

    /// Process pending Ghostty events. Called by the tick timer and the wakeup callback.
    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private var tickTimer: Timer?

    /// Start the 60 FPS timer that drives Ghostty's render and event-processing loop.
    private func startTickTimer() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// Raw action tags that fire constantly during normal focus/scroll/tab-switch.
    /// GhosttyKit is a precompiled xcframework, so the enum names aren't available
    /// in Swift — we silence by raw value. Unknown tags still log so new actions
    /// remain discoverable.
    nonisolated private static let silencedActionTags: Set<UInt32> = [26, 32, 36, 56]

    nonisolated static func handleAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // The child process backing a surface exited (crash, kill, normal quit).
        // Map the surface back to its terminal UUID via the userdata pointer we
        // set in GhosttySurfaceView.createSurface, then notify on the main actor.
        if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let userdata = ghostty_surface_userdata(target.target.surface) {
                let exitCode = Int32(bitPattern: action.action.child_exited.exit_code)
                DispatchQueue.main.async {
                    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    guard let terminalID = view.terminalID else { return }
                    GhosttyApp.shared.onChildExited?(terminalID, exitCode)
                }
            }
            return true
        }
        if !silencedActionTags.contains(UInt32(action.tag.rawValue)) {
            NSLog("[GhosttyApp] Unhandled action: tag=\(action.tag)")
        }
        return false
    }

    public func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        self.app = nil
        self.config = nil
    }

    /// Load app-specific Ghostty config overrides via a temp file.
    private func loadAppConfig(_ cfg: ghostty_config_t) {
        let overrides = """
        scroll-to-bottom = keystroke, no-output
        """

        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let configPath = "\(tmpDir)/crow-ghostty.conf"

        do {
            try overrides.write(toFile: configPath, atomically: true, encoding: .utf8)
            configPath.withCString { ptr in
                ghostty_config_load_file(cfg, ptr)
            }
            try? FileManager.default.removeItem(atPath: configPath)
        } catch {
            NSLog("[GhosttyApp] Failed to write config overrides: \(error)")
        }
    }
}
#endif
