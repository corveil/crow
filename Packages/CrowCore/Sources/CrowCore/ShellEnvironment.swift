import Foundation

/// Resolves the user's login shell PATH for subprocess execution.
///
/// When Crow.app launches from Finder/Dock, macOS provides a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`). This singleton resolves the full PATH
/// from the user's login shell so that Homebrew-installed tools like `gh`,
/// `glab`, and `claude` can be found.
public final class ShellEnvironment: Sendable {
    public static let shared = ShellEnvironment()

    /// Full process environment with the resolved PATH.
    public let env: [String: String]

    /// The resolved PATH string.
    public let resolvedPATH: String

    private init() {
        let inherited = ProcessInfo.processInfo.environment
        let resolved = Self.resolvePATH(inherited: inherited)
        self.resolvedPATH = resolved
        var environment = inherited
        environment["PATH"] = resolved
        self.env = environment
    }

    /// Returns `env` with additional key-value pairs merged on top.
    public func merging(_ extra: [String: String]) -> [String: String] {
        env.merging(extra) { _, new in new }
    }

    /// Returns the absolute path of `name` if it resolves to an executable on
    /// the user's PATH, or `nil` otherwise. Mirrors the behavior of shell
    /// `command -v` — walks `resolvedPATH` left-to-right and returns the first
    /// hit. Used by every `CodingAgent` to find its CLI binary regardless of
    /// where the user's package manager installed it (npm-global / nvm /
    /// volta / pnpm / asdf — see CROW-484).
    public func findExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in resolvedPATH.split(separator: ":") {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Returns `true` if `name` is an executable found in the resolved PATH.
    public func hasCommand(_ name: String) -> Bool {
        findExecutable(name) != nil
    }

    // MARK: - PATH Resolution

    private static func resolvePATH(inherited: [String: String]) -> String {
        if let resolved = resolveFromLoginShell(inherited: inherited) {
            return resolved
        }
        return fallbackPATH(inherited: inherited)
    }

    /// Runs the user's login shell to extract the full PATH.
    private static func resolveFromLoginShell(inherited: [String: String]) -> String? {
        let shell = inherited["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "echo $PATH"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Inherit current environment so $HOME etc. are available
        process.environment = inherited

        do {
            try process.run()
        } catch {
            CrowLog.info("[Crow] Failed to launch login shell for PATH resolution: \(error.localizedDescription)")
            return nil
        }

        // Timeout after 5 seconds to avoid hanging on slow shell configs
        let deadline = DispatchTime.now() + .seconds(5)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            CrowLog.info("[Crow] Login shell PATH resolution timed out")
            return nil
        }

        guard process.terminationStatus == 0 else {
            CrowLog.info("[Crow] Login shell exited with status \(process.terminationStatus)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Take the last non-empty line (shell may print MOTD/banners before echo)
        let path = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)

        guard let path, !path.isEmpty else { return nil }
        CrowLog.info("[Crow] Resolved PATH from login shell (\(path.split(separator: ":").count) components)")
        return path
    }

    /// Appends well-known tool directories to the inherited PATH.
    private static func fallbackPATH(inherited: [String: String]) -> String {
        CrowLog.info("[Crow] Using fallback PATH resolution")
        let current = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = Set(current.split(separator: ":").map(String.init))

        let wellKnown = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            NSHomeDirectory() + "/.local/bin",
        ]

        let additions = wellKnown.filter { !existing.contains($0) }
        if additions.isEmpty { return current }
        return current + ":" + additions.joined(separator: ":")
    }
}
