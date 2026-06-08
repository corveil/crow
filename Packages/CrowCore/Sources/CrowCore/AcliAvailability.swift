import Foundation

/// Whether `acli` (the Atlassian CLI driving the Jira `TaskBackend`) is usable.
/// Drives the availability-aware Task Backend picker in workspace settings — Jira
/// is only offered when this resolves to `.ready`.
public enum JiraAvailability: Sendable, Equatable {
    case ready            // acli installed + authenticated
    case notInstalled     // acli binary missing on PATH
    case notAuthenticated // acli present but `acli jira auth login` not done

    /// A short, actionable hint for the unavailable states (nil when `.ready`).
    public var fixHint: String? {
        switch self {
        case .ready:
            return nil
        case .notInstalled:
            return "acli is not installed. Install the Atlassian CLI, then run `acli jira auth login`."
        case .notAuthenticated:
            return "acli is installed but not authenticated. Run `acli jira auth login`."
        }
    }
}

/// Probes `acli` availability so the UI and backends can gate Jira features.
///
/// Lives in CrowCore (rather than CrowProvider) so SwiftUI views in CrowUI can
/// call it without pulling in the whole provider layer.
public enum AcliProbe {
    /// Run `acli jira auth status`. Exit 0 ⇒ authenticated; a "command not found"
    /// style failure ⇒ not installed; anything else ⇒ installed but not authed.
    public static func availability(shellRunner: ShellRunner = ProcessShellRunner()) async -> JiraAvailability {
        do {
            _ = try await shellRunner.run(args: ["acli", "jira", "auth", "status"], env: [:], cwd: NSHomeDirectory())
            return .ready
        } catch let ShellRunnerError.nonZeroExit(exitCode, output) {
            let lower = output.lowercased()
            if exitCode == 127
                || lower.contains("no such file")
                || lower.contains("command not found")
                || lower.contains("not found") {
                return .notInstalled
            }
            return .notAuthenticated
        } catch {
            return .notInstalled
        }
    }
}
