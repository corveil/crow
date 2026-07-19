import Foundation

/// Thin wrapper around the `tmux` CLI.
///
/// Owns the (binary, socket, session-name) tuple and exposes typed methods
/// for the subset of tmux commands the production code actually uses.
/// Every public method shells out via `Process` — there is no long-lived
/// connection here. For paste-buffer staging, `loadBufferFromStdin` writes
/// payload bytes through a pipe to avoid ARG_MAX-derived `command too long`
/// errors that bite `send-keys -l` for >10KB strings (Phase 3 §3 finding).
///
/// Each `run(...)` invocation has a configurable timeout. The default is
/// 2 seconds — enough for any normal tmux command (typical CLI overhead is
/// ~70ms p95, see spike Phase 2a §2). Exceeding the timeout SIGTERMs the
/// child and throws `.timedOut`; callers wire that into a watchdog flow
/// that offers the user "Restart tmux server" (spec §10.1).
///
/// All methods are blocking until the spawned tmux process exits.
public struct TmuxController: Sendable {
    public let tmuxBinary: String
    public let socketPath: String
    public let sessionName: String

    /// Default per-call timeout. 2s is well above the p95 (~74ms in the
    /// spike) and matches the watchdog threshold in spec §10.1.
    public static let defaultTimeout: TimeInterval = 2.0

    public init(tmuxBinary: String, socketPath: String, sessionName: String) {
        self.tmuxBinary = tmuxBinary
        self.socketPath = socketPath
        self.sessionName = sessionName
    }

    // MARK: - Generic invocation

