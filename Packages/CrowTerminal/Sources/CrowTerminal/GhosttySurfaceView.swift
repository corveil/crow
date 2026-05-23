import AppKit
import GhosttyKit

/// NSView subclass that hosts a libghostty terminal surface with Metal rendering.
public final class GhosttySurfaceView: NSView {
    private var surface: ghostty_surface_t?
    private var pendingText: [String] = []
    private var markedTextStorage = NSMutableAttributedString()
    private var trackingArea: NSTrackingArea?

    /// Backoff schedule for retrying createSurface() when ghostty_surface_new returns nil.
    /// 4 retries totalling ~7.5s before declaring permanent failure.
    private static let retryDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0]
    private var createAttempts: Int = 0

    /// Whether the Ghostty surface has been created (needs window attachment first).
    public var hasSurface: Bool { surface != nil }

    /// Called after createSurface() succeeds.
    public var onSurfaceCreated: (() -> Void)?

    /// Called after createSurface() exhausts its retry budget without producing a surface.
    public var onSurfaceCreationFailed: (() -> Void)?

    /// The terminal UUID this surface backs, if the owner wires per-surface
    /// child-exit mapping. Read by Ghostty's child-exit action callback to map
    /// a dead surface back to its terminal (see `GhosttyApp.handleAction`). The
    /// shared tmux cockpit surface leaves this nil — its child is the `tmux
    /// attach` client, not a single terminal's process.
    public var terminalID: UUID?

    /// The working directory for the shell spawned in this surface.
    public var workingDirectory: String?

    /// Command to run instead of the default shell.
    public var command: String?

    // MARK: - Initialization

    public init(frame: NSRect, workingDirectory: String? = nil, command: String? = nil) {
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

    @MainActor
    public func createSurface() {
        guard let app = GhosttyApp.shared.app else {
            NSLog("GhosttyApp not initialized")
            return
        }

        // If command contains shell expansions ($(...), backticks, etc.), wrap in bash
        var resolvedCommand = command
        if let cmd = resolvedCommand, (cmd.contains("$(") || cmd.contains("`")) {
            resolvedCommand = "/bin/bash -c \(Self.shellEscape(cmd))"
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0

        // Helper to call ghostty_surface_new with optional C-string pointers.
        // withCString ensures pointer validity for the duration of the closure.
        func createWithStrings(wd: String?, cmd: String?) {
            let create = { (wdPtr: UnsafePointer<CChar>?, cmdPtr: UnsafePointer<CChar>?) in
                config.working_directory = wdPtr
                config.command = cmdPtr
                self.surface = ghostty_surface_new(app, &config)
            }
            switch (wd, cmd) {
            case let (wd?, cmd?):
                wd.withCString { wdPtr in cmd.withCString { cmdPtr in create(wdPtr, cmdPtr) } }
            case let (wd?, nil):
                wd.withCString { wdPtr in create(wdPtr, nil) }
            case let (nil, cmd?):
                cmd.withCString { cmdPtr in create(nil, cmdPtr) }
            case (nil, nil):
                create(nil, nil)
            }
        }
        createWithStrings(wd: workingDirectory, cmd: resolvedCommand)

        updateTrackingAreaInternal()

        if surface != nil {
            createAttempts = 0
            NSLog("[Ghostty] createSurface() succeeded, hasCallback=\(onSurfaceCreated != nil)")
            // Flush any text that arrived before the surface was ready
            if !pendingText.isEmpty {
                NSLog("[Ghostty] Flushing %d pending text segments", pendingText.count)
                let pending = pendingText
                pendingText = []
                for text in pending {
                    writeText(text)
                }
            }
            onSurfaceCreated?()
        } else {
            NSLog("[Ghostty] createSurface() FAILED — surface is nil")
            if createAttempts < Self.retryDelays.count {
                let delay = Self.retryDelays[createAttempts]
                createAttempts += 1
                NSLog("[Ghostty] retrying createSurface in %.1fs (attempt %d/%d)",
                      delay, createAttempts, Self.retryDelays.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.surface == nil else { return }
                    self.createSurface()
                }
            } else {
                NSLog("[Ghostty] createSurface() exhausted retries — giving up")
                createAttempts = 0
                onSurfaceCreationFailed?()
            }
        }
    }

    /// Single-quote a string for safe shell interpolation, escaping internal single quotes.
    private static func shellEscape(_ str: String) -> String {
        // Single-quote the string, escaping any internal single quotes
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - View Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil {
            createSurface()
        }
        if let surface {
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let fbFrame = convertToBacking(NSRect(origin: .zero, size: newSize))
        let xScale = fbFrame.size.width / newSize.width
        let yScale = fbFrame.size.height / newSize.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(surface, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            layer?.contentsScale = window.backingScaleFactor
        }
        guard let surface else { return }
        let fbFrame = convertToBacking(frame)
        let xScale = fbFrame.size.width / frame.size.width
        let yScale = fbFrame.size.height / frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        let size = frame.size
        if size.width > 0 && size.height > 0 {
            let scaledSize = convertToBacking(size)
            ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        }
    }

    public override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        guard let surface else { return }
        let size = frame.size
        if size.width > 0 && size.height > 0 {
            let fbFrame = convertToBacking(NSRect(origin: .zero, size: size))
            let xScale = fbFrame.size.width / size.width
            let yScale = fbFrame.size.height / size.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            ghostty_surface_set_size(surface, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingAreaInternal()
    }

    private func updateTrackingAreaInternal() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    // MARK: - Keyboard Input

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard surface != nil else { return false }

        // Intercept Ctrl+key and Cmd+key events so macOS doesn't steal them
        // from the terminal (e.g., Ctrl+C, Ctrl+/, Ctrl+Enter).
        // Cmd+C and Cmd+V are handled inside keyDown explicitly.
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
            self.keyDown(with: event)
            return true
        }

        return false
    }

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        // Handle Cmd+V (paste) directly
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            paste(self)
            return
        }

        // Handle Cmd+C (copy) directly
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copy(self)
            return
        }

        // Send key press to libghostty
        var key = ghostty_input_key_s()
        key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        key.mods = translateMods(event.modifierFlags)
        key.keycode = UInt32(event.keyCode)
        key.composing = false

        // consumed_mods: control and command never contribute to text translation on macOS
        key.consumed_mods = translateMods(event.modifierFlags.subtracting([.control, .command]))

        // unshifted_codepoint: the base character with no modifiers applied
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key.unshifted_codepoint = codepoint.value
            }
        }

        // Determine the text to send with the key event.
        // Control characters (< 0x20) are NOT sent as text — Ghostty handles
        // control-character mapping internally. For control chars, we send the
        // character with the control modifier stripped so Ghostty knows which key
        // was pressed. Function keys in the PUA range (F700-F8FF) are also excluded.
        let text: String? = {
            guard let characters = event.characters else { return nil }
            if characters.count == 1, let scalar = characters.unicodeScalars.first {
                if scalar.value < 0x20 {
                    // Control character — return the un-control'd character
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
                if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                    // Function key in Private Use Area — no text
                    return nil
                }
            }
            // Don't send text for command-modified keys
            if event.modifierFlags.contains(.command) { return nil }
            return characters
        }()

        // Only send text if the first codepoint is printable (>= 0x20)
        if let text, text.count > 0,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            text.withCString { ptr in
                key.text = ptr
                let handled = ghostty_surface_key(surface, key)
                if !handled {
                    self.interpretKeyEvents([event])
                }
            }
        } else {
            let handled = ghostty_surface_key(surface, key)
            if !handled {
                self.interpretKeyEvents([event])
            }
        }
    }

    // MARK: - Copy / Paste

    @objc public func paste(_ sender: Any?) {
        guard let surface else { return }
        let pasteboard = NSPasteboard.general
        guard let content = pasteboard.string(forType: .string) else { return }
        content.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(content.utf8.count))
        }
    }

    @objc public func copy(_ sender: Any?) {
        guard let surface else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_has_selection(surface),
              ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        if let ptr = text.text, text.text_len > 0 {
            let str = String(cString: ptr)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = translateMods(event.modifierFlags)
        key.keycode = UInt32(event.keyCode)
        ghostty_surface_key(surface, key)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = translateMods(event.modifierFlags)
        let action: ghostty_input_action_e = (mods.rawValue & mod != 0)
            ? GHOSTTY_ACTION_PRESS
            : GHOSTTY_ACTION_RELEASE

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods
        key.keycode = UInt32(event.keyCode)
        ghostty_surface_key(surface, key)
    }

    // MARK: - Mouse Input

    public override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, translateMods(event.modifierFlags))
    }

    public override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let scrollMods: ghostty_input_scroll_mods_t = event.hasPreciseScrollingDeltas ? 1 : 0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    // MARK: - Programmatic Text Input

    /// Write text to the terminal's PTY input (for crow CLI `send` command).
    ///
    /// Text segments are sent via `ghostty_surface_text`. Newlines are submitted
    /// by sending both `\r` to the PTY and a key event for Return (keycode 36).
    public func writeText(_ text: String) {
        guard let surface else {
            NSLog("[GhosttySurfaceView] writeText: no surface yet, buffering %d chars", text.count)
            pendingText.append(text)
            return
        }
        let parts = text.components(separatedBy: "\n")
        for (i, part) in parts.enumerated() {
            if !part.isEmpty {
                part.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(part.utf8.count))
                }
            }
            // For each \n boundary (except the last segment), send Enter
            if i < parts.count - 1 {
                // Send Return as a key event. We intentionally do NOT send \r
                // via ghostty_surface_text — for long text, the \r can race
                // with PTY buffer processing and submit before the final
                // characters from the preceding text call are delivered.
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.mods = GHOSTTY_MODS_NONE
                key.keycode = 36  // macOS Return key
                _ = ghostty_surface_key(surface, key)
                key.action = GHOSTTY_ACTION_RELEASE
                _ = ghostty_surface_key(surface, key)
            }
        }
        NSLog("[GhosttySurfaceView] writeText: sent \(text.count) chars, \(parts.count - 1) newlines")
    }

    // MARK: - Drag & Drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    /// Accept dropped file URLs and send their shell-escaped paths as terminal text.
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }

        NSLog("[GhosttySurfaceView] Drag-drop: \(urls.count) file(s)")
        let escapedPaths = urls.map { Self.shellEscapePath($0.path) }
        let text = escapedPaths.joined(separator: " ")

        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
        return true
    }

    /// Shell-escape a file path by single-quoting it if it contains special characters.
    private static func shellEscapePath(_ path: String) -> String {
        let needsEscaping = path.contains { c in
            " \t'\"\\()&|;!$`#*?[]{}~<>".contains(c)
        }
        guard needsEscaping else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Helpers

    /// Translate macOS modifier flags to Ghostty's modifier bitmask.
    private func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - Cleanup

    public func destroy() {
        onSurfaceCreated = nil
        onSurfaceCreationFailed = nil
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }
}

