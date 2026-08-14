import CrowCore
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
/// All methods block the calling thread until the spawned tmux process exits
/// and its output is drained (both bounded — see `run`).
public struct TmuxController: Sendable {
    public let tmuxBinary: String
    public let socketPath: String
    public let sessionName: String

    /// Default per-call timeout. 2s is well above the p95 (~74ms in the
    /// spike) and matches the watchdog threshold in spec §10.1.
    public static let defaultTimeout: TimeInterval = 2.0

    /// Grace for the post-exit pipe drain.
    ///
    /// Deliberately **not** derived from `timeout`: that bounds the *child*,
    /// this bounds a drain whose child has already exited, so every remaining
    /// byte is already sitting in a ≤64 KB kernel pipe buffer. The only thing
    /// this budget must absorb is GCD worker bring-up under contention. Tying it
    /// to `timeout` would hand `capturePane` a pointless 10s stall — on the
    /// MainActor — for microseconds of actual work.
    public static let drainGrace: TimeInterval = 0.25

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
    /// the child. Reading only after the child exits deadlocks once output
    /// exceeds the ~64 KB pipe buffer — `capture-pane -pe -S -N` for a rich
    /// TUI pane routinely does, which made CROW-606 web-terminal replay
    /// silently no-op (`try?` swallowed the timeout).
    ///
    /// Both waits are bounded. The drain in particular gets `drainGrace` rather
    /// than running unbounded: EOF needs *every* copy of the pipe's write end to
    /// close, and a process that inherited one at spawn time can hold it open
    /// long after the tmux child is reaped (CROW-874).
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
        // pipe buffer and stall tmux before it exits.
        let stdoutBox = PipeBox()
        let stderrBox = PipeBox()
        let group = DispatchGroup()
        drain(stdout.fileHandleForReading, into: stdoutBox, group: group)
        drain(stderr.fileHandleForReading, into: stderrBox, group: group)
        let watchdog = ProcessWatchdog(p, timeout: timeout)
        done.wait()
        watchdog.cancel()
        let drainIncomplete = group.wait(timeout: .now() + Self.drainGrace) == .timedOut

        let outString = String(data: stdoutBox.snapshot(), encoding: .utf8) ?? ""
        let errString = String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""