    /// Run `tmux -S <socket> <args...>`. Returns stdout on exit-0,
    /// throws on non-zero exit with stdout/stderr captured. Throws
    /// `TmuxError.timedOut` if the child doesn't exit within `timeout`.
    ///
    /// Stdout/stderr are drained on background threads **while** waiting for
    /// the child. Reading only after `waitUntilExit` deadlocks once output
    /// exceeds the ~64 KB pipe buffer — `capture-pane -pe -S -N` for a rich
    /// TUI pane routinely does, which made CROW-606 web-terminal replay
    /// silently no-op (`try?` swallowed the timeout).
    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval = TmuxController.defaultTimeout) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBinary)
        p.arguments = ["-S", socketPath] + args
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        // Arm the termination signal BEFORE run() (see makeTerminationSignal, #653).
        let done = makeTerminationSignal(for: p)
        try p.run()

        // Drain both pipes concurrently so a large capture can't fill the OS
        // pipe buffer and stall tmux before it exits. Boxes keep the mutable
        // Data off the caller's stack so the concurrent readers don't race a
        // local `var`.
        final class PipeBox: @unchecked Sendable { var data = Data() }
        let stdoutBox = PipeBox()
        let stderrBox = PipeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let watchdog = ProcessWatchdog(p, timeout: timeout)
        done.wait()
        watchdog.cancel()
        group.wait()

        let outString = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let errString = String(data: stderrBox.data, encoding: .utf8) ?? ""

        if watchdog.didFire {
            throw TmuxError.timedOut(args: args, after: timeout)
        }
        guard p.terminationStatus == 0 else {
            throw TmuxError.cliFailed(
                args: args,
                status: p.terminationStatus,
                stdout: outString,
                stderr: errString
            )
        }
        return outString
    }

    // MARK: - Server / session lifecycle

    public func killServer() {
        _ = try? run(["kill-server"])
    }

    /// `tmux new-session -d -s <name>` with optional config file (`-f`)
    /// and per-session env overrides (`-e KEY=VAL`).
    public func newSessionDetached(
        configPath: String? = nil,
        env: [String: String] = [:],
        command: String? = nil
    ) throws {
        var args: [String] = []
        if let configPath { args.append(contentsOf: ["-f", configPath]) }
        // Note: -f is a SERVER option, not a new-session option, so it
        // must come before "new-session" via the run() prepend. We pass
        // it through args here; run() will assemble correctly because
        // run() prepends `-S socket` only.
        args.append(contentsOf: ["new-session", "-d", "-s", sessionName])
        for (k, v) in env { args.append(contentsOf: ["-e", "\(k)=\(v)"]) }
        if let command { args.append(contentsOf: ["--", command]) }
        try run(args)
    }

    public func hasSession() -> Bool {
        ((try? run(["has-session", "-t", sessionName])) != nil)
    }

    public func listWindowIndices() throws -> [Int] {
        let out = try run(["list-windows", "-t", sessionName, "-F", "#{window_index}"])
        return out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// List each window's index and the command currently running in its
    /// active pane (`#{window_index}` + `#{pane_current_command}`). Used by the
    /// orphan-window reaper to distinguish a window running an agent from a
    /// bare login shell (#408).
    public func listWindowCommands() throws -> [(index: Int, command: String)] {
        let out = try run(["list-windows", "-t", sessionName,
                           "-F", "#{window_index}\t#{pane_current_command}"])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return (idx, parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Like `listWindowCommands` but also returns each window's (pinned) name, so
    /// the reconciler can positively identify agent windows and guard Managers by
    /// name without relying on the pane's foreground command (CROW-581).
    public func listWindows() throws -> [(index: Int, name: String, command: String)] {
        let out = try run(["list-windows", "-t", sessionName,
                           "-F", "#{window_index}\t#{window_name}\t#{pane_current_command}"])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return (idx,
                    parts[1].trimmingCharacters(in: .whitespaces),
                    parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Windows

    /// `timeout` defaults to the per-call default. Callers spawning a window
    /// while the app is under load (many concurrent hydrations, a contended
    /// main actor) can pass a longer budget so a slow `new-window` doesn't
    /// SIGTERM and leave the terminal window-less (issue #408).
    public func newWindow(
        name: String? = nil,
        cwd: String? = nil,
        env: [String: String] = [:],
        command: String? = nil,
        timeout: TimeInterval = TmuxController.defaultTimeout
    ) throws -> Int {
        var args = ["new-window", "-P", "-F", "#{window_index}", "-t", sessionName]
        if let name { args.append(contentsOf: ["-n", name]) }
        // -c sets the start-directory for the spawned shell. tmux otherwise
        // uses its OWN working directory (i.e., wherever Crow was launched
        // from) — which would make `claude --continue` in this window pick
        // up a session from the wrong project. Passing -c is mandatory for
        // multi-worktree usage.
        if let cwd, !cwd.isEmpty { args.append(contentsOf: ["-c", cwd]) }
        for (k, v) in env { args.append(contentsOf: ["-e", "\(k)=\(v)"]) }
        if let command { args.append(command) }
        let out = try run(args, timeout: timeout)
        guard let idx = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TmuxError.cliFailed(
                args: args,
                status: 0,
                stdout: out,
                stderr: "could not parse window index"
            )
        }
        return idx
    }

    public func selectWindow(index: Int) throws {
        try run(["select-window", "-t", "\(sessionName):\(index)"])
    }

    public func killWindow(index: Int) {
        _ = try? run(["kill-window", "-t", "\(sessionName):\(index)"])
    }

    // MARK: - Input routing (paste buffer path; see spec §7)

    /// Stage `data` into a named tmux buffer via stdin. Avoids the
    /// ARG_MAX-derived `command too long` error that hits `send-keys -l`
    /// for large payloads (~10KB+ in our measurements).
    ///
    /// Same `timeout` semantics as `run()` — if the child hangs (server
    /// wedged, pipe never drained), the watchdog SIGTERMs it and this
    /// throws `TmuxError.timedOut` rather than blocking the caller. The
    /// payload write itself is covered too: if the watchdog has already
    /// terminated the process, the stdin write will throw EPIPE which
    /// we convert to `.timedOut` for the caller.
    public func loadBufferFromStdin(
        name: String,
        data: Data,
        timeout: TimeInterval = TmuxController.defaultTimeout
    ) throws {
        let args = ["load-buffer", "-b", name, "-"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBinary)
        p.arguments = ["-S", socketPath] + args
        let stdin = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardError = stderr
        // Arm the termination signal BEFORE run() (see makeTerminationSignal, #653).
        let done = makeTerminationSignal(for: p)
        try p.run()

        let watchdog = ProcessWatchdog(p, timeout: timeout)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
        } catch {
            done.wait()
            watchdog.cancel()
            if watchdog.didFire {
                throw TmuxError.timedOut(args: args, after: timeout)
            }
            throw error
        }

        done.wait()
        watchdog.cancel()

        if watchdog.didFire {
            throw TmuxError.timedOut(args: args, after: timeout)
        }
        guard p.terminationStatus == 0 else {
            let errString = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw TmuxError.cliFailed(
                args: args,
                status: p.terminationStatus,
                stdout: "",
                stderr: errString
            )
        }
    }

    public func pasteBuffer(name: String, target: String) throws {
        try run(["paste-buffer", "-b", name, "-t", target])
    }

    /// `tmux send-keys -t <target> <keys...>`. Each entry in `keys` is passed
    /// as a separate argument (e.g. "Enter", "C-c"). Used by
    /// `TmuxBackend.sendText` to deliver an Enter *outside* the bracketed-paste
    /// bracket so prompts that end with `\n` are actually submitted (#264).
    public func sendKeys(target: String, keys: [String]) throws {
        try run(["send-keys", "-t", target] + keys)
    }

    public func deleteBuffer(name: String) {
        _ = try? run(["delete-buffer", "-b", name])
    }

    /// `tmux if-shell -F -t <target> '#{pane_in_mode}' 'send-keys -t <target> -X cancel'`.
    ///
    /// `send-keys -X cancel` errors when the pane isn't in a mode, so the
    /// `if-shell` guard keeps this a no-op in the common case. Called before
    /// `paste-buffer` in `TmuxBackend.sendText` so programmatic sends land
    /// even when the user scrolled the pane into copy-mode (#486): tmux's
    /// default `WheelUpPane` enters copy-mode, and `paste-buffer` doesn't
    /// deliver content while the pane is in a mode.
    public func cancelCopyModeIfActive(target: String) throws {
        try run([
            "if-shell", "-F", "-t", target, "#{pane_in_mode}",
            "send-keys -t \(target) -X cancel",
        ])
    }

    // MARK: - Diagnostic

    /// `tmux capture-pane -p [-e] -t <target> -S -<linesBack>`. Returns the
    /// pane contents from `linesBack` lines of history through the current
    /// screen. Used by the readiness timeout diagnostics to show what state the
    /// shell got stuck in (issue #256), and — with `escapes: true` (`-e`, which
    /// keeps SGR/color sequences) — to replay a pane's scrollback into a
    /// reconnecting web terminal (CROW-606).
    public func capturePane(target: String, linesBack: Int = 200, escapes: Bool = false) throws -> String {
        var args = ["capture-pane", "-p"]
        if escapes { args.append("-e") }
        args.append(contentsOf: ["-t", target, "-S", "-\(linesBack)"])
        // Rich TUI panes (Claude/Cursor) with escapes can be hundreds of KB;
        // give the drain room beyond the default 2s CLI budget (CROW-606).
        return try run(args, timeout: max(TmuxController.defaultTimeout, 10.0))
    }

    /// `tmux display-message -p -t <target> <format>`. Used by the readiness
    /// timeout diagnostics to read `#{pane_pid}` and `#{pane_current_command}`
    /// for the wedged window (issue #256).
    public func displayMessage(target: String, format: String) throws -> String {
        try run(["display-message", "-p", "-t", target, format])
    }

    public static func versionString(tmuxBinary: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBinary)
        p.arguments = ["-V"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        // Arm the termination signal BEFORE run() (see makeTerminationSignal, #653).
        let done = makeTerminationSignal(for: p)
        guard (try? p.run()) != nil else { return nil }
        done.wait()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `hasSession()` and `newSessionDetached(...)` already match the protocol
/// requirements — this conformance is what lets the real controller flow
/// through `TmuxBackend.ensureCockpitSession`.
extension TmuxController: CockpitSessionStarter {}

public enum TmuxError: Error, CustomStringConvertible {
    case cliFailed(args: [String], status: Int32, stdout: String, stderr: String)
    case timedOut(args: [String], after: TimeInterval)

    public var description: String {
        switch self {
        case let .cliFailed(args, status, stdout, stderr):
            let argString = args.joined(separator: " ")
            let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return "tmux \(argString) → exit \(status); stderr=\(trimmedErr); stdout=\(trimmedOut)"
        case let .timedOut(args, after):
            return "tmux \(args.joined(separator: " ")) timed out after \(String(format: "%.1f", after))s"
        }
    }
}

/// Install a termination signal on `p` and return the semaphore to wait on.
/// **Must be called before `p.run()`** so the handler is armed before the child
/// can exit (no lost-wakeup race).
///
/// Waiting on the returned semaphore blocks the caller WITHOUT pumping its run
/// loop. `Process.waitUntilExit()` instead spins a *nested run loop*; on the
/// main thread that nested loop can service an in-flight CoreAnimation commit
/// and re-entrantly dealloc an `_NSWindowTransformAnimation` mid-window-open
/// animation → SIGSEGV (#653). Offloading `waitUntilExit()` to a background
/// thread does NOT help: `Process` delivers termination via the *launching*
/// thread's run loop, so a process launched on the main thread (e.g. from the
/// `@MainActor` `TmuxBackend`) is never observed as exited while the main run
/// loop is blocked here — a hard deadlock.
///
/// `terminationHandler` sidesteps both: Foundation invokes it on its own
/// background queue, independent of any thread's run loop, so it fires even
/// while the caller is blocked on the semaphore and never pumps. A
/// `ProcessWatchdog`'s `terminate()` still unblocks the wait — the killed
/// child's termination fires the handler. Same pattern as
/// `SessionService`'s `terminationHandler` continuation.
private func makeTerminationSignal(for p: Process) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    return done
}

/// One-shot SIGTERM watchdog for a child Process. Schedules a timer
/// on a background queue at construction; if the timer fires before
/// `cancel()` is called, the wrapped process is sent `terminate()` and
/// `didFire` flips to true. Used by `run()` and `loadBufferFromStdin`
/// to keep the UI thread from wedging on a hung tmux server (spec
/// §10.1).
private final class ProcessWatchdog: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var fired = false

    init(_ p: Process, timeout: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        self.timer = timer
        timer.setEventHandler { [weak p, weak self] in
            guard let p, p.isRunning else { return }
            self?.fire()
            p.terminate()
        }
        timer.resume()
    }

    private func fire() { lock.lock(); fired = true; lock.unlock() }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    func cancel() { timer.cancel() }
}
