import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix domain socket server that accepts JSON-RPC 2.0 connections.
///
/// Listens on a newline-delimited JSON-RPC 2.0 protocol over a Unix domain
/// socket at `~/.local/share/crow/crow.sock`. Each client connection sends
/// one request and receives one response. The socket file is restricted to
/// owner-only access (0o600) within an owner-only directory (0o700).
///
/// Threading model: an accept loop runs on a dedicated GCD queue. Each
/// accepted connection is dispatched to the global concurrent queue where
/// it blocks until the async handler completes via a semaphore bridge.
public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private let router: CommandRouter
    private var serverFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.radiusmethod.crow.socket", qos: .userInitiated)

    /// Maximum size of a single JSON-RPC message (1 MB).
    static let maxMessageSize = 1_048_576

    public init(socketPath: String? = nil, router: CommandRouter) {
        self.socketPath = socketPath ?? Self.defaultSocketPath()
        self.router = router
    }

    public var path: String { socketPath }

    /// Well-known socket path shared by server and client.
    /// Uses ~/.local/share/crow/crow.sock instead of $TMPDIR
    /// because $TMPDIR varies across processes (app, CLI, Claude Code hooks).
    public static func defaultSocketPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Restrict directory to owner-only access
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        return (dir as NSString).appendingPathComponent("crow.sock")
    }

    // MARK: - Start / Stop

    public func start() throws {
        // Writing to a socket whose peer has closed raises SIGPIPE, which by
        // default terminates the process on Linux. Ignore it so write() returns
        // EPIPE instead. Idempotent and harmless on Darwin.
        _ = signal(SIGPIPE, SIG_IGN)

        // Remove stale socket
        unlink(socketPath)

        // Create socket
        serverFD = socket(AF_UNIX, crowSockStream, 0)
        guard serverFD >= 0 else {
            throw SocketError.createFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strlcpy(dest, ptr, 104)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFD)
            throw SocketError.bindFailed(errno)
        }

        // Restrict socket to owner-only access
        chmod(socketPath, 0o600)

        // Listen
        guard listen(serverFD, 5) == 0 else {
            close(serverFD)
            throw SocketError.listenFailed(errno)
        }

        running = true

        // Accept loop on background queue
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        running = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        // Don't unlink here — a newer instance may have already bound
        // to the same path. Cleanup is handled by start() which unlinks
        // before binding.
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while running {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                if running { continue }
                return
            }

            // Handle each client connection on a separate queue
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        // Read until newline (with size limit to prevent memory exhaustion)
        var buffer = Data()
        var byte: UInt8 = 0

        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead <= 0 { return }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
            if buffer.count >= Self.maxMessageSize {
                let errorResponse = JSONRPCResponse.error(id: 0, code: RPCErrorCode.parseError, message: "Message too large")
                writeResponse(errorResponse, to: fd)
                return
            }
        }

        guard !buffer.isEmpty else { return }

        // Parse JSON-RPC request
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(JSONRPCRequest.self, from: buffer) else {
            let errorResponse = JSONRPCResponse.error(id: 0, code: RPCErrorCode.parseError, message: "Invalid JSON")
            writeResponse(errorResponse, to: fd)
            return
        }

        // Bridge from sync socket I/O to async handler. Blocks one GCD thread
        // per active connection — acceptable since Crow processes one CLI
        // request at a time. A full async I/O rewrite would avoid the blocked
        // thread but is out of scope for the current architecture.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let capturedRouter = router
        let capturedRequest = request

        Task {
            box.value = await capturedRouter.handle(request: capturedRequest)
            semaphore.signal()
        }

        semaphore.wait()

        if let response = box.value {
            writeResponse(response, to: fd)
        }
    }

    private func writeResponse(_ response: JSONRPCResponse, to fd: Int32) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { rawBuffer in
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, rawBuffer.baseAddress! + offset, remaining)
                if written < 0 { return }  // client disconnected
                offset += written
                remaining -= written
            }
        }
    }
}

/// Single-slot carrier used to hand the async handler's result back across the
/// semaphore barrier in `handleClient`. Written once inside the `Task` before
/// `signal()`, read once after `wait()`; the semaphore provides the happens-before
/// ordering, so unsynchronized access is safe. Marked `@unchecked Sendable` so the
/// `Task` closure that captures it stays Sendable under Swift 6.2 strict concurrency.
private final class ResponseBox: @unchecked Sendable {
    var value: JSONRPCResponse?
}

public enum SocketError: Error, LocalizedError {
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectionFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case timeout
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .createFailed(let e): "Socket create failed: \(String(cString: strerror(e)))"
        case .bindFailed(let e): "Socket bind failed: \(String(cString: strerror(e)))"
        case .listenFailed(let e): "Socket listen failed: \(String(cString: strerror(e)))"
        case .connectionFailed(let e): "Socket connection failed: \(String(cString: strerror(e)))"
        case .writeFailed(let e): "Socket write failed: \(String(cString: strerror(e)))"
        case .readFailed(let e): "Socket read failed: \(String(cString: strerror(e)))"
        case .timeout: "Socket read timed out"
        case .responseTooLarge: "Response exceeded maximum size"
        }
    }
}
