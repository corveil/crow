import Foundation
#if canImport(Darwin)
import Darwin
import os
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide log sink. **Never blocks the caller** (CROW-874).
///
/// The rule this type exists to enforce: `crowd` serves every CLI and web client
/// through RPC handlers that hop to the MainActor, so anything that blocks the
/// MainActor stalls the whole daemon rather than one request. `NSLog` does
/// exactly that — it funnels into CoreFoundation's `_logToStderr`, which calls
/// `writev(2)` on the controlling tty. When that tty's output queue is full and
/// nobody is draining it (Ctrl-S, a stopped terminal, an unread pane), `writev`
/// blocks in the kernel with no timeout. A `sample` of a wedged daemon caught
/// exactly this: one `NSLog` inside `MainActor.run` holding up every other
/// MainActor-bound RPC until the tty drained. `NSLog` is therefore banned
/// repo-wide outside this file — see `scripts/check-no-nslog.sh`.
///
/// How this stays non-blocking:
///
/// - **os_log mirror runs on the calling thread, before enqueue.** `Logger.log`
///   is a bounded `memcpy` into this process's trace buffer, which cannot block.
///   Doing it here rather than on the drain thread is the whole point: it is the
///   copy that survives a wedged stderr, a dropped line, and `execv`.
/// - **The backlog is bounded** (`backlogCapacity`). Past the cap lines are
///   dropped and counted, and the drain reports the gap when it next runs. A
///   wedged sink costs bounded memory and a hole in the log, never a hang.
/// - **A dedicated thread does the blocking write.** Not a serial
///   `DispatchQueue`: `DispatchQueue.async` already never blocks the caller, so
///   the actual job here is *bounding* the queue — and a dispatch queue's queue
///   cannot be bounded.
///
/// It also remains the durable automation-decision log from CROW-782:
/// `automation(_:)` additionally appends to
///
///     ~/Library/Logs/crow/crowd-automation.log
///
/// as `<ISO8601> [automation] <message>`, size-capped at `maxBytes` with exactly
/// one rotated generation (`…log.1`) and owner-only permissions. `info(_:)` and
/// `error(_:)` deliberately do **not** touch that file — it is a decision log,
/// and general traffic would evict the auto-merge trail it exists to preserve.
///
/// Under launchd, stdout and stderr are the same path
/// (`~/Library/Logs/crow/crowd.log`). launchd keeps that fd open for the process
/// lifetime, so a rename alone would leave subsequent writes on the old inode
/// (the file on disk looks rotated, then grows forever under a new name). The
/// drain thread therefore size-caps `crowd.log` with the same `maxBytes` /
/// one-generation / 0o600 policy and `dup2`s a freshly opened fd over stdout
/// and stderr so later writes follow. A tty (dev-mode
/// `scripts/daemon-run.sh`) is left alone — `fstat` sees a non-regular file.
///
/// Per ADR 0012 a test process never writes to the live log directory: the
/// destination is resolved on the *caller's* thread at enqueue (see `emit`), so
/// `configure(directory:)` is a strict happens-before for every later line.
public enum CrowLog {
    /// Rotate `crowd.log` and `crowd-automation.log` once either exceeds this
    /// size (bytes). One policy, two files — never mix their traffic.
    static let maxBytes: Int = 5 * 1024 * 1024

    /// Maximum lines held while the sink is blocked. Past this, lines are
    /// dropped and counted. `var` only so tests can shrink it; production
    /// never assigns it.
    nonisolated(unsafe) static var backlogCapacity: Int = 4096

    // MARK: - State
    //
    // Two locks, and they are NEVER nested. `cond` guards the queue and is held
    // only for a handful of array operations — never across a write. `dirLock`
    // guards `overrideDirectory` alone, and `automation(_:)` takes and releases
    // it *before* it touches `cond`. That ordering is the safety argument: the
    // drain thread cannot be holding a lock that a logging caller needs, so a
    // blocked write can never back-pressure into the caller.

