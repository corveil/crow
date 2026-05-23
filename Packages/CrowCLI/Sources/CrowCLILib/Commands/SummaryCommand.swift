import ArgumentParser
import CrowIPC
import Foundation

/// Print a cross-repo commit digest for a time window.
///
/// Calls the `get-summary` RPC, which scans every repo under the dev root and
/// groups commits by repo. Text output mirrors a changelog; `--json` emits the
/// raw structured result.
public struct Summary: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "Cross-repo commit digest over a time period"
    )

    @Option(name: .long, help: "Start of window (git date: '24 hours ago', '2026-05-01'). Defaults to the last 24 hours.")
    var since: String = "24 hours ago"

    @Option(name: .long, help: "End of window (git date). Defaults to now.")
    var until: String?

    @Flag(name: .long, help: "Emit raw JSON instead of formatted text.")
    var json = false

    public init() {}

    public func run() throws {
        var params: [String: JSONValue] = ["since": .string(since)]
        if let until { params["until"] = .string(until) }
        let result = try rpc("get-summary", params: params)
        if json {
            printJSON(result)
        } else {
            printDigest(result)
        }
    }

    /// Render the `repos` array as a grouped, per-repo changelog.
    private func printDigest(_ result: [String: JSONValue]) {
        let repos = result["repos"]?.arrayValue ?? []
        let totalCommits = repos.reduce(0) { acc, repo in
            acc + (repo.objectValue?["commits"]?.arrayValue?.count ?? 0)
        }
        let window = until.map { "\(since) until \($0)" } ?? since
        print("## Since \(window) · \(totalCommits) commit\(totalCommits == 1 ? "" : "s") · \(repos.count) repo\(repos.count == 1 ? "" : "s")")

        for repo in repos {
            guard let obj = repo.objectValue else { continue }
            let name = obj["repo"]?.stringValue ?? "(unknown)"
            let commits = obj["commits"]?.arrayValue ?? []
            let ins = obj["totalInsertions"]?.intValue ?? 0
            let del = obj["totalDeletions"]?.intValue ?? 0
            let files = obj["totalFilesChanged"]?.intValue ?? commits.reduce(0) {
                $0 + ($1.objectValue?["filesChanged"]?.intValue ?? 0)
            }

            print("")
            print("### \(name) (\(commits.count))")
            for commit in commits {
                let subject = commit.objectValue?["subject"]?.stringValue ?? ""
                print("- \(subject)")
            }
            print("  \(files) file\(files == 1 ? "" : "s"), +\(ins) / -\(del)")
        }
    }
}