// MARK: - Accessibility

extension GhosttySurfaceView {
    public override func isAccessibilityElement() -> Bool {
        return true
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        return .textArea
    }

    public override func accessibilityHelp() -> String? {
        return "Terminal content area"
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        return selectedRange()
    }
}

// MARK: - NSTextInputClient (separate extension to avoid concurrency issues)

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let str = string as? String ?? (string as? NSAttributedString)?.string ?? ""
        str.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(str.utf8.count))
        }
        markedTextStorage = NSMutableAttributedString()
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str = string as? String ?? (string as? NSAttributedString)?.string ?? ""
        markedTextStorage = NSMutableAttributedString(string: str)
        guard let surface else { return }
        str.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
        }
    }

    public func unmarkText() {
        markedTextStorage = NSMutableAttributedString()
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange {
        markedTextStorage.length > 0 ? NSRange(location: 0, length: markedTextStorage.length) : NSRange(location: NSNotFound, length: 0)
    }
    public func hasMarkedText() -> Bool { markedTextStorage.length > 0 }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let point = convert(NSPoint(x: x, y: frame.height - y - h), to: nil)
        guard let windowPoint = window?.convertPoint(toScreen: point) else { return .zero }
        return NSRect(x: windowPoint.x, y: windowPoint.y, width: w, height: h)
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }
}
