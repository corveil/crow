import AppKit

/// An `NSWindow` that opts out of AppKit's automatic Touch Bar.
///
/// Crow never uses the Touch Bar, and the automatic teardown path
/// (`NSTouchBarFinder` → `NSMapTable dealloc`) intermittently SIGSEGVs during
/// the first window display commit (crow#563). Returning `nil` here keeps the
/// window's `touchBar` nil, so that code path is never exercised.
final class NoTouchBarWindow: NSWindow {
    override func makeTouchBar() -> NSTouchBar? { nil }
}
