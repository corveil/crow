import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix domain socket client for sending JSON-RPC 2.0 requests.
///
/// Creates a new connection per request, sends a newline-delimited JSON-RPC
/// message, and reads the response. Applies a 30-second read timeout and
/// a 1 MB response size limit matching the server's request limit.
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
        let fd = socket(AF_UNIX, crowSockStream, 0)
        guard fd >= 0 else {
            throw SocketError.createFailed(errno)
        }
        defer { close(fd) }

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

        // Set read timeout so a hung server doesn't block the CLI indefinitely
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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
                if written < 0 { return false }
                offset += written
                remaining -= written
            }
            return true
        }
        guard writeOK else { throw SocketError.writeFailed(errno) }

        // Read response until newline (with size limit and timeout awareness)
        var responseData = Data()
        var byte: UInt8 = 0
        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead < 0 {
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
}
