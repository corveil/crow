import AppKit
import Foundation

/// Floating search affordance pinned to the top of a terminal container
/// (#471 gap 2). Cmd+F in the surface toggles visibility via the
/// `.terminalBeginSearch` notification; ESC or the Done button hides it.
/// All search work is dispatched to `TmuxBackend` against the active
/// terminal — the bar itself owns no tmux state.
@MainActor
public final class TerminalSearchBar: NSView, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton()
    private weak var hostSurface: NSView?
    /// True once Enter has issued an initial search query. Gates ▲/▼ so
    /// `search-again` / `search-reverse` don't fire before tmux has an
    /// anchor match to step from.
    private var hasActiveSearch = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        searchField.placeholderString = "Find in terminal"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configure(button: prevButton, symbol: "chevron.up", fallback: "▲", action: #selector(findPrevious))
        configure(button: nextButton, symbol: "chevron.down", fallback: "▼", action: #selector(findNext))
        configure(button: doneButton, symbol: nil, fallback: "Done", action: #selector(closeSearch))

        let stack = NSStackView(views: [searchField, prevButton, nextButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        isHidden = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBeginSearch),
            name: .terminalBeginSearch,
            object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Track the surface the bar floats over so we can hand focus back to
    /// the terminal when the user closes the bar.
    public func setHostSurface(_ surface: NSView?) {
        hostSurface = surface
    }

    private func configure(
        button: NSButton, symbol: String?, fallback: String, action: Selector
    ) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        if let symbol,
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
            button.image = img
            button.title = ""
        } else {
            button.title = fallback
        }
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func handleBeginSearch() {
        // Only un-hide if this bar's container currently hosts the
        // shared cockpit surface. The cockpit surface is re-parented
        // between per-tab containers (see `TerminalSurfaceView` header),
        // so each container persists its own bar — observing the bare
        // notification would un-hide every previously-rendered tab's bar
        // at once.
        guard let surface = hostSurface, surface.superview === self.superview else {
            return
        }
        isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc private func closeSearch() {
        searchField.stringValue = ""
        hasActiveSearch = false
        isHidden = true
        if let id = TmuxBackend.shared.activeTerminalID {
            try? TmuxBackend.shared.exitCopyMode(id: id)
        }
        if let surface = hostSurface {
            window?.makeFirstResponder(surface)
        }
    }

    /// Run a fresh backward search from the cursor against the field's
    /// current query. Invoked by Enter; resets `hasActiveSearch` so the
    /// ▲/▼ buttons can step through matches via `search-again` /
    /// `search-reverse` without re-issuing the query.
    private func submitSearch() {
        guard let id = TmuxBackend.shared.activeTerminalID else { return }
        let query = searchField.stringValue
        guard !query.isEmpty else { return }
        do {
            try TmuxBackend.shared.searchInScrollback(
                id: id, query: query, direction: .backward
            )
            hasActiveSearch = true
        } catch {
            NSLog("[TerminalSearchBar] search failed: \(error)")
        }
    }

    @objc private func findPrevious() {
        // ▲ steps further in the same direction as the last search
        // (backward, by default). No-op until Enter has issued an
        // initial query — without an active search tmux has no anchor
        // to step from.
        guard hasActiveSearch, let id = TmuxBackend.shared.activeTerminalID else { return }
        do {
            try TmuxBackend.shared.searchAgain(id: id, reverse: false)
        } catch {
            NSLog("[TerminalSearchBar] search-again failed: \(error)")
        }
    }

    @objc private func findNext() {
        // ▼ flips direction (`search-reverse`) so the user can walk
        // forward through matches after stepping back too far. Mirrors
        // ▲'s no-op-before-initial-search semantics.
        guard hasActiveSearch, let id = TmuxBackend.shared.activeTerminalID else { return }
        do {
            try TmuxBackend.shared.searchAgain(id: id, reverse: true)
        } catch {
            NSLog("[TerminalSearchBar] search-reverse failed: \(error)")
        }
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSearch()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter triggers a fresh backward search; ▲/▼ then step
            // through matches without re-running the query.
            submitSearch()
            return true
        }
        return false
    }
}

public extension Notification.Name {
    /// Posted by the terminal surface when the user hits Cmd+F. Observed
    /// by `TerminalSearchBar` to show itself.
    static let terminalBeginSearch = Notification.Name("com.crow.terminal.beginSearch")
}
