import Darwin
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

    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public init() {}

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
        envStrings.append("TERM=xterm-256color")
        envStrings.append("COLORTERM=truecolor")
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
        guard masterFD >= 0 else { return }
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &win)
    }

    public func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(masterFD, base, buffer.count)
        }
    }

    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    public func terminate() {
        readSource?.cancel()
        readSource = nil
        if childPID > 0 {
            kill(childPID, SIGTERM)
            childPID = -1
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(self.masterFD, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                let handler = self.onOutput
                DispatchQueue.main.async {
                    handler?(data)
                }
            } else if count == 0 {
                source.cancel()
                self.waitForExit()
            }
        }
        source.resume()
        readSource = source
    }

    private func waitForExit() {
        let pid = childPID
        guard pid > 0 else { return }
        readQueue.async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = (status >> 8) & 0xFF
            let handler = self?.onExit
            DispatchQueue.main.async {
                handler?(Int32(code))
            }
        }
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
