import Darwin
import Foundation

/// Captures crashes that the macOS crash reporter misses or buries.
///
/// Three classes of crash motivated this (#266):
///   1. POSIX signals (SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP) raised
///      out of SwiftUI's AttributeGraph or native library wrappers, which
///      can vanish the process without producing a `.ips` file.
///   2. Swift runtime traps (`fatalError`, `precondition`) which print to
///      stderr and then `abort()` — stderr is otherwise discarded for
///      .app bundles double-clicked from Finder.
///   3. Uncaught `NSException`s (already handled in #240, folded in here
///      so all paths land in the same on-disk artifact).
///
/// On each launch a new log file is opened at
/// `~/.local/share/crow/crash-logs/crow-<ISO8601>.log` and `stderr` is
/// redirected to it. Signal handlers write a short header plus the raw
/// stack via `backtrace_symbols_fd(3)` and then re-raise the signal so the
/// OS still has a chance to write `.ips`. A marker file alongside the log
/// records that the prior launch crashed, surfaced on next launch via
/// `unseenPriorCrashLog()`.
///
/// Symbolication: the on-disk frames are raw addresses + mangled symbol
/// names. Pair with the build's `.dSYM` and `atos` to demangle.
enum CrashReporter {
    static let logDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/crow/crash-logs", isDirectory: true)

    private static let markerFilename = ".unseen-crash"
    private static let maxRetainedLogs = 20
    private static let signals: [Int32] = [
        SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP,
    ]

    // Mutable state is touched once on the main thread at install time and
    // then read-only from C signal handlers, so `nonisolated(unsafe)` is safe
    // here.
    nonisolated(unsafe) private static var currentLogURL: URL?
    nonisolated(unsafe) private static var priorCrashLogURL: URL?
    nonisolated(unsafe) private static var logFD: Int32 = -1
    nonisolated(unsafe) private static var markerPathCString: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var backtraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    private static let backtraceCapacity: Int32 = 128
    nonisolated(unsafe) private static var installed = false

    // MARK: - Public API

    /// Idempotent. Safe to call multiple times; subsequent calls are no-ops.
    /// Must be invoked on the main thread at app launch before any other
    /// AppDelegate work so the next exit (graceful or not) lands in the log.
    static func install() {
        guard !installed else { return }
        installed = true

        ensureDirectory()
        priorCrashLogURL = detectPriorCrash()
        rotateOldLogs()
        openCurrentLog()
        prepareSignalHandlerBuffers()
        redirectStderr()
        installSignalHandlers()
        installExceptionHandler()
    }

    /// The crash log written by the previous launch, if it crashed.
    /// Returns nil after `acknowledgePriorCrash()` is called.
    static func unseenPriorCrashLog() -> URL? { priorCrashLogURL }

