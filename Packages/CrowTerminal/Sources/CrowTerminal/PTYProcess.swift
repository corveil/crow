#if canImport(Glibc)
import Glibc
import CPty  // exposes openpty(3) from <pty.h>; libc's Glibc module doesn't
#else
import Darwin
#endif
import Foundation

enum PTYProcessError: Error {
    case openptyFailed
    case spawnFailed(Int32)
}

/// Minimal pseudo-terminal wrapper for running a shell command and streaming I/O.
public final class PTYProcess: @unchecked Sendable {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "com.radiusmethod.crow.pty-read", qos: .userInteractive)
    /// When true (default), `onOutput`/`onExit` fire on `DispatchQueue.main` —
    /// what the AppKit surface needs. The headless `crowd` daemon has no main
    /// run loop pumping that queue, so it constructs with `false` to receive
    /// callbacks synchronously on `readQueue` and bridge them into its async
    /// WebSocket loop (CROW-581).
    private let deliverOnMain: Bool

    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public init(deliverOnMainQueue: Bool = true) {
        self.deliverOnMain = deliverOnMainQueue
    }

    deinit {
        readSource?.cancel()
        readSource = nil
        // Do NOT hop onto `readQueue` here. `deinit` can run *on* `readQueue`
        // when the last strong reference is released by a `readQueue.async`
        // block (write/resize/terminate all capture `self`), and
        // `dispatch_sync` onto the current queue traps — the daemon's
        // short-lived PTYs hit this on disconnect. By `deinit` no other
        // references or queued self-capturing blocks remain, so this state is
        // ours to tear down directly without serialization.
        if childPID > 0 {
            let pid = childPID
            childPID = -1
            kill(pid, SIGTERM)
            Self.forceReap(pid)
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    public func start(command: String, workingDirectory: String?) throws {
        guard masterFD < 0 else { return }

        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PTYProcessError.openptyFailed
        }
        masterFD = master

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(master)
            close(slave)
            masterFD = -1
            throw PTYProcessError.spawnFailed(errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        if slave > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, slave)
        }
        if let wd = workingDirectory {
            _ = wd.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        }

        var attrs: posix_spawnattr_t?
        guard posix_spawnattr_init(&attrs) == 0 else {
            close(master)
            close(slave)
            masterFD = -1
            throw PTYProcessError.spawnFailed(errno)
        }
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))

        var envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        if !envStrings.contains(where: { $0.hasPrefix("TERM=") }) {
            // xterm-256color is present on stock macOS; xterm-kitty terminfo is not.
            envStrings.append("TERM=xterm-256color")
        }
        if !envStrings.contains(where: { $0.hasPrefix("COLORTERM=") }) {
            envStrings.append("COLORTERM=truecolor")
        }
        if !envStrings.contains(where: { $0.hasPrefix("LANG=") }) {
            envStrings.append("LANG=en_US.UTF-8")
        }
        if !envStrings.contains(where: { $0.hasPrefix("LC_CTYPE=") }) {
            envStrings.append("LC_CTYPE=en_US.UTF-8")
        }

        let argv = ["/bin/bash", "-c", command]
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeMutablePointers { argvPtr in
            envStrings.withUnsafeMutablePointers { envPtr in
                posix_spawn(&pid, "/bin/bash", &actions, &attrs, argvPtr, envPtr)
            }
        }

        close(slave)

        if spawnResult != 0 {
            close(master)
            masterFD = -1
            throw PTYProcessError.spawnFailed(spawnResult)
        }

        childPID = pid
        startReading()
    }

    public func resize(rows: UInt16, cols: UInt16) {
        readQueue.async { [rows, cols] in
            guard self.masterFD >= 0 else { return }
            var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            #if canImport(Glibc)
            // glibc imports the ioctl request as an unsigned long.
            _ = ioctl(self.masterFD, UInt(TIOCSWINSZ), &win)
            #else
            _ = ioctl(self.masterFD, TIOCSWINSZ, &win)
            #endif
        }
    }

    public func write(_ data: Data) {
        readQueue.async {
            guard self.masterFD >= 0 else { return }
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                #if canImport(Glibc)
                _ = Glibc.write(self.masterFD, base, buffer.count)
                #else
                _ = Darwin.write(self.masterFD, base, buffer.count)
                #endif
            }
        }
    }

    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    public func terminate() {
        readQueue.async {
            let pid = self.childPID
            if pid > 0 {
                self.childPID = -1
                kill(pid, SIGTERM)
                Self.forceReap(pid)
            }

            if let source = self.readSource {
                self.readSource = nil
                source.cancel()
            }
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.masterFD >= 0 {
                close(self.masterFD)
                self.masterFD = -1
            }
        }
        source.setEventHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            #if canImport(Glibc)
            let count = Glibc.read(self.masterFD, &buffer, buffer.count)
            #else
            let count = Darwin.read(self.masterFD, &buffer, buffer.count)
            #endif
            if count > 0 {
                let data = Data(buffer.prefix(count))
                let handler = self.onOutput
                if self.deliverOnMain {
                    DispatchQueue.main.async { handler?(data) }
                } else {
                    handler?(data)
                }
            } else if count == 0 {
                source.cancel()
                self.reapChild(notifyExit: true)
            } else {
                let err = errno
                if err == EINTR || err == EAGAIN {
                    return
                }
                source.cancel()
                self.reapChild(notifyExit: true)
            }
        }
        source.resume()
        readSource = source
    }

    private func reapChild(notifyExit: Bool) {
        let pid = childPID
        guard pid > 0 else { return }
        childPID = -1
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard notifyExit else { return }
        let code = Self.decodeExitStatus(status)
        let handler = onExit
        if deliverOnMain {
            DispatchQueue.main.async { handler?(code) }
        } else {
            handler?(code)
        }
    }

    /// Reap a child after SIGTERM without blocking the read queue indefinitely.
    private static func forceReap(_ pid: pid_t) {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return }
        for _ in 0..<10 {
            usleep(50_000)
            if waitpid(pid, &status, WNOHANG) == pid { return }
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
    }

    private static func decodeExitStatus(_ status: Int32) -> Int32 {
        // Decode wait(2) status without WEXITSTATUS/WTERMSIG macros (unsupported in Swift).
        let lowByte = status & 0xFF
        if lowByte == 0 {
            return (status >> 8) & 0xFF
        }
        if lowByte != 0x7F {
            return 128 + (status & 0x7F)
        }
        return status
    }
}

private extension Array where Element == String {
    func withUnsafeMutablePointers<R>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> R
    ) -> R {
        let cStrings = map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings.map { UnsafeMutablePointer($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}
