import AppKit
import WebKit

/// NSView hosting xterm.js in a WKWebView, backed by a native PTY running the
/// configured shell command (typically `tmux attach-session`).
@MainActor
public final class XTermSurfaceView: NSView {
    private let webView: TerminalWebView
    private let messageHandler: MessageHandler
    private let navigationHandler: NavigationHandler
    private var pty = PTYProcess()
    private var pendingOutput: [Data] = []
    private var loadStarted = false
    private var isWebReady = false
    private var isPTYStarted = false

    /// Whether the terminal surface is live (web loaded and PTY spawned).
    public var hasSurface: Bool { isWebReady && isPTYStarted }

    public var onSurfaceCreated: (() -> Void)?
    public var onSurfaceCreationFailed: (() -> Void)?
    public var onProcessExit: ((Int32) -> Void)?

    public var terminalID: UUID?
    public var workingDirectory: String?
    public var command: String?

    public init(frame: NSRect, workingDirectory: String? = nil, command: String? = nil) {
        self.workingDirectory = workingDirectory
        self.command = command

        let config = WKWebViewConfiguration()
        messageHandler = MessageHandler()
        navigationHandler = NavigationHandler()
        config.userContentController.add(messageHandler, name: "crowReady")
        config.userContentController.add(messageHandler, name: "crowInput")
        config.userContentController.add(messageHandler, name: "crowResize")
        config.userContentController.add(messageHandler, name: "crowError")

        webView = TerminalWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        super.init(frame: frame)

        log("init frame=\(frame.width)x\(frame.height)")

        messageHandler.owner = self
        navigationHandler.owner = self
        webView.navigationDelegate = navigationHandler

        pty.onOutput = { [weak self] data in
            Task { @MainActor in self?.handlePTYOutput(data) }
        }
        pty.onExit = { [weak self] code in
            Task { @MainActor in self?.onProcessExit?(code) }
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    public func createSurface() {
        guard !loadStarted else { return }
        guard window != nil else {
            log("deferring createSurface — not in a window yet")
            return
        }
        guard let htmlURL = BundledResources.terminalHTMLURL else {
            log("terminal.html not found in bundle")
            onSurfaceCreationFailed?()
            return
        }
        loadStarted = true
        let folder = htmlURL.deletingLastPathComponent()
        log("loading terminal UI from \(htmlURL.path)")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: folder)
    }

    public func destroy() {
        onSurfaceCreated = nil
        onSurfaceCreationFailed = nil
        onProcessExit = nil
        pty.terminate()
        isPTYStarted = false
        isWebReady = false
        loadStarted = false
        pendingOutput.removeAll()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            log("attached to window (visible=\(window?.isVisible ?? false))")
            createSurface()
        } else if isWebReady {
            scheduleFit()
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(webView)
        return true
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "f" {
            NotificationCenter.default.post(name: .terminalBeginSearch, object: nil)
            return true
        }
        return false
    }

    fileprivate func handleWebReady() {
        guard !isWebReady else { return }
        isWebReady = true
        log("xterm.js ready")
        startPTYIfNeeded()
        flushPendingOutput()
        scheduleFit()
        onSurfaceCreated?()
    }

    fileprivate func handleLoadFailure(_ message: String) {
        log("load failed: \(message)")
        onSurfaceCreationFailed?()
    }

    fileprivate func handleJSError(_ message: String) {
        log("JS error: \(message)")
        onSurfaceCreationFailed?()
    }

    fileprivate func handleInput(_ data: String) {
        pty.write(data)
    }

    fileprivate func handleResize(rows: Int, cols: Int) {
        pty.resize(rows: UInt16(max(rows, 1)), cols: UInt16(max(cols, 1)))
    }

    private func startPTYIfNeeded() {
        guard isWebReady, !isPTYStarted else { return }
        guard let command else {
            log("no command configured")
            onSurfaceCreationFailed?()
            return
        }
        do {
            try pty.start(command: command, workingDirectory: workingDirectory)
            isPTYStarted = true
            log("PTY started")
        } catch {
            log("PTY start failed: \(error)")
            onSurfaceCreationFailed?()
        }
    }

    private func log(_ message: String) {
        NSLog("[XTermSurfaceView] %@", message)
        if let data = "[XTermSurfaceView] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func handlePTYOutput(_ data: Data) {
        guard isWebReady else {
            pendingOutput.append(data)
            return
        }
        sendToTerminal(data)
    }

    private func flushPendingOutput() {
        guard !pendingOutput.isEmpty else { return }
        let queued = pendingOutput
        pendingOutput.removeAll()
        for data in queued {
            sendToTerminal(data)
        }
    }

    private func sendToTerminal(_ data: Data) {
        let b64 = data.base64EncodedString()
        guard let json = try? JSONEncoder().encode(b64),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.crowWrite(\(jsonString))", completionHandler: nil)
    }

    fileprivate func scheduleFit() {
        webView.evaluateJavaScript("window.crowFit && window.crowFit()", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.webView.evaluateJavaScript("window.crowFit && window.crowFit()", completionHandler: nil)
        }
    }

    public override func layout() {
        super.layout()
        if window != nil, !loadStarted {
            createSurface()
        }
        if isWebReady {
            scheduleFit()
        }
    }
}

// MARK: - WKWebView (no native context menu)

/// Suppresses WebKit's Copy/Paste/Autofill/Services menus — tmux handles mouse via PTY.
private final class TerminalWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }
}

// MARK: - WKScriptMessageHandler

private final class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: XTermSurfaceView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            guard let owner else { return }
            switch message.name {
            case "crowReady":
                owner.handleWebReady()
            case "crowInput":
                if let body = message.body as? [String: Any],
                   let data = body["data"] as? String {
                    owner.handleInput(data)
                }
            case "crowResize":
                if let body = message.body as? [String: Any],
                   let rows = body["rows"] as? Int,
                   let cols = body["cols"] as? Int {
                    owner.handleResize(rows: rows, cols: cols)
                }
            case "crowError":
                if let body = message.body as? [String: Any],
                   let msg = body["message"] as? String {
                    owner.handleJSError(msg)
                }
            default:
                break
            }
        }
    }
}

// MARK: - WKNavigationDelegate

private final class NavigationHandler: NSObject, WKNavigationDelegate {
    weak var owner: XTermSurfaceView?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            owner?.scheduleFit()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            owner?.handleLoadFailure(error.localizedDescription)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            owner?.handleLoadFailure(error.localizedDescription)
        }
    }
}
