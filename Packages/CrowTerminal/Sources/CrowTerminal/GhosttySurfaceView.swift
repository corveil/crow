import AppKit
import GhosttyKit
import QuickLookUI

/// NSView subclass that hosts a libghostty terminal surface with Metal rendering.
public final class GhosttySurfaceView: NSView {
    private var surface: ghostty_surface_t?
    private var pendingText: [String] = []
    private var markedTextStorage = NSMutableAttributedString()
    private var trackingArea: NSTrackingArea?
    private var hoveredLinkURL: String?

    /// Backing URL for the active Quick Look preview (spacebar, #471 gap 4).
    /// Either a remote URL pulled directly from the selection or a temp
    /// text file we wrote to render plain selection text. Cleared and the
    /// temp file removed when the preview panel closes.
    private var quickLookItem: NSURL?
    private var quickLookTempFile: URL?

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

    /// Toggle the pointing-hand cursor when libghostty reports the mouse is
    /// hovering an OSC 8 hyperlink, and stash the URL for the right-click
    /// "Open Link" menu item. Fed from `GHOSTTY_ACTION_MOUSE_OVER_LINK` in
    /// `GhosttyApp.handleAction()`. Pass `nil` when the mouse leaves the link.
    public func setHoveringLink(_ url: String?) {
        guard hoveredLinkURL != url else { return }
        let wasHovering = hoveredLinkURL != nil
        hoveredLinkURL = url
        if wasHovering != (url != nil) {
            window?.invalidateCursorRects(for: self)
        }
    }

    public override func resetCursorRects() {
        // I-beam by default so terminal text feels selectable like macOS
        // Terminal / iTerm2. Pointing-hand wins on hovered OSC 8 links —
        // AppKit picks the last-registered cursor whose rect contains the
        // point, so the order here matters.
        addCursorRect(bounds, cursor: .iBeam)
        if hoveredLinkURL != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
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

        // Cmd+F → open the search overlay (#471 gap 2). Notification is
        // observed by `TerminalSearchBar`; the bar takes first responder
        // from us so the user can type immediately.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "f" {
            NotificationCenter.default.post(name: .terminalBeginSearch, object: nil)
            return
        }

        // Cmd+↑ / Cmd+↓ → jump between OSC 133 prompts (#471 gap 6). Lives
        // before the generic Cmd path so the arrow keys don't reach the
        // surface (which would scroll a line). 126 = up, 125 = down on
        // macOS.
        if event.modifierFlags.contains(.command),
           event.keyCode == 126 || event.keyCode == 125,
           let id = TmuxBackend.shared.activeTerminalID {
            do {
                if event.keyCode == 126 {
                    try TmuxBackend.shared.previousPrompt(id: id)
                } else {
                    try TmuxBackend.shared.nextPrompt(id: id)
                }
            } catch {
                NSLog("[GhosttySurfaceView] prompt jump failed: \(error)")
            }
            return
        }

        // Spacebar Quick Look on an active selection (#471 gap 4). Bare
        // space only — modified space (Ctrl+Space, etc.) still goes to
        // the surface. We deliberately do not consume space when there's
        // no selection, so typing into the shell is unaffected.
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           ghostty_surface_has_selection(surface) {
            showQuickLook()
            return
        }

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
        guard surface != nil else { return }
        let pasteboard = NSPasteboard.general
        guard let content = pasteboard.string(forType: .string) else { return }