    /// Clears the cached "prior crash" pointer and removes the marker file.
    static func acknowledgePriorCrash() {
        priorCrashLogURL = nil
        let markerURL = logDirectory.appendingPathComponent(markerFilename)
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Path of the log this launch is writing to. nil before install.
    static var currentLogURLForDisplay: URL? { currentLogURL }

    // MARK: - Install steps

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true
        )
    }

    /// Look for the previous-launch marker BEFORE this launch opens a fresh
    /// log. If found, identify the prior log by mtime (newest .log present
    /// at this moment, which is necessarily from a prior launch).
    private static func detectPriorCrash() -> URL? {
        let markerURL = logDirectory.appendingPathComponent(markerFilename)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return nil
        }
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let newest = logs
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
            .first
        return newest
    }

    /// Keep at most `maxRetainedLogs` historical logs. Skipped silently on
    /// any I/O failure — never block app launch on housekeeping.
    private static func rotateOldLogs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = entries
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
        guard logs.count >= maxRetainedLogs else { return }
        for stale in logs.dropFirst(maxRetainedLogs - 1) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func openCurrentLog() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = logDirectory.appendingPathComponent("crow-\(stamp).log")
        currentLogURL = url

        let fd = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        guard fd >= 0 else { return }
        logFD = fd

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let header = """
        --- crow launch \(Date()) pid=\(ProcessInfo.processInfo.processIdentifier) version=\(version) ---

        """
        _ = header.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
    }

    /// Pre-allocate everything the signal handler will need so the handler
    /// itself only touches async-signal-safe primitives.
    private static func prepareSignalHandlerBuffers() {
        backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>
            .allocate(capacity: Int(backtraceCapacity))

        let markerPath = logDirectory.appendingPathComponent(markerFilename).path
        let bytes = Array(markerPath.utf8CString)
        let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        for (i, b) in bytes.enumerated() { ptr[i] = b }
        markerPathCString = ptr
    }

    private static func redirectStderr() {
        guard logFD >= 0 else { return }
        // dup2 returns the new fd or -1; we don't close logFD because we
        // still need it for direct writes from the signal handler.
        _ = dup2(logFD, STDERR_FILENO)
    }

    private static func installSignalHandlers() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = CrashReporter.signalHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        for sig in signals {
            sigaction(sig, &action, nil)
        }
    }

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            let message = "[CrowCrash] uncaught NSException name=\(exception.name.rawValue) " +
                "reason=\(exception.reason ?? "<nil>")\n\(symbols)\n"
            NSLog("%@", message)
            // Also write to the on-disk log + drop the marker so next launch
            // surfaces the crash artifact. stderr is already redirected to
            // logFD, so a plain fputs reaches the file.
            fputs(message, stderr)
            CrashReporter.writeMarkerFromHandlerSafeContext()
        }
    }

    // MARK: - Signal handler

    /// Async-signal-safe path. NO Swift allocations, NO ObjC, NO String
    /// formatting. Only `write(2)`, `open(2)`, `backtrace(3)`,
    /// `backtrace_symbols_fd(3)`, `sigaction(2)`, `raise(3)` per POSIX.
    private static let signalHandler: @convention(c) (Int32) -> Void = { signum in
        if logFD >= 0 {
            writeCString("\n--- crow crash signal=", to: logFD)
            writeInt32(signum, to: logFD)
            writeCString(" ---\n", to: logFD)
            if let buf = backtraceBuffer {
                let frames = backtrace(buf, backtraceCapacity)
                backtrace_symbols_fd(buf, frames, logFD)
            }
            writeCString("\n", to: logFD)
            fsync(logFD)
        }
        writeMarkerFromHandlerSafeContext()

        // Restore the default disposition and re-raise so the OS crash
        // reporter still gets a chance to write `.ips`. The re-raise
        // terminates the process.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(signum, &action, nil)
        raise(signum)
    }

    /// Touch the "crashed last launch" marker. Signal-safe: only `open` and
    /// `write` (one byte). Called from both the signal handler and the
    /// NSException handler.
    private static func writeMarkerFromHandlerSafeContext() {
        guard let path = markerPathCString else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        var byte: UInt8 = 0x31 // '1'
        _ = withUnsafePointer(to: &byte) { write(fd, $0, 1) }
        close(fd)
    }

    // MARK: - Signal-safe write helpers

    private static func writeCString(_ literal: StaticString, to fd: Int32) {
        // StaticString.utf8Start is a compile-time pointer — no allocation.
        _ = write(fd, literal.utf8Start, literal.utf8CodeUnitCount)
    }

    /// Write a signed Int32 in base 10 to fd. Stack-only buffer.
    private static func writeInt32(_ value: Int32, to fd: Int32) {
        var buffer = (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                      Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
        withUnsafeMutableBytes(of: &buffer) { raw in
            let chars = raw.bindMemory(to: Int8.self)
            var n = value
            var negative = false
            if n < 0 { negative = true; n = -n }
            var idx = chars.count - 1
            if n == 0 {
                chars[idx] = 0x30 // '0'
                idx -= 1
            } else {
                while n > 0 && idx >= 0 {
                    chars[idx] = Int8(0x30 + (n % 10))
                    n /= 10
                    idx -= 1
                }
            }
            if negative && idx >= 0 {
                chars[idx] = 0x2D // '-'
                idx -= 1
            }
            let start = idx + 1
            _ = write(fd, chars.baseAddress!.advanced(by: start), chars.count - start)
        }
    }
}
