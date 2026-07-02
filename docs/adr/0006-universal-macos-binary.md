# Status
Accepted

# Date
2026-07-01

# Deciders
Crow team (#548 Intel architecture audit)

# Context

Crow was developed and tested exclusively on Apple Silicon. The terminal renderer was libghostty (GhosttyKit), built from a Zig submodule into an arm64-only XCFramework. That made Intel Macs unable to run released builds or compile from source without a complex universal Ghostty build.

Issue #548 asked whether Crow could run on Intel Macs. A universal Ghostty build proved fragile (long Zig builds, linker issues with dual-arch SwiftPM + static GhosttyKit). The tmux session backend (ADR 0001) is architecture-agnostic; only the terminal *renderer* blocked Intel support.

# Decision

Replace Ghostty with an xterm.js terminal surface hosted in WKWebView, backed by a native PTY running `tmux attach-session`. Keep `TmuxBackend` unchanged as the sole terminal backend.

1. `XTermSurfaceView` loads vendored xterm.js assets from SPM resources and bridges PTY I/O via `WKScriptMessageHandler`.
2. `PTYProcess` spawns the attach command with `openpty` + `fork`/`exec`.
3. Remove GhosttyKit, Zig, and Metal toolchain from the build path. Crow builds with SwiftPM only.
4. Release artifacts ship as universal macOS binaries (`arm64` + `x86_64`) via `swift build --arch arm64 --arch x86_64`.

# Consequences

- Intel and Apple Silicon Macs build and run from the same source without Ghostty.
- Simpler CI (no submodule, no Zig cache, no framework assembly).
- Terminal UX regresses vs Ghostty for v1 spike: no GPU rendering, no OSC 8 link hover, no Quick Look on selection, no rich context menu. Search (Cmd+F) still routes through tmux.
- Manager process-exit banner (previously via Ghostty child-exit callback) is not wired for the shared attach client.

# Alternatives considered

- **Universal GhosttyKit build** — attempted on this branch; abandoned due to build complexity and SwiftPM + static library dual-arch linking issues.
- **SwiftTerm** — lower drift than xterm.js but less proven for tmux attach UX; xterm.js chosen for faster spike and familiar terminal emulation.
- **arm64-only with runtime rejection on Intel** — rejected; ticket calls for Intel support where feasible.

# References

- Issue #548
- ADR 0001 (tmux as sole terminal backend)
- Code: `XTermSurfaceView.swift`, `PTYProcess.swift`, `Packages/CrowTerminal/Resources/xterm/`