        // Multi-line paste safety prompt (iTerm2 / Terminal.app convention):
        // pastes that contain a newline can submit a destructive command
        // before the user realises what they pasted. Confirm via sheet, then
        // forward through the same path as a single-line paste.
        if content.contains("\n") || content.contains("\r") {
            confirmMultilinePaste(content)
            return
        }
        forwardPaste(content)
    }

    /// Forward already-vetted pasteboard text to the libghostty surface.
    /// Shared by single-line paste and the confirm-sheet handler.
    private func forwardPaste(_ content: String) {
        guard let surface else { return }
        content.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(content.utf8.count))
        }
    }

    /// Show a confirmation sheet before forwarding a paste that contains a
    /// newline. Modeless on `self.window`; falls back to a synchronous alert
    /// if the view is not yet attached to a window (shouldn't happen in
    /// practice, but a paste shortcut could arrive between detach and free).
    private func confirmMultilinePaste(_ content: String) {
        let alert = NSAlert()
        alert.messageText = "Paste multiple lines?"
        alert.informativeText = "The clipboard contains a line break, which may submit a command immediately."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")

        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn {
                forwardPaste(content)
            }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.forwardPaste(content)
        }
    }

    @objc public func copy(_ sender: Any?) {
        guard let str = currentSelectionText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(str, forType: .string)
    }

    /// Read the active selection from libghostty as a Swift `String`, or
    /// `nil` if there is no selection. Shared by Copy, the right-click
    /// smart-detect items, and Quick Look.
    private func currentSelectionText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_has_selection(surface),
              ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(cString: ptr)
    }

    // MARK: - Right-click context menu

    /// Build a context menu matching macOS terminal conventions: Copy / Paste /
    /// Select All / Clear / Open Link. Items are enabled/disabled at
    /// construction time against the current surface state (selection present,
    /// pasteboard contents, hovered link, known active terminal). Right-click
    /// position has already driven `mouseMoved` → `MOUSE_OVER_LINK`, so
    /// `hoveredLinkURL` already reflects what's under the cursor.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown || event.type == .rightMouseUp else {
            return super.menu(for: event)
        }

        let menu = NSMenu(title: "Terminal")
        // AppKit's default `autoenablesItems = true` ignores per-item
        // `isEnabled` and instead enables anything whose target responds to
        // its action selector — which would render every item enabled
        // regardless of selection / pasteboard / hover state. Disable so the
        // gating below is what users see.
        menu.autoenablesItems = false

        let hasSelection: Bool = {
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        }()
        let canPaste = NSPasteboard.general.canReadObject(
            forClasses: [NSString.self], options: nil
        )
        let activeTerminalID = TmuxBackend.shared.activeTerminalID
        let linkURL: URL? = {
            guard let raw = hoveredLinkURL,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  GhosttyApp.allowedURLSchemes.contains(scheme) else { return nil }
            return url
        }()

        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = canPaste
        menu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(contextSelectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self
        selectAllItem.isEnabled = activeTerminalID != nil
        menu.addItem(selectAllItem)

        let clearItem = NSMenuItem(
            title: "Clear",
            action: #selector(contextClear(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = activeTerminalID != nil
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let openLinkItem = NSMenuItem(
            title: "Open Link",
            action: #selector(contextOpenLink(_:)),
            keyEquivalent: ""
        )
        openLinkItem.target = self
        openLinkItem.representedObject = linkURL
        openLinkItem.isEnabled = linkURL != nil
        menu.addItem(openLinkItem)

        // Smart-detect items off the current selection (#471 gap 5). These
        // are hover-independent: select a bare URL or a `path:line` token
        // and the matching action lights up. Both items always render so the
        // menu shape is stable across selections; isEnabled gates dispatch.
        let selection = currentSelectionText()
        let detectedURL: URL? = selection.flatMap {
            SmartDetect.detectURL(in: $0, allowedSchemes: GhosttyApp.allowedURLSchemes)
        }
        let detectedFileLine: (path: String, line: Int)? = selection.flatMap {
            SmartDetect.detectFileLine(in: $0)
        }
        let resolvedFileURL: URL? = detectedFileLine.flatMap { resolveFileURL(path: $0.path) }

        menu.addItem(.separator())

        let openURLItem = NSMenuItem(
            title: "Open URL",
            action: #selector(contextOpenDetectedURL(_:)),
            keyEquivalent: ""
        )
        openURLItem.target = self
        openURLItem.representedObject = detectedURL
        openURLItem.isEnabled = detectedURL != nil
        menu.addItem(openURLItem)

        let openInEditorItem = NSMenuItem(
            title: "Open in Editor",
            action: #selector(contextOpenInEditor(_:)),
            keyEquivalent: ""
        )
        openInEditorItem.target = self
        openInEditorItem.representedObject = resolvedFileURL
        openInEditorItem.isEnabled = resolvedFileURL != nil
        menu.addItem(openInEditorItem)

        return menu
    }

    @objc private func contextSelectAll(_ sender: Any?) {
        guard let id = TmuxBackend.shared.activeTerminalID else { return }
        do {
            try TmuxBackend.shared.selectAll(id: id)
        } catch {
            NSLog("[GhosttySurfaceView] selectAll failed: \(error)")
        }
    }

    @objc private func contextClear(_ sender: Any?) {
        guard let id = TmuxBackend.shared.activeTerminalID else { return }
        do {
            try TmuxBackend.shared.clearHistory(id: id)
        } catch {
            NSLog("[GhosttySurfaceView] clearHistory failed: \(error)")
        }
    }

    @objc private func contextOpenLink(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func contextOpenDetectedURL(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func contextOpenInEditor(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let url = item.representedObject as? URL else { return }
        // v1 limitation: we resolve the file path but drop the line
        // number `SmartDetect.detectFileLine` parsed. Jumping to a
        // specific line is editor-specific (txmt://, vscode://, …) and
        // there is no portable way to pick one without a configurable
        // editor preference. Opening the file is still useful; line
        // navigation can be a follow-up once we add an editor setting.
        NSWorkspace.shared.open(url)
    }

    // MARK: - Quick Look

    /// Open `QLPreviewPanel` against the current selection (#471 gap 4).
    /// URL selections preview directly; plain text is staged into a tmp
    /// file under `$TMPDIR/crow-quicklook-<uuid>.txt`. Cleanup happens in
    /// `endPreviewPanelControl(_:)` when the user closes the preview.
    private func showQuickLook() {
        guard let selection = currentSelectionText() else { return }

        cleanupQuickLookTempFile()
        quickLookItem = nil

        if let url = SmartDetect.detectURL(
            in: selection, allowedSchemes: GhosttyApp.allowedURLSchemes
        ) {
            quickLookItem = url as NSURL
        } else {
            let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"]
                ?? NSTemporaryDirectory()
            let tmpURL = URL(fileURLWithPath: tmpDir)
                .appendingPathComponent("crow-quicklook-\(UUID().uuidString).txt")
            do {
                try selection.write(to: tmpURL, atomically: true, encoding: .utf8)
                quickLookTempFile = tmpURL
                quickLookItem = tmpURL as NSURL
            } catch {
                NSLog("[GhosttySurfaceView] Quick Look temp write failed: \(error)")
                return
            }
        }

        let panel = QLPreviewPanel.shared()
        if panel?.isVisible == true {
            panel?.reloadData()
        } else {
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func cleanupQuickLookTempFile() {
        guard let path = quickLookTempFile else { return }
        try? FileManager.default.removeItem(at: path)
        quickLookTempFile = nil
    }

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    // The QLPreviewPanel control hooks are inherited as nonisolated from
    // NSResponder, but AppKit only ever dispatches them on the main
    // thread. Hop via `MainActor.assumeIsolated` so we can touch the
    // surface's main-isolated state (panel.dataSource/.delegate are
    // themselves `@MainActor`).
    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === self { panel.dataSource = nil }
            if panel.delegate === self { panel.delegate = nil }
            cleanupQuickLookTempFile()
            quickLookItem = nil
        }
    }

    /// Resolve a `path:line` detection's path to a file URL by checking
    /// (1) absolute / cwd-relative on its own and (2) joined with the
    /// surface's `workingDirectory`. Returns nil if neither exists, so the
    /// "Open in Editor" item stays disabled rather than handing a bogus
    /// path to NSWorkspace.
    private func resolveFileURL(path: String) -> URL? {
        let fm = FileManager.default
        if (path as NSString).isAbsolutePath, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let cwd = workingDirectory {
            let joined = (cwd as NSString).appendingPathComponent(path)
            if fm.fileExists(atPath: joined) {
                return URL(fileURLWithPath: joined)
            }
        }
        // Last resort: treat as relative to the process cwd. Mostly a
        // no-op since Crow doesn't chdir, but avoids surprising the user
        // when they invoke from an unusual launcher.
        if fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
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
        // Note: smart-detect (gap 5) is intentionally NOT bound to
        // Cmd+click here. libghostty's C surface doesn't expose
        // text-at-point, so we can't verify the click landed on the
        // detected URL — a global "Cmd+click anywhere opens the
        // selected URL" would override macOS Terminal's
        // selection-extend convention and surprise the user. The
        // right-click menu's "Open URL" / "Open in Editor" items
        // already cover the selection-based flow.
        sendMousePosition(for: event)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        sendMousePosition(for: event)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        sendMousePosition(for: event)
    }

    private func sendMousePosition(for event: NSEvent) {
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

// MARK: - Quick Look conformance (#471 gap 4)

extension GhosttySurfaceView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return quickLookItem != nil ? 1 : 0
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return quickLookItem
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
