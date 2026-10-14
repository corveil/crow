import Foundation
import Testing
@testable import CrowEngine
#if canImport(Darwin)
import Darwin
#endif

/// `runShellAsync` used to read the pipes only after the child exited, so a
/// child that wrote more than the pipe buffer never exited. It also inherited
/// crowd's TTY on stdin (CROW-1323).
@Suite struct RunShellTests {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @Test(.timeLimit(.minutes(1)))
    func largeStdoutReturnsInsteadOfHanging() async throws {
        let output = try await SessionService.runShellAsync(
            env: env,
            args: ["dd", "if=/dev/zero", "bs=1024", "count=1200"])
        #expect(output.count == 1200 * 1024)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeStdoutSyncReturnsInsteadOfHanging() async {
        let count = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            DispatchQueue.global().async {
                let output = try? SessionService.runShellSync(
                    ["dd", "if=/dev/zero", "bs=1024", "count=1200"])
                continuation.resume(returning: output?.count ?? -1)
            }
        }
        #expect(count == 1200 * 1024)
    }

    @Test(.timeLimit(.minutes(1)))
    func childReadingStdinGetsEOFImmediately() async throws {
        // macOS `/dev/fd/0` is the device itself, not a symlink, so `readlink`
        // fails even when stdin is `/dev/null`. Match the device identity and
        // require `read` to return EOF (a TTY would block; a closed fd errors).
        let output = try await SessionService.runShellAsync(env: env, args: [
            "sh", "-c",
            "null=$(stat -f '%d:%i' /dev/null); mine=$(stat -f '%d:%i' /dev/fd/0 2>/dev/null || printf missing); if IFS= read -r _; then printf 'DATA %s %s' \"$mine\" \"$null\"; else printf 'EOF %s %s' \"$mine\" \"$null\"; fi",
        ])
        let parts = output.split(separator: " ").map(String.init)
        #expect(parts.count == 3)
        #expect(parts.first == "EOF")
        #expect(parts.dropFirst().first == parts.last)
        #expect(parts.last != "missing")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationTerminatesTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-1323-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let task = Task {
            try await SessionService.runShellAsync(env: env, args: [
                "sh", "-c", "echo $$ > '\(pidFile.path)'; exec sleep 60",
            ])
        }
        let pid = await waitForPid(at: pidFile)
        #expect(pid > 0)
        task.cancel()

        let gone = await waitUntilGone(pid)
        #expect(gone)
        let result = await task.result
        if case .failure = result {
        } else {
            Issue.record("expected the cancelled shell call to throw")
        }
    }

    private func waitForPid(at url: URL) async -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return 0
    }

    private func waitUntilGone(_ pid: Int32) async -> Bool {
        guard pid > 0 else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return kill(pid, 0) != 0
    }
}
