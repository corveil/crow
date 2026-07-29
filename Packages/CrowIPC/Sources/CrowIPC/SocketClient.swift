import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix domain socket client for sending JSON-RPC 2.0 requests.
///
/// Creates a new connection per request and sends a newline-delimited JSON-RPC
/// message. `send` then reads the response (30-second read timeout, 1 MB size
/// limit matching the server's request limit); `post` returns without reading,
/// for fire-and-forget notifications that must not block the caller on a reply
/// (#903).
public struct SocketClient: Sendable {
    private let socketPath: String

    /// Default read timeout in seconds applied via `SO_RCVTIMEO`.
    public static let readTimeoutSeconds: Int = 30

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? {
            // CROW_SOCKET overrides for hook subprocesses (legacy support)
            if let override = ProcessInfo.processInfo.environment["CROW_SOCKET"] {
                return override
            }
            return SocketServer.defaultSocketPath()
        }()
    }

    /// Send a JSON-RPC request and return the response.
    ///
    /// - Parameter timeoutSeconds: Read timeout; defaults to 30. Slow methods
    ///   (e.g. `job-run`, which may clone a repo) pass a larger value.
    /// - Throws: `SocketError.timeout` if the server doesn't respond within the timeout.
    /// - Throws: `SocketError.responseTooLarge` if the response exceeds 1 MB.
    /// - Throws: `SocketError.writeFailed` if sending the request fails.
    public func send(
        method: String,
        params: [String: JSONValue] = [:],
        timeoutSeconds: Int = SocketClient.readTimeoutSeconds
    ) throws -> JSONRPCResponse {
        let fd = try connectAndWrite(method: method, params: params)
        defer { close(fd) }

        // Set read timeout so a hung server doesn't block the CLI indefinitely
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read response until newline (with size limit and timeout awareness)
        var responseData = Data()
        var byte: UInt8 = 0
        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead < 0 {
                if errno == EINTR { continue }  // interrupted by signal; retry
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketError.timeout
                }
                throw SocketError.readFailed(errno)
            }
            if bytesRead == 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            responseData.append(byte)
            if responseData.count >= SocketServer.maxMessageSize {
                throw SocketError.responseTooLarge
            }
        }

        let decoder = JSONDecoder()
        return try decoder.decode(JSONRPCResponse.self, from: responseData)
    }

    /// Fire-and-forget a JSON-RPC request: connect, write, and return without
    /// reading (or waiting for) a response.
    ///
    /// Used by hooks (`crow hook-event`), which are notifications the agent must
    /// not block on the daemon's reply for. The daemon still processes the
    /// request once its serialized `@MainActor` frees; because the client never
    /// reads a reply, a busy daemon (board poll, git op, whole-store write, a
    /// burst of hook-events) can no longer stall the agent waiting for a reply
    /// the fire-and-forget path discards (#903).
    ///
    /// This bounds the wait to the `write()`, not a full round-trip. For the
    /// measured `PreToolUse:Bash` payloads that returns immediately, but no send
    /// timeout is set (only `SO_RCVTIMEO`), so a payload larger than the socket
    /// send buffer — e.g. a `Write`/`Edit` hook forwarding a whole file body —
    /// can still block in `write()` until the daemon drains it. The agent's own
    /// hook timeout bounds that worst case.
    ///
    /// The connection is closed as soon as the request is written. Data already
    /// accepted into a Unix stream socket's buffer is delivered to the peer
    /// before the FIN, so the server still receives the full request; if it
    /// later replies to the now-closed connection, its `SIGPIPE`-ignoring write
    /// path drops the response harmlessly.
    ///
    /// - Throws: `SocketError.connectionFailed` when the daemon isn't running
    ///   (callers treat this as an expected no-op); other socket errors
    ///   (`createFailed`, `writeFailed`) still propagate.
    public func post(method: String, params: [String: JSONValue] = [:]) throws {
        let fd = try connectAndWrite(method: method, params: params)
        close(fd)
    }

    /// Open a connection and write the encoded JSON-RPC request, returning the
    /// connected file descriptor. The caller owns the fd and must `close` it.
    ///
    /// Shared by `send` (which then reads a response) and `post` (fire-and-forget,
    /// which closes immediately). On any failure after the socket is created the
    /// fd is closed before throwing, so callers never leak a descriptor.
    private func connectAndWrite(method: String, params: [String: JSONValue]) throws -> Int32 {
        // Ignore SIGPIPE so a write to a peer-closed socket returns EPIPE
        // rather than killing the process on Linux. See SocketServer.start().
        _ = signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_UNIX, crowSockStream, 0)
        guard fd >= 0 else {
            throw SocketError.createFailed(errno)
        }
        // Hand the fd back on success; close it on any throw below.
        var keepOpen = false
        defer { if !keepOpen { close(fd) } }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strlcpy(dest, ptr, 104)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketError.connectionFailed(errno)
        }

        // Send request
        let request = JSONRPCRequest(id: 1, method: method, params: params.isEmpty ? nil : params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(request)
        data.append(UInt8(ascii: "\n"))

        let writeOK = data.withUnsafeBytes { rawBuffer -> Bool in
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, rawBuffer.baseAddress! + offset, remaining)
                if written < 0 {
                    if errno == EINTR { continue }  // interrupted by signal; retry
                    return false
                }
                offset += written
                remaining -= written
            }
            return true
        }
        guard writeOK else { throw SocketError.writeFailed(errno) }

        keepOpen = true
        return fd
    }
}
