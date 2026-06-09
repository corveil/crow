// CROW-466 spike — renderer-agnostic typealias so call sites in
// `TmuxBackend` and `TerminalSurfaceView` don't need to know which
// renderer is linked. Both renderer NSViews expose the same public
// constructor + `terminalID`/`destroy()` surface used by callers.
//
// Flip via Package.swift when `CROW_RENDERER_SWIFTTERM=1` is exported
// before `swift build`.

import AppKit

#if CROW_RENDERER_SWIFTTERM
public typealias TerminalSurfaceImpl = SwiftTermSurfaceView
#else
public typealias TerminalSurfaceImpl = GhosttySurfaceView
#endif
