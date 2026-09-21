#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CrowIPC
import Foundation

/// Single-instance socket lock (fail-open, per `--socket`) and store-writer lock
/// (fail-closed, per store directory). Extracted from `CrowDaemon` (CROW-1279).
/// FDs stay `nonisolated(unsafe)` so `reexec` can close them before `execv`.
extension CrowDaemon {
    /// Whether a live server is already accepting on the Unix socket at `path` —
    /// used to avoid stealing another process's socket. A stale socket file
    /// (nothing listening) returns false, so normal startup still replaces it.
    static func socketInUse(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, crowSockStream, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 104) { dest in strlcpy(dest, ptr, 104) }
            }
        }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// Held for the process lifetime once acquired — closing the fd drops the
    /// `flock`, so the OS reclaims the lock automatically on exit or crash.
    /// `nonisolated(unsafe)`: written once during single-threaded startup, then
    /// only kept alive; never mutated concurrently.
    nonisolated(unsafe) static var singleInstanceLockFD: Int32 = -1

    /// Enforce ONE `crowd` per socket path via an advisory `flock` on
    /// `<socketPath>.lock`. Without it a second daemon on the same socket sees the
    /// socket "in use", skips the unix bind, and runs degraded (HTTP-only) — then
    /// orphans `crow.sock` when the first exits (the multi-`daemon-run` footgun).
    /// Distinct `--socket` paths get distinct locks, so isolated daemons still
    /// coexist. Fails open on lock-file errors (never blocks a daemon over a weird
    /// lock dir). Returns false when another live crowd already holds this lock
    /// (CROW-581).
    static func acquireSingleInstanceLock(socketPath: String) -> Bool {
        let lockPath = socketPath + ".lock"
        let fd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else {
            log("WARNING: could not open lock file \(lockPath) (\(String(cString: strerror(errno)))); "
                + "continuing without the single-instance guard")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        singleInstanceLockFD = fd
        return true
    }

    /// Held for the process lifetime once acquired — closing the fd drops the
    /// `flock`. Separate from `singleInstanceLockFD` because it guards a
    /// different resource: the STORE, not the socket. `nonisolated(unsafe)`:
    /// written once during single-threaded startup, then only kept alive.
    nonisolated(unsafe) static var storeWriterLockFD: Int32 = -1

    /// Enforce ONE writer of `store.json` regardless of `--socket`, via an
    /// advisory `flock` on `<storeDirectory>/store.json.writer.lock`.
    ///
    /// The socket lock (`acquireSingleInstanceLock`) is keyed to the socket
    /// path, but `store.json` lives at a fixed app-support location no matter
    /// which `--socket` a daemon uses — so two daemons on different sockets both
    /// pass the socket guard and then race the same file. Because
    /// `JSONStore.mutate` rewrites the entire `StoreData`, a stale full-file
    /// write silently clobbers every session the other writer knew about
    /// ("all my sessions disappeared" — #759). This store-scoped lock closes
    /// that gap.
    ///
    /// Unlike the socket lock, this one **fails CLOSED**: if the lock file can't
    /// even be opened we refuse to run rather than write unguarded, because the
    /// blast radius of a lost race is the user's entire session history.
    /// Returns false when another live crowd already holds the store lock.
    static func acquireStoreWriterLock(storeDirectory: URL) -> Bool {
        // `open(O_CREAT)` needs the parent dir; on a fresh install it doesn't
        // exist yet (JSONStore.init creates it, but we lock BEFORE constructing
        // the store). Create it here so a first-run daemon locks cleanly instead
        // of failing closed on ENOENT.
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let lockPath = storeDirectory.appendingPathComponent("store.json.writer.lock").path
        let fd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else {
            log("FATAL: could not open store writer lock \(lockPath) "
                + "(\(String(cString: strerror(errno)))); refusing to start (fail closed) rather "
                + "than write store.json unguarded and risk clobbering another writer's sessions.")
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        storeWriterLockFD = fd
        return true
    }
}