        if watchdog.didFire {
            throw TmuxError.timedOut(args: args, after: timeout)
        }
        if drainIncomplete {
            // NOT an error: `done.wait()` returned, so the child exited and
            // wrote everything it will ever write — and because the readers are
            // incremental, we already hold those bytes. Only the EOF notice is
            // missing. Throwing here would be actively harmful: `.timedOut`
            // drives TmuxBackend.onUnresponsive, which offers the user "Restart
            // tmux server" — destroying their terminals over our own fd hygiene.
            CrowLog.info(
                "[TmuxController] pipe drain hit \(Self.drainGrace)s without EOF for "
                    + "`tmux \(args.joined(separator: " "))` (status \(p.terminationStatus)); "
                    + "another process inherited the pipe. Continuing with the captured output.")
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

    /// Discards stdout; captures stderr in a temp file so `cliFailed` still
    /// carries tmux's message. Used for `new-session -d` when a pipe reader
    /// would stay blocked for the tmux server's lifetime (CROW-645) — a file
    /// fd does not wait on EOF. The capture file is unlinked after exit while
    /// tmux may still hold the fd; the inode stays writable until the server
    /// closes it. Thrown errors have empty `stdout`; `stderr` is populated from
    /// the temp capture on non-zero exit.
    private func runDiscardingOutput(
        _ args: [String],
        timeout: TimeInterval = TmuxController.defaultTimeout
    ) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBinary)
        p.arguments = ["-S", socketPath] + args
        guard let nullOut = FileHandle(forWritingAtPath: "/dev/null") else {
            throw TmuxError.cliFailed(args: args, status: -1, stdout: "", stderr: "cannot open /dev/null")
        }
        p.standardOutput = nullOut
        let errURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-tmux-\(UUID().uuidString).err")
        defer { try? FileManager.default.removeItem(at: errURL) }
        FileManager.default.createFile(
            atPath: errURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard let errFH = FileHandle(forWritingAtPath: errURL.path) else {
            throw TmuxError.cliFailed(args: args, status: -1, stdout: "", stderr: "cannot create stderr capture file")
        }
        p.standardError = errFH
        let done = makeTerminationSignal(for: p)
        try p.run()
        let watchdog = ProcessWatchdog(p, timeout: timeout)
        done.wait()
        watchdog.cancel()
        try? errFH.close()
        let errString = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if watchdog.didFire {
            throw TmuxError.timedOut(args: args, after: timeout)
        }
        guard p.terminationStatus == 0 else {
            throw TmuxError.cliFailed(args: args, status: p.terminationStatus, stdout: "", stderr: errString)
        }
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
        try runDiscardingOutput(args)
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

    /// Per-window scrollback health: each window's index plus the three facts
    /// that determine whether scroll-up can show the full transcript —
    /// `#{history_limit}` (the frozen-at-birth scrollback cap), `#{alternate_on}`
    /// (whether the active pane is CURRENTLY in the alternate buffer, which has
    /// NO scrollback), and `#{alternate-screen}` (whether this window is
    /// CONFIGURED to honor the alternate screen at all).
    ///
    /// Windows created before the current `crow-tmux.conf` are stuck at
    /// `history_limit=5000 alternate_on=1` and tmux cannot resize/undo either in
    /// place, so this is how Crow detects the degraded windows that need a
    /// recreate (CROW-804).
    ///
    /// The `alternate-screen` OPTION is what separates "degraded" from "working
    /// as designed" under the hybrid scroll model (ADR-0013): agent-TUI windows
    /// deliberately run with it `on`, so `alternate_on=1` there is expected
    /// rather than broken. It is a window OPTION, not a pane variable, but tmux
    /// resolves options in format strings, so one `list-windows` read serves
    /// both the health check and the agent-surface classification. (Verified on
    /// tmux 3.6a: a real option renders `0`/`1`, an unknown one renders empty.)
    public func listWindowScrollback() throws
        -> [(index: Int, historyLimit: Int, alternateOn: Bool, alternateScreenEnabled: Bool)] {
        let out = try run(["list-windows", "-t", sessionName,
                           "-F", "#{window_index}\t#{history_limit}\t#{alternate_on}\t#{alternate-screen}"])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let limit = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            // tmux renders boolean flags AND boolean options as "1"/"0".
            let alt = parts[2].trimmingCharacters(in: .whitespaces) == "1"
            let altOption = parts[3].trimmingCharacters(in: .whitespaces) == "1"
            return (idx, limit, alt, altOption)
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

    /// Set a tmux WINDOW option on a single window, overriding the global
    /// default from `crow-tmux.conf` for that window only.
    ///
    /// Crow's terminal settings are otherwise all server-global (set once at
    /// startup via `tmux -f crow-tmux.conf`); this is the one place a window
    /// deviates. It exists for the per-surface hybrid scroll model (ADR-0013):
    /// agent-TUI windows get `alternate-screen on` so their full-frame repaints
    /// stay in the alt buffer instead of silting up the shared scrollback, while
    /// plain shell windows keep the global `off` and the unified 50k history.
    public func setWindowOption(index: Int, name: String, value: String) throws {
        try run(["set-window-option", "-t", "\(sessionName):\(index)", name, value])
    }

    /// Set a tmux SESSION option on this controller's session.
    ///
    /// Used to sandwich `new-window` with a temporary `history-limit` so an
    /// inline-rendering agent surface is *born* with a scrollback-less main
    /// buffer (CROW-1008). `history-limit` is frozen at window birth — a
    /// subsequent `setw` does not change `#{history_limit}` — so the session
    /// option has to move before the window exists, then move back.
    public func setSessionOption(name: String, value: String) throws {
        try run(["set-option", "-t", sessionName, name, value])
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

        // Drain stderr concurrently rather than lazily on the failure path: a
        // read that only happens after the child exits deadlocks once the output
        // exceeds the pipe buffer. `load-buffer` error text is short, so that
        // was latent rather than live — but it is the same bug as CROW-606.
        let stderrBox = PipeBox()
        let group = DispatchGroup()
        drain(stderr.fileHandleForReading, into: stderrBox, group: group)

        let watchdog = ProcessWatchdog(p, timeout: timeout)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
        } catch {
            done.wait()
            watchdog.cancel()
            _ = group.wait(timeout: .now() + Self.drainGrace)
            if watchdog.didFire {
                throw TmuxError.timedOut(args: args, after: timeout)
            }
            throw error
        }

        done.wait()
        watchdog.cancel()
        _ = group.wait(timeout: .now() + Self.drainGrace)

        if watchdog.didFire {
            throw TmuxError.timedOut(args: args, after: timeout)
        }
        guard p.terminationStatus == 0 else {
            throw TmuxError.cliFailed(
                args: args,
                status: p.terminationStatus,
                stdout: "",
                stderr: String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
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
        // Reachable from `captureDiagnostics` on the MainActor, so it needs the
        // same two bounds as `run()`. It previously had neither: no watchdog at
        // all, and a `readDataToEndOfFile()` *after* the exit wait — the >64 KB
        // deadlock the doc on `run()` warns about (CROW-874).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBinary)
        p.arguments = ["-V"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Arm the termination signal BEFORE run() (see makeTerminationSignal, #653).
        let done = makeTerminationSignal(for: p)
        guard (try? p.run()) != nil else { return nil }

        let outBox = PipeBox()
        let errBox = PipeBox()
        let group = DispatchGroup()
        drain(out.fileHandleForReading, into: outBox, group: group)
        drain(err.fileHandleForReading, into: errBox, group: group)

        let watchdog = ProcessWatchdog(p, timeout: defaultTimeout)
        done.wait()
        watchdog.cancel()
        _ = group.wait(timeout: .now() + drainGrace)

        guard !watchdog.didFire, p.terminationStatus == 0 else { return nil }
        return String(data: outBox.snapshot(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Read `handle` into `box` until EOF, on a background queue.
///
/// Uses raw `read(2)` rather than any `FileHandle` read method, and that is
/// load-bearing (CROW-874):
///
/// - `readDataToEndOfFile()` is all-or-nothing — it buffers internally and hands
///   back a `Data` only at EOF, so on a bounded-drain timeout the box would hold
///   **zero** bytes rather than the output the child already wrote.
/// - `read(upToCount:)` reads that many bytes, not *up to* that many: measured
///   on Darwin, it blocks until the full count or EOF, so with a 64 KB request
///   it behaves exactly like `readDataToEndOfFile()` for our purposes.
/// - `availableData` returns after one read, but raises an uncatchable
///   Objective-C exception on read error.
///
/// A single `read(2)` returns as soon as any bytes are available, so once the
/// child has exited every byte it wrote is in the box even when EOF never
/// arrives because some other process inherited the write end.
///
/// The closure retains `handle`, which owns the descriptor — the reader may
/// outlive the call that started it, and closing an fd under a blocked `read(2)`
/// is undefined behavior on Darwin.
private func drain(_ handle: FileHandle, into box: PipeBox, group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
            if n > 0 {
                box.append(Data(buffer[0..<n]))
                continue
            }
            if n < 0 && errno == EINTR { continue }
            break  // 0 = EOF; < 0 = a real error, nothing more to read.
        }
        group.leave()
    }
}

/// Lock-protected accumulator for a pipe drain.
/// Once the drain wait is bounded, the reader can still be running when the
/// caller snapshots — there is no way to interrupt a blocking read on a pipe fd,
/// and closing the fd out from under it is undefined behavior on Darwin and
/// invites fd-number reuse. So the accessor has to be race-free on its own
/// rather than relying on the wait having guaranteed the writers finished; that
/// guarantee is exactly what bounding the wait gives up.
private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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

/// One-shot SIGTERM watchdog for a child Process, escalating to SIGKILL.
/// Schedules a timer on a background queue at construction; if the timer
/// fires before `cancel()` is called, the wrapped process is sent
/// `terminate()` and `didFire` flips to true. Used by `run()` and
/// `loadBufferFromStdin` to keep the caller from wedging on a hung tmux
/// server (spec §10.1).
///
/// The timer repeats so a child that ignores or blocks SIGTERM gets SIGKILL on
/// the next tick. Without that, `done.wait()` is bounded only in theory: the
/// semaphore is signalled by `terminationHandler`, which needs the child to
/// actually die (CROW-874).
private final class ProcessWatchdog: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var fired = false

    init(_ p: Process, timeout: TimeInterval, killAfter: TimeInterval = 1.0) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout, repeating: killAfter)
        self.timer = timer
        timer.setEventHandler { [weak p, weak self] in
            guard let self else { return }
            guard let p, p.isRunning else { self.timer.cancel(); return }
            if self.didFire {
                // Second tick: SIGTERM was ignored or the child is wedged.
                kill(p.processIdentifier, SIGKILL)
                self.timer.cancel()
            } else {
                self.fire()
                p.terminate()
            }
        }
        timer.resume()
    }

    private func fire() { lock.lock(); fired = true; lock.unlock() }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    func cancel() { timer.cancel() }
}
