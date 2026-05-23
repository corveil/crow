# Terminal Runtime Alternatives: Research & Recommendations

**Issue:** [#103 — Investigate: Terminal Alternatives to Ghostty for Background Execution](https://github.com/radiusmethod/crow/issues/103)
**Date:** 2026-04-06

## Executive Summary

Crow's terminal runtime (embedded Ghostty) **requires a visible NSView attached to a window** before it can create a terminal surface and spawn a shell. This creates a hard sequential bottleneck: each session's terminal must be the active, visible tab to initialize, making concurrent workspace setup impossible.

The root cause is architectural — Ghostty couples Metal GPU rendering with shell process lifecycle. The `ghostty_surface_new()` C API requires an NSView pointer for its Metal rendering pipeline, and the shell is spawned as part of surface creation.

**Short-term fix:** Use an offscreen `NSWindow` to satisfy Ghostty's window requirement without user interaction — surfaces can initialize in the background while a different tab is visible.

**Long-term recommendation:** Decouple shell execution from terminal rendering by introducing a PTY management layer (using Darwin's `forkpty()`). Shells start immediately without any UI. A renderer (Ghostty, SwiftTerm, or other) attaches on-demand when the user views the tab.

---

## 1. Current Architecture

### 1.1 Ghostty Integration Overview

Crow embeds Ghostty via `GhosttyKit.xcframework`, a precompiled binary framework built from vendored source (`/vendor/ghostty`) using Zig. The integration consists of three files:

| File | Role |
|------|------|
| `GhosttyApp.swift` | Singleton managing `ghostty_app_t`, config loading, 60 FPS tick timer |
| `GhosttySurfaceView.swift` | `NSView` subclass hosting a `ghostty_surface_t` with Metal rendering |
| `TerminalSurfaceView.swift` | SwiftUI `NSViewRepresentable` wrapper + `TerminalManager` singleton |

### 1.2 The Focus/Visibility Bottleneck

The initialization chain requires **6 sequential steps**, gated on view visibility:

```
1. SessionService.hydrateState()
   └─ Sets terminalReadiness[id] = .uninitialized
   └─ Calls TerminalManager.trackReadiness(for: id)

2. User navigates to session tab
   └─ SwiftUI renders SessionDetailView → TerminalSurfaceView

3. TerminalSurfaceView.makeNSView()                    [TerminalSurfaceView.swift:88]
   └─ Calls TerminalManager.surface(for:workingDirectory:command:)
   └─ Creates GhosttySurfaceView, stores in surfaces dict

4. GhosttySurfaceView.viewDidMoveToWindow()             [GhosttySurfaceView.swift:98]
   └─ Guard: window != nil && surface == nil
   └─ Calls createSurface()

5. GhosttySurfaceView.createSurface()                   [GhosttySurfaceView.swift:41]
   └─ ghostty_surface_config_new()
   └─ config.platform.macos.nsview = self (Metal requirement)
   └─ config.scale_factor = window?.backingScaleFactor
   └─ ghostty_surface_new(app, &config) → spawns shell via PTY
   └─ Fires onSurfaceCreated callback → readiness = .surfaceCreated

6. 2-second hardcoded delay                              [TerminalSurfaceView.swift:67]
   └─ readiness = .shellReady
   └─ SessionService.launchClaude() sends "claude --continue\n"
```

**Steps 2-4 are the bottleneck.** The view must be part of an active SwiftUI hierarchy, which only happens when the user's selected session tab renders the `TerminalSurfaceView`. Without this, the chain stalls at step 1 indefinitely.

### 1.3 Impact

For N work sessions: **N x ~2.5 seconds of sequential initialization**, each requiring the user to manually switch to that session's tab. During batch workspace setup (e.g., launching 5 sessions via `crow new-terminal`), the Manager's orchestrating Claude Code cannot proceed until each terminal individually reaches `.shellReady`.

### 1.4 Ghostty C API Surface Used by Crow

```
// App lifecycle
ghostty_init()
ghostty_config_new() / ghostty_config_free()
ghostty_config_load_default_files() / ghostty_config_load_file()
ghostty_config_finalize()
ghostty_app_new() / ghostty_app_free()
ghostty_app_tick()

// Surface lifecycle
ghostty_surface_config_new()
ghostty_surface_new() / ghostty_surface_free()
ghostty_surface_set_focus()
ghostty_surface_set_size()
ghostty_surface_set_content_scale()

// Input
ghostty_surface_key()
ghostty_surface_text()
ghostty_surface_mouse_button() / ghostty_surface_mouse_pos() / ghostty_surface_mouse_scroll()
ghostty_surface_preedit() / ghostty_surface_ime_point()

// Output (read-only)
ghostty_surface_has_selection() / ghostty_surface_read_selection() / ghostty_surface_free_text()

// Runtime callbacks
ghostty_runtime_config_s  (wakeup, action, read_clipboard, write_clipboard, etc.)
```

**Notable gap:** There is no API to read terminal output programmatically. Crow can only send input and read user-selected text. There is no `ghostty_surface_read_output()` or similar.

---

## 2. Ghostty Pros and Cons

### 2.1 Strengths

| Strength | Detail |
|----------|--------|
| **GPU-accelerated rendering** | Metal-based rendering with SIMD UTF-8 decoding. Smooth 60fps scrolling and updates. |
| **Full VT emulation** | Complete xterm/VT220 terminal emulation handled internally by libghostty. |
| **Integrated PTY management** | Ghostty handles `forkpty()`, shell spawning, and process lifecycle. Crow has zero PTY code. |
| **Rich input handling** | Full keyboard (including key equivalents), mouse (click, drag, scroll), IME (international text input), and drag-and-drop file path insertion. |
| **Copy/paste & selection** | Built-in text selection, clipboard integration, and shell-escaped path drag-drop. |
| **Single dependency** | One xcframework wraps the entire terminal stack — no additional libraries needed. |
| **Active upstream development** | Ghostty 1.2.0 shipped September 2025; 1.3.0 planned for March 2026. |

### 2.2 Limitations

| Limitation | Detail |
|------------|--------|
| **Hard NSView+Window requirement** | `ghostty_surface_new()` requires `config.platform.macos.nsview` — a valid NSView pointer in a window. No headless mode exists. |
| **No background initialization** | Surface creation is gated on `viewDidMoveToWindow()`. Terminals cannot start until their tab is visible. |
| **Opaque shell lifecycle** | No API to access the underlying PTY file descriptor, process ID, or exit status. Shell management is entirely internal to libghostty. |
| **No programmatic output reading** | Cannot read terminal screen content or output stream. Only user-selected text is accessible. |
| **Always-running tick timer** | 60 FPS `ghostty_app_tick()` runs continuously (`GhosttyApp.swift:76`), even when all terminals are idle. |
| **Complex build chain** | Requires Zig 0.15.2, Metal Toolchain, vendored Ghostty submodule. Build script extracts `.o` files from Zig's internal cache. |
| **Tight rendering coupling** | Metal rendering and PTY lifecycle are inseparable at the libghostty level. Cannot defer rendering or create "display-less" surfaces. |

### 2.3 Build & Maintenance Burden

The Ghostty build (`scripts/build-ghostty.sh`) is the most complex part of Crow's build system:
- Requires vendored Ghostty source at `/vendor/ghostty`
- Builds with Zig (`zig build`) targeting `aarch64-macos` and `x86_64-macos`
- Extracts individual `.o` files from Zig's cache directory
- Links against Metal, IOSurface, QuartzCore frameworks
- Produces `GhosttyKit.xcframework` (universal binary)

Any upstream Ghostty changes require rebuilding this pipeline. The Zig dependency is pinned to a specific version (0.15.2).

---

## 3. Alternative Solutions

### 3.1 Headless PTY (`forkpty` / `posix_openpt`)

**What it is:** Direct use of macOS/Darwin POSIX pseudo-terminal APIs to spawn shell processes without any terminal emulator UI.

**How it works:**
```swift
import Darwin

var parentFD: Int32 = 0
var childFD: Int32 = 0
let pid = forkpty(&parentFD, nil, nil, nil)

if pid == 0 {
    // Child process — exec the shell
    execl("/bin/zsh", "zsh", nil)
} else {
    // Parent process — read/write via parentFD
    write(parentFD, "echo hello\n", 11)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(parentFD, &buffer, buffer.count)
}
```

**Assessment:**

| Dimension | Rating |
|-----------|--------|
| Background initialization | Full support — no UI required |
| Concurrent startup | Unlimited parallel PTY creation |
| Rendering | None — requires a separate renderer for display |
| Output capture | Full — read directly from PTY fd |
| macOS native | Yes — POSIX API, available on all macOS versions |
| Build complexity | Zero — no dependencies |
| Integration effort | **High** — must implement PTY lifecycle, signal handling, process reaping |
| Maturity | Mature — POSIX standard, used by every terminal emulator internally |

**Key advantage:** This is what Ghostty does internally. By using `forkpty()` directly, Crow decouples shell execution from rendering, enabling immediate background shell startup.

**Key risk:** Crow would need to manage process lifecycle (SIGCHLD handling, zombie reaping), PTY sizing (`TIOCSWINSZ`), and raw I/O buffering — all currently handled by Ghostty.

### 3.2 SwiftTerm

**What it is:** A pure Swift terminal emulator library by Miguel de Icaza. Provides both a terminal emulation engine and platform-specific views (AppKit `TerminalView`, UIKit `TerminalView`).

**Architecture:**
- **`Terminal`** — Core VT100/xterm emulation engine (UI-agnostic)
- **`LocalProcess`** — PTY management: creates pseudo-terminal, spawns shell, handles I/O
- **`HeadlessTerminal`** — Combines `Terminal` + `LocalProcess` without any view. The `process` property is public.
- **`TerminalView` (AppKit)** — NSView subclass for rendering

**Headless capability confirmed:** SwiftTerm's `HeadlessTerminal` class allows running a terminal session (PTY + VT emulation) without any UI. This is the exact capability Crow needs for background initialization.

**Assessment:**

| Dimension | Rating |
|-----------|--------|
| Background initialization | Full — `HeadlessTerminal` needs no UI |
| Concurrent startup | Unlimited |
| Rendering | CoreText-based (CPU), not GPU-accelerated. Lower visual quality than Metal. |
| Output capture | Full — `Terminal` object provides screen content, scrollback |
| macOS native | Yes — pure Swift, SPM package |
| Build complexity | Low — standard Swift Package Manager dependency |
| Integration effort | **Medium** — replace Ghostty views with SwiftTerm views, adapt input handling |
| Maturity | Production-tested — used in multiple macOS/iOS apps. Handles UTF-8, grapheme clusters better than xterm.js. |

**Key advantage:** Clean separation of PTY management, terminal emulation, and rendering. `HeadlessTerminal` is exactly the "background execution" primitive Crow needs.

**Key risk:** Rendering quality. SwiftTerm uses CoreText (CPU-based text rendering), not Metal GPU acceleration. For a developer tool where users stare at terminal output all day, this matters. However, SwiftTerm could be used for the headless backend while keeping Ghostty or another renderer for display.

### 3.3 xterm.js in WKWebView

**What it is:** A TypeScript terminal emulator that runs in the browser, embedded in a macOS app via `WKWebView`.

**How it would work:**
- WKWebView loads an HTML page with xterm.js
- JavaScript↔Swift bridge sends PTY data between native code and the web terminal
- Requires a native PTY backend (xterm.js is display-only, like Ghostty's surface)

**Assessment:**

| Dimension | Rating |
|-----------|--------|
| Background initialization | Partial — WKWebView can render offscreen but has overhead |
| Concurrent startup | Limited by WKWebView process count |
| Rendering | WebGL renderer available; good but not Metal-native quality |
| Output capture | Yes — JavaScript API provides full screen content |
| macOS native | No — web technology in a native wrapper |
| Build complexity | Medium — JavaScript bundling, bridge code |
| Integration effort | **High** — WKWebView setup, JS↔Swift bridge, PTY backend still needed |
| Maturity | Very mature — xterm.js powers VS Code's terminal, Hyper, and many web IDEs |

**Key advantage:** Proven at massive scale (VS Code). Rich addon ecosystem (search, web links, fit).

**Key risk:** Architectural mismatch. Adding a web runtime to a native macOS app introduces complexity, memory overhead (~50MB per WKWebView process), and a JavaScript↔Swift bridge. The PTY backend still needs to be built natively. This is the wrong direction for a native app that already has GPU-accelerated rendering.

**Verdict:** Not recommended. The overhead of WKWebView outweighs the benefits when native alternatives exist.

### 3.4 Terminal.app / iTerm2 Scripting

**What it is:** Use AppleScript or the Scripting Bridge to manage terminals in external applications.

```applescript
tell application "Terminal"
    do script "cd /path/to/worktree && claude --continue"
end tell
```

**Assessment:**

| Dimension | Rating |
|-----------|--------|
| Background initialization | Yes — Terminal.app handles everything |
| Concurrent startup | Yes |
| Rendering | N/A — external application handles it |
| Output capture | Very limited — AppleScript can read window content but unreliably |
| macOS native | Yes — but external dependency |
| Build complexity | Very low |
| Integration effort | **Low** — but loses embedded terminal experience |
| Maturity | Mature — AppleScript has been stable for decades |

**Key advantage:** Zero terminal management code. Shell processes "just work."

**Key risk:** Crow loses its embedded terminal experience. Sessions would open in separate Terminal.app or iTerm2 windows, breaking the unified session management UI. Users would need Terminal.app or iTerm2 installed. There is no way to embed these external terminals back into Crow's window.

**Verdict:** Not viable as a primary solution. Could be a fallback or "open in external terminal" option.

### 3.5 tmux / screen as Intermediary

**What it is:** Use tmux as a multiplexer layer. Crow creates tmux sessions for background execution and attaches a renderer when the user views the tab.

**How it would work:**
1. `tmux new-session -d -s crow-{uuid}` — creates a detached session
2. `tmux send-keys -t crow-{uuid} "claude --continue" Enter` — sends commands
3. When user views tab: attach a terminal emulator (Ghostty/SwiftTerm) running `tmux attach -t crow-{uuid}`

**tmux Control Mode (`-CC`):**
tmux supports a structured text protocol when launched with `-CC`. Instead of rendering a TUI, tmux sends structured messages (`%output`, `%begin`, `%end`) that a host application can parse. iTerm2 uses this for its tmux integration. Crow could implement the same protocol.

**Assessment:**

| Dimension | Rating |
|-----------|--------|
| Background initialization | Full — `tmux new-session -d` is designed for this |
| Concurrent startup | Unlimited |
| Rendering | Requires a renderer to "attach" (Ghostty, SwiftTerm, or control mode parser) |
| Output capture | Full — `tmux capture-pane`, control mode `%output` |
| macOS native | No — requires tmux installed (available via Homebrew) |
| Build complexity | Low — shell commands |
| Integration effort | **Medium** — session management via tmux CLI, attach/detach logic |
| Maturity | Very mature — tmux is battle-tested infrastructure |

**Key advantage:** tmux is purpose-built for the attach/detach pattern. Sessions survive terminal disconnection. The control mode protocol (`-CC`) enables structured communication without a TUI.

**Key risk:** External dependency (tmux must be installed). Adds a layer of indirection. Rendering quality depends on what attaches to the tmux session. The tmux control mode protocol is complex and not well-documented outside of iTerm2's implementation.

### 3.6 libvterm

**What it is:** A C99 library implementing VT220/xterm terminal emulation via callbacks. Used by Neovim for its built-in `:terminal`. Does not handle PTY creation or rendering — purely a state machine that parses terminal escape sequences.

**Assessment:**

| Dimension | Rating |
|-----------|--------|
| Background initialization | N/A — no PTY, no process management |
| Concurrent startup | N/A |
| Rendering | None — callback-based, requires custom renderer |
| Output capture | Full — the entire screen buffer is accessible via callbacks |
| macOS native | C library, requires bridging header for Swift |
| Build complexity | Low — small C library, easy to compile |
| Integration effort | **Very high** — must pair with PTY layer AND build a renderer |
| Maturity | Mature — powers Neovim's terminal. Bundled into Neovim's repo. |

**Key advantage:** Lightweight, pure terminal state machine. If Crow builds its own PTY layer, libvterm could provide the VT parsing without a full terminal emulator.

**Verdict:** Too low-level for Crow's needs. SwiftTerm's `Terminal` class provides the same VT parsing capability in pure Swift with a better API. Only useful if Crow needs C-level performance for terminal state management, which is unlikely given the workload (developer sessions, not high-throughput data streaming).

---

## 4. Hybrid Architecture

### 4.1 Proposed Design: Headless Execution + On-Demand Rendering

```
┌─────────────────────────────────────────────────────────┐
│                     Crow App                             │
│                                                          │
│  ┌──────────────────┐    ┌───────────────────────────┐  │
│  │   PTYManager      │    │   TerminalRenderer        │  │
│  │   (new layer)     │    │   (on-demand)             │  │
│  │                   │    │                           │  │
│  │  ┌─────────────┐ │    │  ┌───────────────────┐   │  │
│  │  │ PTYSession   │ │    │  │ GhosttySurfaceView│   │  │
│  │  │  - fd: Int32 │◄├────├──│ (or SwiftTerm)    │   │  │
│  │  │  - pid: pid_t│ │    │  │                   │   │  │
│  │  │  - buffer    │ │    │  │ Reads from buffer │   │  │
│  │  └─────────────┘ │    │  │ Sends input to fd │   │  │
│  │                   │    │  └───────────────────┘   │  │
│  │  ┌─────────────┐ │    │                           │  │
│  │  │ PTYSession   │ │    │  (Only created when      │  │
│  │  │ (session 2)  │ │    │   user views the tab)    │  │
│  │  └─────────────┘ │    │                           │  │
│  │                   │    │                           │  │
│  │  ┌─────────────┐ │    │                           │  │
│  │  │ PTYSession   │ │    │                           │  │
│  │  │ (session 3)  │ │    │                           │  │
│  │  └─────────────┘ │    │                           │  │
│  └──────────────────┘    └───────────────────────────┘  │
│                                                          │
│  Shell processes start immediately ──► No window needed  │
│  Renderer attaches on view ──────────► GPU when visible  │
└─────────────────────────────────────────────────────────┘
```

### 4.2 PTY Management Layer

A new `PTYManager` / `PTYSession` class that:

1. **Spawns shells via `forkpty()`** — no Ghostty, no NSView, no window required
2. **Maintains a scrollback buffer** — stores recent output (e.g., last 10,000 lines)
3. **Provides read/write access** — `write(fd, text)` for input, `read(fd)` for output
4. **Tracks process state** — PID, exit status, SIGCHLD handling
5. **Handles PTY sizing** — `TIOCSWINSZ` ioctl for terminal dimensions

```swift
// Conceptual API
class PTYSession {
    let id: UUID
    let fd: Int32           // PTY master file descriptor
    let pid: pid_t          // Child process ID
    var scrollback: Data    // Buffered output
    var isAlive: Bool       // Process still running

    func write(_ text: String)  // Send input to shell
    func read() -> Data         // Read buffered output
    func resize(cols: Int, rows: Int)
}

class PTYManager {
    static let shared = PTYManager()
    func spawn(workingDirectory: String, command: String?) -> PTYSession
    func destroy(id: UUID)
    func send(id: UUID, text: String)
}
```

### 4.3 Terminal State Buffering

For the hybrid architecture, a VT state buffer is needed so the renderer can display the terminal's current state when it attaches. Two options:

1. **Raw scrollback buffer** — Store the raw byte stream from the PTY. When a renderer attaches, replay the buffer to initialize the terminal view. Simple but may be slow for large buffers.

2. **SwiftTerm `HeadlessTerminal`** — Use SwiftTerm's terminal emulation engine to maintain a parsed screen state. When a renderer attaches, it reads the current screen content directly. More complex but provides immediate rendering without replay.

**Recommendation:** Start with option 1 (raw buffer replay) for simplicity. If performance is an issue with large scrollback, migrate to option 2.

### 4.4 On-Demand Renderer Attachment

When the user navigates to a session tab:

1. Check if a `PTYSession` exists for the terminal
2. Create a `GhosttySurfaceView` (or SwiftTerm `TerminalView`)
3. **Connect the renderer to the PTY session:**
   - Replay buffered output to initialize the screen
   - Route new PTY output to the renderer
   - Route renderer input (keyboard, mouse) to the PTY fd
4. When user navigates away: **detach the renderer** but keep the PTY session running

**Key insight:** The renderer lifecycle becomes independent of the shell lifecycle. Shells start on session creation; renderers start on tab navigation. This is the same pattern tmux uses.

### 4.5 Migration Path

| Phase | Change | Risk |
|-------|--------|------|
| **Phase 0** (short-term) | Offscreen NSWindow trick (see Section 7.1) | Low — minimal code change |
| **Phase 1** | Add `PTYManager` alongside Ghostty | Low — additive, no removals |
| **Phase 2** | Use `PTYManager` for managed terminals (Claude Code) | Medium — changes launch flow |
| **Phase 3** | Use `PTYManager` for all terminals, Ghostty as renderer only | High — architectural shift |
| **Phase 4** | Evaluate replacing Ghostty renderer with SwiftTerm | Optional — only if build complexity or rendering needs change |

---

## 5. Feature Comparison Matrix

| Feature | Ghostty (current) | Headless PTY | SwiftTerm | xterm.js + WKWebView | Terminal.app | tmux | libvterm |
|---|---|---|---|---|---|---|---|
| **Background shell spawn** | No | Yes | Yes (HeadlessTerminal) | No | Yes | Yes | N/A |
| **Concurrent init** | No | Yes | Yes | Partial | Yes | Yes | N/A |
| **GPU rendering** | Yes (Metal) | No | No (CoreText) | Yes (WebGL) | N/A | No | No |
| **PTY management** | Internal | Manual (`forkpty`) | Built-in (`LocalProcess`) | Manual | External | External | No |
| **Output capture** | No API | Yes (`read(fd)`) | Yes (screen buffer) | Yes (JS API) | Limited | Yes (`capture-pane`) | Yes (callbacks) |
| **macOS native** | Yes | Yes (POSIX) | Yes (Swift) | No (web) | Yes | No (Homebrew) | C library |
| **Build complexity** | High (Zig + Metal) | None | Low (SPM) | Medium (JS bundle) | None | None | Low (C) |
| **Integration effort** | Existing | High | Medium | High | Low | Medium | Very High |
| **Maturity** | High | Mature (POSIX) | High | Very High | Mature | Very High | High |
| **Input handling quality** | Excellent | Basic (raw write) | Good | Good | N/A | Via attached term | N/A |
| **Attach/detach** | No | With buffer | Partial | No | No | Native | N/A |
| **External dependency** | Vendored source | None | SPM package | npm + WKWebView | System app | Homebrew | C source |

---

## 6. Performance Analysis

### 6.1 Current Baseline (Estimated)

| Metric | Value | Source |
|--------|-------|--------|
| Single terminal init (surface creation → shellReady) | ~2.5s | 2s hardcoded delay + view lifecycle |
| N terminals (sequential, requires tab switching) | N x 2.5s + user interaction time | Manual tab switching required |
| 5 session workspace setup | ~15-30s (including manual tab switches) | Observed behavior |
| Memory per terminal (Ghostty surface) | ~20-50MB (Metal context + scrollback) | Metal rendering pipeline |
| CPU idle (tick timer, per terminal) | ~1-2% (60fps timer) | `ghostty_app_tick()` at 16.7ms interval |

### 6.2 Projected Improvements

| Approach | Single Init | N Terminals | Notes |
|----------|-------------|-------------|-------|
| **Current (Ghostty)** | ~2.5s sequential | N x 2.5s + manual | Requires tab focus |
| **Offscreen window trick** | ~2.5s but automatic | N x 2.5s (no manual) | Removes user interaction requirement |
| **Headless PTY** | <100ms | ~100ms total (concurrent) | Shell ready in <100ms via `forkpty()` |
| **SwiftTerm HeadlessTerminal** | <200ms | ~200ms total (concurrent) | Includes VT emulation setup |
| **tmux detached** | <200ms | ~200ms total (concurrent) | `tmux new-session -d` is fast |

### 6.3 Benchmark Methodology

To validate these estimates, measure:

1. **`forkpty()` spawn time**: Time from `forkpty()` call to shell printing first prompt. Use a probe command (`echo READY`) and measure time to see output on the PTY fd.

2. **Offscreen window init time**: Time from creating an offscreen `NSWindow` + adding `GhosttySurfaceView` to `onSurfaceCreated` callback firing.

3. **Concurrent scaling**: Spawn N=1, 5, 10, 20 PTY sessions concurrently and measure total time to all-ready.

4. **Renderer attach latency**: Time from creating a `GhosttySurfaceView` in a visible tab to first frame rendered, when attaching to an already-running PTY session.

---

## 7. Recommendations

### 7.1 Short-Term: Offscreen NSWindow Trick

**Goal:** Remove the user interaction requirement without replacing Ghostty.

**Approach:** Create a small, offscreen `NSWindow` and add `GhosttySurfaceView` instances to it. This satisfies the `viewDidMoveToWindow()` requirement without the view being visible to the user. When the user navigates to the session tab, move the view from the offscreen window to the real content area.

```swift
// Conceptual implementation in TerminalManager
private lazy var offscreenWindow: NSWindow = {
    let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.orderOut(nil)  // Never shown
    return window
}()

func preInitializeSurface(for id: UUID, workingDirectory: String, command: String?) {
    let view = GhosttySurfaceView(frame: .zero, workingDirectory: workingDirectory, command: command)
    view.onSurfaceCreated = { [weak self] in
        self?.surfaceDidCreate(id: id)
    }
    surfaces[id] = view
    offscreenWindow.contentView?.addSubview(view)
    // viewDidMoveToWindow() fires → createSurface() runs → shell spawns
}
```

**Effort:** ~50 lines of code. Changes limited to `TerminalManager`.

**Risks:**
- Metal rendering in an offscreen window may have GPU overhead (drawing frames nobody sees)
- The 60fps tick timer will tick for offscreen surfaces
- Offscreen windows may not receive the same Metal pipeline initialization on all macOS versions

**Mitigation:** Test on macOS 14+ (Sonoma/Sequoia). If Metal refuses to initialize in an offscreen window, try a 1x1 pixel visible window positioned off-screen.

### 7.2 Long-Term: Headless PTY Backend

**Goal:** Decouple shell execution from terminal rendering entirely.

**Recommended approach:** Introduce a `PTYManager` layer using Darwin `forkpty()` (see Section 4.2). This is preferred over SwiftTerm HeadlessTerminal or tmux because:

1. **Zero dependencies** — POSIX API, no additional libraries
2. **Minimal abstraction** — Crow needs to spawn a shell and write text. `forkpty()` + `write(fd)` does exactly this.
3. **Maximum flexibility** — Any renderer can attach later (Ghostty, SwiftTerm, or a future option)
4. **Proven pattern** — Every terminal emulator uses `forkpty()` internally. This just exposes it to Crow.

**For rendering**, keep Ghostty as the default renderer for visible terminals. The change is that Ghostty surfaces are created when the user views a tab (lazy rendering), not when the session starts. The shell is already running and has output buffered.

**SwiftTerm** is the recommended **alternative renderer** if Ghostty's build complexity becomes unsustainable or if the offscreen window trick proves insufficient. SwiftTerm's `HeadlessTerminal` could also replace the raw PTY layer if full VT state management is needed (e.g., for capturing structured terminal output).

### 7.3 Implementation Sequencing

```
Now ─────► Phase 0: Offscreen window trick (1-2 days)
           - Removes manual tab-switching requirement
           - All terminals auto-initialize on session creation
           - No architecture changes

Soon ────► Phase 1: PTYManager prototype (3-5 days)
           - Standalone PTYManager with forkpty()
           - Used only for managed terminals (Claude Code)
           - Ghostty still used for rendering
           - Claude Code starts within ~100ms of session creation

Later ───► Phase 2: Full PTY migration (1-2 weeks)
           - All terminals use PTYManager
           - Ghostty becomes a pure renderer (attach on view)
           - Remove 2-second delay heuristic
           - Add scrollback buffer for output replay

Future ──► Phase 3: Renderer evaluation (if needed)
           - Evaluate SwiftTerm as Ghostty replacement
           - Consider if Ghostty build complexity justifies the switch
           - This is optional — only if Ghostty causes maintenance issues
```

### 7.4 Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Offscreen Metal rendering fails on some macOS versions | Low | Medium | Fall back to 1x1 visible window; test on macOS 14-16 |
| `forkpty()` shell readiness detection is unreliable | Low | Medium | Use probe command (`echo $?`) instead of hardcoded delay |
| Ghostty renderer cannot attach to external PTY | Medium | High | Ghostty's `config.command` can run a program that connects to an existing PTY via `script` or similar |
| SwiftTerm rendering quality is noticeably worse | Medium | Low | Keep Ghostty as primary renderer; SwiftTerm only as fallback |
| Buffer replay for large scrollback is slow | Low | Low | Cap replay buffer; use SwiftTerm HeadlessTerminal for state snapshots if needed |

---

## Appendix

### A. Prototype: Offscreen Window Pre-Initialization

```swift
// Add to TerminalManager in TerminalSurfaceView.swift

/// Hidden window used to pre-initialize Ghostty surfaces without user interaction.
private lazy var offscreenWindow: NSWindow = {
    let w = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    w.isReleasedWhenClosed = false
    // Do NOT call orderFront/makeKeyAndOrderFront — window stays invisible
    return w
}()

/// Pre-initialize a terminal surface in the offscreen window.
/// The surface will be moved to the real view hierarchy when the user views the tab.
public func preInitialize(id: UUID, workingDirectory: String, command: String? = nil) {
    guard surfaces[id] == nil else { return }

    let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                   workingDirectory: workingDirectory,
                                   command: command)
    view.onSurfaceCreated = { [weak self] in
        self?.surfaceDidCreate(id: id)
    }
    surfaces[id] = view

    // Adding to offscreenWindow triggers viewDidMoveToWindow → createSurface()
    offscreenWindow.contentView?.addSubview(view)
}
```

### B. Prototype: Headless PTY Session

```swift
import Darwin

/// Minimal headless PTY session — spawns a shell without any terminal UI.
struct PTYSession {
    let masterFD: Int32
    let pid: pid_t

    /// Spawn a new shell process with a pseudo-terminal.
    static func spawn(workingDirectory: String = NSHomeDirectory(),
                      command: String = "/bin/zsh") -> PTYSession? {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        let pid = forkpty(&masterFD, nil, nil, nil)

        guard pid >= 0 else { return nil }

        if pid == 0 {
            // Child process
            chdir(workingDirectory)
            setenv("TERM", "xterm-256color", 1)
            execl(command, command, nil)
            _exit(1) // exec failed
        }

        // Parent — close slave fd (forkpty already duped it into the child)
        // masterFD is our read/write handle
        return PTYSession(masterFD: masterFD, pid: pid)
    }

    /// Send text to the shell.
    func write(_ text: String) {
        text.withCString { ptr in
            Darwin.write(masterFD, ptr, strlen(ptr))
        }
    }

    /// Read available output (non-blocking).
    func readAvailable() -> String? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Set non-blocking
        let flags = fcntl(masterFD, F_GETFL)
        fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        let n = Darwin.read(masterFD, &buffer, buffer.count)
        fcntl(masterFD, F_SETFL, flags) // Restore
        guard n > 0 else { return nil }
        return String(bytes: buffer[..<n], encoding: .utf8)
    }

    /// Resize the terminal.
    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFD, TIOCSWINSZ, &size)
    }
}
```

### C. Ghostty C API Functions Used by Crow (Complete List)

```
// Initialization & Config
ghostty_init(argc, argv)
ghostty_config_new() -> ghostty_config_t?
ghostty_config_load_default_files(config)
ghostty_config_load_file(config, path)
ghostty_config_finalize(config)
ghostty_config_free(config)

// App Lifecycle
ghostty_app_new(&runtime_config, config) -> ghostty_app_t?
ghostty_app_tick(app)
ghostty_app_free(app)

// Surface Lifecycle
ghostty_surface_config_new() -> ghostty_surface_config_t
ghostty_surface_new(app, &config) -> ghostty_surface_t?
ghostty_surface_free(surface)
ghostty_surface_set_focus(surface, focused)
ghostty_surface_set_size(surface, width, height)
ghostty_surface_set_content_scale(surface, x, y)

// Input
ghostty_surface_key(surface, key_event) -> Bool
ghostty_surface_text(surface, text_ptr, length)
ghostty_surface_mouse_button(surface, action, button, mods)
ghostty_surface_mouse_pos(surface, x, y, mods)
ghostty_surface_mouse_scroll(surface, dx, dy, scroll_mods)

// IME
ghostty_surface_preedit(surface, text_ptr, length)
ghostty_surface_ime_point(surface, &x, &y, &w, &h)

// Selection/Clipboard
ghostty_surface_has_selection(surface) -> Bool
ghostty_surface_read_selection(surface, &text) -> Bool
ghostty_surface_free_text(surface, &text)

// Runtime Callbacks (ghostty_runtime_config_s)
wakeup, action, read_clipboard, write_clipboard
```

### D. POSIX PTY API Reference (macOS/Darwin)

```c
// Open a pseudo-terminal pair
int posix_openpt(int flags);       // Returns master fd
int grantpt(int masterfd);         // Grant access to slave
int unlockpt(int masterfd);        // Unlock slave
char *ptsname(int masterfd);       // Get slave device path

// Combined fork + PTY setup
pid_t forkpty(int *master, char *name, struct termios *termp, struct winsize *winp);

// Terminal size
ioctl(fd, TIOCSWINSZ, &winsize);   // Set size
ioctl(fd, TIOCGWINSZ, &winsize);   // Get size

// Read/write
read(masterfd, buffer, count);      // Read output from shell
write(masterfd, text, length);      // Send input to shell
```

### E. References

- [SwiftTerm — GitHub](https://github.com/migueldeicaza/SwiftTerm)
- [SwiftTerm LocalProcess API](https://migueldeicaza.github.io/SwiftTerm/Classes/LocalProcess.html)
- [Ghostty — Official Site](https://ghostty.org/)
- [Ghostty — GitHub](https://github.com/ghostty-org/ghostty)
- [xterm.js — Official Site](https://xtermjs.org/)
- [tmux Control Mode — Wiki](https://github.com/tmux/tmux/wiki/Control-Mode)
- [iTerm2 tmux Integration](https://iterm2.com/documentation-tmux-integration.html)
- [libvterm — GitHub (Neovim fork)](https://github.com/neovim/libvterm)
- [macOS Metal + NSView Setup](https://metashapes.com/blog/advanced-nsview-setup-opengl-metal-macos/)
- [Apple Developer Forums — Swift PTY](https://developer.apple.com/forums/thread/688534)
- [Apple Developer Forums — forkpty in sandbox](https://developer.apple.com/forums/thread/685544)

---

## Implementation Status (2026-05)

The "long-term" recommendation in this document — a headless PTY backend that decouples terminal lifecycle from view rendering — landed in PR #229 as the **tmux backend**. tmux's control-mode protocol gives Crow a stable PTY supervisor without writing one from scratch, while a Swift `TmuxBackend` wraps the per-window operations Crow needs (spawn, send text via paste-buffer route, destroy).

Rollout history: #229 introduced it behind the `CROW_TMUX_BACKEND` flag (off by default); #301 made it the default; #303 removed the legacy per-terminal Ghostty path and the flag entirely, so tmux is now the only backend.

- tmux is the only backend; the Manager session runs on it too (#324).
- Per-terminal dispatch happens in `Sources/Crow/App/TerminalRouter.swift`, a thin facade over `TmuxBackend`.
- Requires `tmux ≥ 3.3`; missing-tmux is detected at launch and surfaced via a one-shot alert with a `brew install tmux` hint. Managed terminals don't render without it.

The short-term recommendation (offscreen `NSWindow` to unblock surface creation, see PR #105) was implemented earlier and is in production today.

See [architecture.md › Terminal Backends](architecture.md#terminal-backends) for the integration layer and [troubleshooting.md](troubleshooting.md) for common tmux-backend failure modes.