    private static let cond = NSCondition()
    /// `nonisolated(unsafe)`: only ever touched while holding `cond`.
    private nonisolated(unsafe) static var pending: [Record] = []
    private nonisolated(unsafe) static var dropped: Int = 0
    /// Monotonic drop total, never reset. Exists so tests can assert the
    /// overflow path was taken; `dropped` above is cleared by each drain.
    private nonisolated(unsafe) static var droppedTotal: Int = 0
    /// Highest sequence actually appended to `pending`. Dropped lines never get
    /// one — that is what keeps `flush` from waiting on a line that will never
    /// be written.
    private nonisolated(unsafe) static var enqueuedSeq: UInt64 = 0
    /// Highest sequence the drain has finished writing.
    private nonisolated(unsafe) static var retiredSeq: UInt64 = 0
    private nonisolated(unsafe) static var workerStarted = false

    private static let dirLock = NSLock()
    /// `nonisolated(unsafe)`: only ever touched while holding `dirLock`.
    private nonisolated(unsafe) static var overrideDirectory: URL?

    #if canImport(Darwin)
    /// `com.corveil.crowd` matches the launchd label, so `log stream
    /// --predicate 'subsystem == "com.corveil.crowd"'` picks up the daemon.
    private static let osLogger = Logger(subsystem: "com.corveil.crowd", category: "crow")
    #endif

    private struct Record {
        let seq: UInt64
        /// Captured at enqueue, formatted on the drain. Formatting at drain time
        /// would stamp every line buffered during a wedge with the *resume*
        /// time — destroying the one thing you need to reconstruct the hang.
        let date: Date
        let message: String
        /// Resolved on the caller's thread at enqueue (ADR 0012). `nil` means
        /// stderr + os_log only.
        let fileDirectory: URL?
    }

    private enum Level { case info, error }

    // MARK: - Public API

    /// Log one line to stderr and the unified log. Never blocks.
    public static func info(_ message: String) {
        emit(message, level: .info, fileDirectory: nil)
    }

    /// As `info(_:)`, but recorded at error level in the unified log so
    /// `log show --predicate 'messageType == error'` can isolate it.
    public static func error(_ message: String) {
        emit(message, level: .error, fileDirectory: nil)
    }

    /// Record a background-automation decision (CROW-782). Same non-blocking
    /// path as `info(_:)`, plus an append to `crowd-automation.log`.
    public static func automation(_ message: String) {
        // Resolve the destination HERE, on the caller, so a later
        // `configure(directory:)` cannot retarget a line that is already queued.
        dirLock.lock()
        let dir = resolvedDirectoryLocked()
        dirLock.unlock()
        emit("[automation] \(message)", level: .info, fileDirectory: dir)
    }

    /// Block until every line queued at the time of the call has been written,
    /// or `timeout` elapses. Returns `false` on timeout.
    ///
    /// This is a barrier, **not** a delivery guarantee: a sink that is wedged
    /// stays wedged, and this returns `false` with those lines still unwritten.
    /// They are not lost — the os_log copy was made on the calling thread before
    /// the line was ever queued, which is precisely why that mirror is on the
    /// producer side.
    ///
    /// Call before `exit()` / `execv()`, and from tests that assert on file
    /// contents. Must not be called from the drain thread.
    @discardableResult
    public static func flush(timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        // Waits on `enqueuedSeq`, not `pending` — a batch the drain has already
        // taken is no longer in `pending` but is not yet written.
        while retiredSeq < enqueuedSeq {
            if !cond.wait(until: deadline) { return false }
        }
        return true
    }

    /// Point the automation file at a different directory. Tests use this to
    /// write into a temp dir; production leaves it alone.
    public static func configure(directory: URL?) {
        dirLock.lock()
        overrideDirectory = directory
        dirLock.unlock()
    }

    /// Directory holding the automation log. `~/Library/Logs/crow` in
    /// production; a temp directory under a test runner (ADR 0012).
    public static var directory: URL {
        dirLock.lock()
        defer { dirLock.unlock() }
        return resolvedDirectoryLocked()
    }

    /// Full path of the active automation log file.
    public static var fileURL: URL { directory.appendingPathComponent("crowd-automation.log") }

    // MARK: - Producer

