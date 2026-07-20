import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// "Is a `crowd` answering right now?" — a bare `connect()` to the Unix socket.
///
/// Deliberately not an RPC round trip: install/status need this on the cold
/// path (daemon possibly down, possibly mid-start), and a connect probe costs
/// nothing and needs no method to exist. It backs two things:
///   - `AutostartStatus.running`, so status can report enabled-vs-running
///     separately, and
///   - the install-time decision to *not* touch launchd while a daemon is
///     already up (`LaunchdAutostart.install`) — bootstrapping a second one
///     would trip `crowd`'s single-instance / store-writer locks.
public enum DaemonProbe {
    /// The well-known socket, matching `SocketServer.defaultSocketPath()` and
    /// the `CROW_SOCKET` override the CLI and hooks honor. Duplicated rather
    /// than imported so this package stays dependency-free (and so the probe
    /// never has the side effect of *creating* the socket directory).
    public static func defaultSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CROW_SOCKET"] {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow/crow.sock").path
    }

    /// True when something accepts a connection on `socketPath`.
    ///
    /// A stale socket file left by a killed daemon fails to connect
    /// (`ECONNREFUSED`), so this reports liveness, not file existence.
    public static func isRunning(socketPath: String? = nil) -> Bool {
        let path = socketPath ?? defaultSocketPath()
        guard FileManager.default.fileExists(atPath: path) else { return false }

        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return false }
        path.withCString { source in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strlcpy(destination, source, capacity)
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }
}
