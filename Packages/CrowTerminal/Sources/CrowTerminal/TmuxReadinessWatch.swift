import CrowCore
import Foundation

/// Sentinel readiness watch, retry, and `.timedOut` diagnostics (#256 / #282).
///
/// Extracted from `TmuxBackend` (CROW-1222). `destroyTerminal` still cancels
/// in-flight tasks via the facade's `readinessTasks` map.

extension TmuxBackend {
    func sentinelPath(for id: UUID) -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (dir as NSString)
            .appendingPathComponent("crow-ready-\(id.uuidString).sentinel")
    }

    /// Per-terminal log path for `crow-shell-wrapper.sh` stage breadcrumbs
    /// (issue #256). Stable across `registerTerminal` / `adoptTerminal` /
    /// `retryReadinessWatch` for a given terminal UUID.
    func wrapperLogPath(for id: UUID) -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (dir as NSString)
            .appendingPathComponent("crow-wrapper-\(id.uuidString).log")
    }

    func startReadinessWatch(id: UUID, sentinelPath: String) {
        startReadinessWatch(id: id, sentinelPath: sentinelPath, timeoutBudget: 30.0)
    }

    func startReadinessWatch(id: UUID, sentinelPath: String, timeoutBudget: TimeInterval) {
        let waiter = SentinelWaiter()
        // Periodic progress beacon every 10s so operators tailing the log can
        // see the watch is alive and whether the sentinel has appeared yet
        // (issue #256). Cancelled when the waiter resolves.
        let progressTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                let exists = FileManager.default.fileExists(atPath: sentinelPath)
                _ = self  // keep the capture; method-level NSLog is fine
                CrowLog.info("[CrowTelemetry tmux:first_prompt_progress terminal=\(id) elapsed_ms=\(elapsed) sentinel_exists=\(exists)]")
            }
        }
        let waiterTask = Task { [weak self] in
            // 30s default budget (was 5s). On app restart with many managed
            // terminals hydrating concurrently, shell startup is CPU-contended
            // and the wrapper's first precmd may not fire within 5s. Callers
            // can pass a longer budget for retries (see retryReadinessWatch).
            let elapsed = await waiter.waitForPrompt(
                sentinelPath: sentinelPath,
                timeout: timeoutBudget
            )
            progressTask.cancel()
            await MainActor.run { [weak self] in
                // Bail if the terminal was destroyed (or the backend went
                // away) while we were waiting. Without this guard a 30s
                // waiter could fire readiness for a tab the user closed
                // 29s ago — issue #282.
                guard let self, self.bindings[id] != nil else { return }
                if let elapsed {
                    let ms = Int(elapsed * 1000)
                    CrowLog.info("[CrowTelemetry tmux:first_prompt_ms=\(ms) terminal=\(id)]")
                    self.onReadinessChanged?(id, .shellReady)
                } else {
                    // Genuine timeout. Most likely the shell is alive but its
                    // startup is pathologically slow (heavy zshrc + concurrent
                    // hydrate, cold tmux server + App Nap on a backgrounded
                    // app); less likely the wrapper failed to install the
                    // precmd hook (exotic shell) or the shell crashed at start.
                    //
                    // Surface this via `.timedOut` rather than lying about
                    // readiness. Auto-paste of the launch command relies on a
                    // live `zle`, so pasting blind here can leave the pane in
                    // an unrecoverable state (visible command, no Claude TUI,
                    // bytes consumed by half-initialized subshells). The UI
                    // renders a Retry affordance for `.timedOut`; the
                    // `didBecomeActive` observer also re-arms automatically
                    // when the app returns to the foreground.
                    let ms = Int(timeoutBudget * 1000)
                    CrowLog.info("[CrowTelemetry tmux:first_prompt_timeout terminal=\(id) budget_ms=\(ms)]")
                    // Capture stage-by-stage diagnostics and dump them to the
                    // system log alongside the timeout marker. The UI surfaces
                    // the same bundle via "Copy diagnostics" (issue #256).
                    let bundle = self.captureDiagnostics(id: id)
                    CrowLog.info("[CrowTelemetry tmux:first_prompt_diagnostics terminal=\(id)]\n\(bundle)")
                    self.onReadinessChanged?(id, .timedOut)
                }
            }
        }
        // Track both Tasks so `destroyTerminal` can cancel them (#282).
        // `retryReadinessWatch` may call us again for the same id; the
        // previous Tasks are already resolved (or about to be), so appending
        // here rather than replacing keeps the contract simple.
        readinessTasks[id, default: []].append(contentsOf: [progressTask, waiterTask])
    }

    /// Re-arm the readiness watch for a terminal whose first attempt timed
    /// out. Clears the stale sentinel file (in case the wrapper now writes
    /// to it asynchronously) and starts a fresh watch with a longer budget.
    /// Safe to call repeatedly; previous watches resolve independently.
    public func retryReadinessWatch(id: UUID, timeoutBudget: TimeInterval = 120.0) {
        guard let sentinelPath = sentinels[id] else { return }
        try? FileManager.default.removeItem(atPath: sentinelPath)
        startReadinessWatch(id: id, sentinelPath: sentinelPath, timeoutBudget: timeoutBudget)
    }

    /// Build a stage-by-stage diagnostic bundle for terminal `id`. Captures
    /// pane contents, pane PID + process tree, sentinel state, and the
    /// wrapper's breadcrumb log. Each section is wrapped so a single missing
    /// piece doesn't lose the rest; per-section output is capped to keep the
    /// clipboard payload sane. Called from the readiness-watch timeout path
    /// (logged via NSLog) and from the UI "Copy diagnostics" button
    /// (issue #256).
    public func captureDiagnostics(id: UUID) -> String {
        let sectionCap = 8_192
        var lines: [String] = []
        lines.append("=== Crow tmux readiness diagnostics ===")
        lines.append("terminal=\(id)")
        lines.append("captured_at=\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // Section 1: environment & host
        lines.append("--- environment ---")
        let env = ProcessInfo.processInfo.environment
        lines.append("SHELL=\(env["SHELL"] ?? "")")
        lines.append("PATH=\(env["PATH"] ?? "")")
        lines.append("TERM=\(env["TERM"] ?? "")")
        lines.append("USER=\(env["USER"] ?? "")")
        if !tmuxBinary.isEmpty,
           let ver = TmuxController.versionString(tmuxBinary: tmuxBinary) {
            lines.append("tmux=\(ver)")
        } else {
            lines.append("tmux=<unknown>")
        }
        if let dscl = runShortCommand(
            "/usr/bin/dscl",
            ["." , "-read", "/Users/\(env["USER"] ?? "")", "UserShell"]
        ) {
            lines.append("dscl=\(dscl.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append("")

        // Section 2: tmux state for this terminal's window
        lines.append("--- tmux state ---")
        guard let windowIndex = bindings[id] else {
            lines.append("no binding for terminal \(id) — window never created")
            lines.append("")
            return appendSentinelAndLog(id: id, sectionCap: sectionCap, lines: lines)
        }
        let ctrl = controller
        if let ctrl {
            let target = "\(ctrl.sessionName):\(windowIndex)"
            lines.append("target=\(target)")

            // pane_pid + pane_current_command — what's actually running in
            // the pane right now.
            var panePID: Int32?
            if let info = try? ctrl.displayMessage(
                target: target,
                format: "#{pane_pid} #{pane_current_command}"
            ) {
                let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("display_message=\(trimmed)")
                if let firstField = trimmed.split(separator: " ").first,
                   let pid = Int32(firstField) {
                    panePID = pid
                }
            } else {
                lines.append("display_message=<failed>")
            }
            lines.append("")

            // ps on the pane PID + immediate descendants. Reveals whether the
            // wrapper is still alive or has exec'd into the shell.
            lines.append("--- process tree ---")
            if let pid = panePID {
                if let ps = runShortCommand(
                    "/bin/ps",
                    ["-o", "pid,ppid,stat,etime,command", "-p", "\(pid)"]
                ) {
                    lines.append(ps.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if let children = runShortCommand("/usr/bin/pgrep", ["-P", "\(pid)"]) {
                    let childPIDs = children.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    for child in childPIDs {
                        if let ps = runShortCommand(
                            "/bin/ps",
                            ["-o", "pid,ppid,stat,etime,command", "-p", child]
                        ) {
                            lines.append(ps.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            } else {
                lines.append("<no pane pid available>")
            }
            lines.append("")

            // Pane capture — usually the single most useful signal: shows
            // whether we're stuck at the shell prompt, mid-.zshrc, or showing
            // a python traceback from oh-my-zsh.
            lines.append("--- pane capture (last 200 lines) ---")
            if let pane = try? ctrl.capturePane(target: target, linesBack: 200) {
                lines.append(truncated(pane, max: sectionCap))
            } else {
                lines.append("<capture-pane failed>")
            }
            lines.append("")
        } else {
            lines.append("controller not initialized")
            lines.append("")
        }

        return appendSentinelAndLog(id: id, sectionCap: sectionCap, lines: lines)
    }

    private func appendSentinelAndLog(id: UUID, sectionCap: Int, lines: [String]) -> String {
        var out = lines

        // Sentinel state — exists? size? parent writable?
        out.append("--- sentinel ---")
        if let path = sentinels[id] {
            out.append("path=\(path)")
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: path)
            out.append("exists=\(exists)")
            if exists, let attrs = try? fm.attributesOfItem(atPath: path) {
                if let size = attrs[.size] as? Int { out.append("size=\(size)") }
                if let mtime = attrs[.modificationDate] as? Date {
                    out.append("mtime=\(ISO8601DateFormatter().string(from: mtime))")
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            out.append("parent=\(parent) parent_writable=\(fm.isWritableFile(atPath: parent))")
        } else {
            out.append("no sentinel path recorded for terminal \(id)")
        }
        out.append("")

        // Wrapper log — the breadcrumb trail.
        out.append("--- wrapper log ---")
        if let path = wrapperLogs[id] {
            out.append("path=\(path)")
            if let data = try? String(contentsOfFile: path, encoding: .utf8) {
                out.append(truncated(data, max: sectionCap))
            } else {
                out.append("<log not readable or absent>")
            }
        } else {
            out.append("no wrapper log path recorded for terminal \(id)")
        }
        out.append("")
        out.append("=== end diagnostics ===")
        return out.joined(separator: "\n")
    }

    /// Run a short command and return its stdout (≤2s timeout). Used by
    /// `captureDiagnostics` so any single subprocess hanging can't wedge the
    /// main actor. Returns `nil` on any failure (missing binary, non-zero
    /// exit, timeout) so the caller can fall back gracefully.
    private func runShortCommand(_ launchPath: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let queue = DispatchQueue.global(qos: .utility)
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        queue.asyncAfter(deadline: .now() + 2.0, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func truncated(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let head = s.prefix(max)
        return head + "\n…(truncated; \(s.count - max) chars omitted)"
    }
}
