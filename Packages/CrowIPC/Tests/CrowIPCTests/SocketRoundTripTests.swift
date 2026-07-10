import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import CrowIPC

// MARK: - Helpers

/// Create a unique socket path in a temp directory for each test.
private func tempSocketPath() -> String {
    let dir = NSTemporaryDirectory()
    return (dir as NSString).appendingPathComponent("crow-test-\(UUID().uuidString).sock")
}

/// Thread-safe counter for use in @Sendable closures.
private actor Counter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

/// Start a server with the given handlers at the given socket path.
/// Returns the server (caller must stop it).
private func startServer(
    path: String,
    handlers: [String: CommandRouter.Handler]
) throws -> SocketServer {
    let router = CommandRouter(handlers: handlers)
    let server = SocketServer(socketPath: path, router: router)
    try server.start()
    // Give the accept loop a moment to start
    Thread.sleep(forTimeInterval: 0.05)
    return server
}

// MARK: - Round-Trip Tests

@Test func basicRoundTrip() throws {
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [
        "echo": { @Sendable params in params },
    ])
    defer { server.stop(); unlink(path) }

    let client = SocketClient(socketPath: path)
    let response = try client.send(method: "echo", params: ["msg": .string("hello")])
    #expect(response.result?["msg"] == .string("hello"))
    #expect(response.error == nil)
}

@Test func largeResponseSucceeds() throws {
    let path = tempSocketPath()
    // Generate a string just under 1MB (leave room for JSON framing)
    let largeString = String(repeating: "x", count: 900_000)
    let server = try startServer(path: path, handlers: [
        "large": { @Sendable _ in ["data": .string(largeString)] },
    ])
    defer { server.stop(); unlink(path) }

    let client = SocketClient(socketPath: path)
    let response = try client.send(method: "large")
    #expect(response.result?["data"]?.stringValue?.count == 900_000)
}

@Test func oversizedRequestReturnsSizeError() throws {
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [
        "echo": { @Sendable params in params },
    ])
    defer { server.stop(); unlink(path) }

    // Build a request with payload > 1MB
    let bigValue = String(repeating: "A", count: SocketServer.maxMessageSize + 100)
    let client = SocketClient(socketPath: path)
    let response = try client.send(method: "echo", params: ["big": .string(bigValue)])
    // Server should return a parse error (message too large)
    #expect(response.error?.code == RPCErrorCode.parseError)
}

@Test func invalidJSONReturnsParseError() throws {
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [:])
    defer { server.stop(); unlink(path) }

    // Connect manually and send garbage
    let fd = socket(AF_UNIX, crowSockStream, 0)
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = strlcpy(dest, ptr, 104)
            }
        }
    }
    _ = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    // Send invalid JSON
    let garbage = "not json at all\n".data(using: .utf8)!
    garbage.withUnsafeBytes { ptr in
        _ = write(fd, ptr.baseAddress!, ptr.count)
    }

    // Set a read timeout so we don't hang
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    // Read response
    var responseData = Data()
    var byte: UInt8 = 0
    while true {
        let bytesRead = read(fd, &byte, 1)
        if bytesRead <= 0 { break }
        if byte == UInt8(ascii: "\n") { break }
        responseData.append(byte)
    }

    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
    #expect(response.error?.code == RPCErrorCode.parseError)
}

@Test func multipleSequentialConnections() throws {
    let path = tempSocketPath()
    let counter = Counter()
    let server = try startServer(path: path, handlers: [
        "count": { @Sendable _ in
            let n = await counter.increment()
            return ["n": .int(n)]
        },
    ])
    defer { server.stop(); unlink(path) }

    let client = SocketClient(socketPath: path)
    for i in 1...5 {
        let response = try client.send(method: "count")
        #expect(response.result?["n"] == .int(i))
    }
}

@Test func unknownMethodReturnsError() throws {
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [:])
    defer { server.stop(); unlink(path) }

    let client = SocketClient(socketPath: path)
    let response = try client.send(method: "does-not-exist")
    #expect(response.error?.code == RPCErrorCode.methodNotFound)
}

@Test func socketFilePermissions() throws {
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [:])
    defer { server.stop(); unlink(path) }

    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let perms = attrs[.posixPermissions] as? Int
    // 0o600 == 384 in decimal (owner read+write only)
    #expect(perms == 0o600)
}

@Test func clientTimeoutOnSlowHandler() throws {
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [
        "slow": { @Sendable _ in
            // Sleep longer than the client timeout — but use a modest
            // duration since the test itself must complete.
            try await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            return [:]
        },
    ])
    defer { server.stop(); unlink(path) }

    // Use a custom client with a very short timeout for testing.
    // We can't easily override the timeout constant, so we'll test
    // the timeout mechanism by connecting manually with a 1s timeout.
    let fd = socket(AF_UNIX, crowSockStream, 0)
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { ptr in
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
    #expect(connectResult == 0)

    // Set a 1-second read timeout
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    // Send a valid request for the slow handler
    let request = JSONRPCRequest(id: 1, method: "slow")
    var data = try JSONEncoder().encode(request)
    data.append(UInt8(ascii: "\n"))
    data.withUnsafeBytes { ptr in
        _ = write(fd, ptr.baseAddress!, ptr.count)
    }

    // Read should timeout
    var byte: UInt8 = 0
    let bytesRead = read(fd, &byte, 1)
    #expect(bytesRead < 0)
    #expect(errno == EAGAIN || errno == EWOULDBLOCK)
}

@Test func connectionToNonexistentSocketFails() {
    let client = SocketClient(socketPath: "/tmp/nonexistent-crow-test.sock")
    #expect(throws: SocketError.self) {
        _ = try client.send(method: "test")
    }
}

@Test func nestedObjectParamsSurviveRoundTrip() throws {
    // The `job-add`/`job-edit` RPCs send the schedule as a nested JSON object
    // and prompts as an array (CROW-604) — assert compound JSONValue params
    // survive client → server → handler → response intact.
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [
        "job-add": { @Sendable params in
            ["schedule": params["schedule"] ?? .null, "prompts": params["prompts"] ?? .null]
        },
    ])
    defer { server.stop(); unlink(path) }

    let schedule = JSONValue.object([
        "type": .string("dailyAt"),
        "hour": .int(9),
        "minute": .int(30),
        "weekdays": .array([.int(2), .int(6)]),
    ])
    let prompts = JSONValue.array([.string("first"), .string("second")])
    let client = SocketClient(socketPath: path)
    let response = try client.send(method: "job-add", params: ["schedule": schedule, "prompts": prompts])
    #expect(response.error == nil)
    #expect(response.result?["schedule"] == schedule)
    #expect(response.result?["prompts"] == prompts)
}

@Test func clientAcceptsPerCallTimeout() throws {
    // `job run` passes a longer read timeout; a short one must still time out.
    let path = tempSocketPath()
    let server = try startServer(path: path, handlers: [
        "slow": { @Sendable _ in
            try await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            return [:]
        },
    ])
    defer { server.stop(); unlink(path) }

    let client = SocketClient(socketPath: path)
    #expect(throws: SocketError.self) {
        _ = try client.send(method: "slow", timeoutSeconds: 1)
    }
}