    private static func emit(_ message: String, level: Level, fileDirectory: URL?) {
        #if canImport(Darwin)
        // On the CALLER, before enqueue — see the type doc. `privacy: .public`
        // is mandatory, not decorative: `Logger` renders dynamic (non-literal)
        // interpolations as `<private>` to other processes, and every message
        // here is a runtime String. Without it every line reads `<private>`.
        switch level {
        case .info: osLogger.log("\(message, privacy: .public)")
        case .error: osLogger.error("\(message, privacy: .public)")
        }
        #endif

        let now = Date()
        cond.lock()
        startWorkerIfNeededLocked()
        if pending.count < backlogCapacity {
            enqueuedSeq &+= 1
            pending.append(Record(seq: enqueuedSeq, date: now, message: message,
                                  fileDirectory: fileDirectory))
            cond.signal()
        } else {
            dropped &+= 1
            droppedTotal &+= 1
        }
        cond.unlock()
    }

    /// Total lines dropped to backlog overflow since process start. Test seam.
    static var droppedLineCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return droppedTotal
    }

    private static func startWorkerIfNeededLocked() {
        guard !workerStarted else { return }
        workerStarted = true
        let thread = Thread { drainLoop() }
        thread.name = "com.corveil.crow.log"
        thread.qualityOfService = .utility
        thread.stackSize = 512 * 1024
        thread.start()
    }

    // MARK: - Drain (one dedicated thread; holds no lock during I/O)

    private static func drainLoop() {
        // Thread-confined: ISO8601DateFormatter is not thread-safe, and this is
        // now its only user.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tag = "\(ProcessInfo.processInfo.processName)[\(getpid())]"

        while true {
            cond.lock()
            while pending.isEmpty { cond.wait() }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            let drops = dropped
            dropped = 0
            cond.unlock()

            var out = ""
            if drops > 0 {
                out += "\(iso.string(from: Date())) \(tag) [CrowLog] dropped \(drops) line(s) — sink was blocked\n"
            }
            for record in batch {
                let stamp = iso.string(from: record.date)
                out += "\(stamp) \(tag) \(record.message)\n"
                if let dir = record.fileDirectory {
                    appendToAutomationFile(directory: dir, line: "\(stamp) \(record.message)\n")
                }
            }
            // Rotate launchd's capture file *before* the blocking write so this
            // batch lands on the new inode. No lock is held across either call.
            rotateCaptureIfNeeded()
            writeAll(out, to: STDERR_FILENO)

            cond.lock()
            if let last = batch.last { retiredSeq = last.seq }
            cond.broadcast()
            cond.unlock()
        }
    }

    /// `write(2)` loop handling short writes, `EINTR`, and a non-blocking fd.
    ///
    /// Deliberately not `FileHandle.standardError.write(_:)`: that raises an
    /// uncatchable Objective-C exception on `EPIPE`/`EBADF`, so a closed stderr
    /// would take the daemon down instead of dropping a log line.
    private static func writeAll(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let written = write(fd, base + offset, buf.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        // Someone set O_NONBLOCK on our stderr. Park rather than
                        // spin; this thread blocking is the design.
                        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&poller, 1, 100)
                        continue
                    }
                }
                return  // EPIPE / EBADF / closed — drop the rest rather than spin.
            }
        }
    }

    // MARK: - Automation file (drain thread is the sole writer)

    private static func appendToAutomationFile(directory dir: URL, line: String) {
        let url = dir.appendingPathComponent("crowd-automation.log")
        let fm = FileManager.default
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        rotateIfNeeded(url: url)

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write, or the file was rotated/removed under us — create it.
            try? data.write(to: url, options: .atomic)
        }
        // The log carries session UUIDs, PR URLs and raw `gh` error text, so it
        // gets the same owner-only treatment as Crow's other durable local state
        // (JSONStore / ConfigStore, 0o700 dirs + 0o600 files). Re-applied after
        // every write: an atomic write replaces the inode, so permissions set on
        // a previous generation don't carry over (review #787).
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Rename `url` to `url.1` once it exceeds `maxBytes`. Returns whether the
    /// rename happened, so the capture-fd path can `dup2` a new open only then.
    @discardableResult
    private static func rotateIfNeeded(url: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return false }
        let rotated = url.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        do {
            try fm.moveItem(at: url, to: rotated)
        } catch {
            return false
        }
        // The rotated generation holds the same data as the active file, so it
        // keeps the same owner-only permissions (a move preserves them, but the
        // active file may predate this hardening).
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotated.path)
        return true
    }

    // MARK: - launchd capture file (drain thread; CROW-1197)

    /// Size-cap the file behind stderr when it is launchd's `crowd.log`, and
    /// retarget stdout/stderr onto a new open so writes follow the rename.
    ///
    /// Default fds are the process stdio; tests pass dedicated fds opened on a
    /// temp `crowd.log` so this never has to steal the test runner's stderr.
    static func rotateCaptureIfNeeded(
        stderrFD: Int32 = STDERR_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO
    ) {
        var st = stat()
        guard fstat(stderrFD, &st) == 0 else { return }
        // A tty / pipe / socket is the inner-loop case: leave it alone.
        guard (st.st_mode & S_IFMT) == S_IFREG else { return }
        guard let path = filePath(of: stderrFD) else { return }
        guard URL(fileURLWithPath: path).lastPathComponent == "crowd.log" else { return }

        // launchd creates this 0644 via umask. Re-applied every drain so a
        // rotated-and-reopened inode cannot drift, matching the automation file.
        _ = fchmod(stderrFD, 0o600)

        guard st.st_size > off_t(maxBytes) else { return }

        var outStat = stat()
        let retargetStdout = fstat(stdoutFD, &outStat) == 0
            && (outStat.st_mode & S_IFMT) == S_IFREG
            && outStat.st_dev == st.st_dev
            && outStat.st_ino == st.st_ino

        let url = URL(fileURLWithPath: path)
        guard rotateIfNeeded(url: url) else { return }
        reopenStdio(onto: path, stderrFD: stderrFD, stdoutFD: stdoutFD, retargetStdout: retargetStdout)
    }

    /// `dup2` a newly created `crowd.log` over the capture fds. `O_APPEND` is
    /// mandatory: launchd may have given stdout and stderr separate opens of the
    /// same path, and independent offsets would clobber each other.
    private static func reopenStdio(
        onto path: String,
        stderrFD: Int32,
        stdoutFD: Int32,
        retargetStdout: Bool
    ) {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        _ = dup2(fd, stderrFD)
        if retargetStdout {
            _ = dup2(fd, stdoutFD)
        }
    }

    /// Path of an open fd. Darwin's `F_GETPATH`; Linux `/proc/self/fd/N`.
    private static func filePath(of fd: Int32) -> String? {
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let rc = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return fcntl(fd, F_GETPATH, base)
        }
        guard rc == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #elseif canImport(Glibc)
        var buf = [CChar](repeating: 0, count: 4096)
        let n = "/proc/self/fd/\(fd)".withCString { cPath in
            buf.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return readlink(cPath, base, ptr.count - 1)
            }
        }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return nil
        #endif
    }

    // MARK: - Directory resolution (callers hold `dirLock`)

    private static func resolvedDirectoryLocked() -> URL {
        if let overrideDirectory { return overrideDirectory }
        if isRunningUnderTests() {
            // Never write into the developer's real log directory from a test
            // process (ADR 0012). Appending is not destructive the way a
            // full-store `mutate` is, but test noise in a diagnostic log is
            // exactly what makes the log untrustworthy later.
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("crow-test-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/crow", isDirectory: true)
    }

    /// Mirrors `JSONStore.isRunningUnderTests()` — see ADR 0012 for why each
    /// signal is checked. Duplicated rather than shared because `CrowCore` sits
    /// below `CrowPersistence` in the package graph.
    private static func isRunningUnderTests() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        let arg0 = CommandLine.arguments.first
        let runnerNames: Set<String> = ["swiftpm-testing-helper", "xctest"]
        if let base = (arg0 as NSString?)?.lastPathComponent, runnerNames.contains(base) { return true }
        if runnerNames.contains(ProcessInfo.processInfo.processName) { return true }
        if arg0?.contains(".xctest") == true { return true }
        return false
    }
}
