import Foundation
import CrowProvider

/// Builds the wrapped launch prompt for a Corveil worker run (corveil/crow#801).
///
/// Crow owns the run lifecycle (claim → heartbeat → complete), so the agent's
/// job is narrower than the manual `worker-runner` skill loop: execute the
/// snapshotted `prompt_body`, perform any allow-listed write-backs via
/// `corveil worker-run mcp-call`, and end by writing a machine-readable result
/// to `.crow-run-result.json`. Crow reads that file on the agent's `.done` hook
/// and maps it onto `corveil worker-run complete`.
///
/// Pure (no I/O) so it's unit-testable.
enum WorkerRunPrompt {
    /// The result file the agent must write; Crow reads it on finish.
    static let resultFileName = ".crow-run-result.json"

    static func build(run: WorkerRun, workerID: String) -> String {
        var lines: [String] = []

        lines.append("# Corveil worker run")
        lines.append("")
        lines.append("You are executing **Corveil worker run `\(run.id)`** as an external Crow runner. "
            + "Carry out the task below on your own model/subscription. Crow has already claimed this run "
            + "and is holding the lease for you — do **not** call `worker-run claim`, `heartbeat`, or `complete`; "
            + "Crow does that. Your only Corveil calls are the allow-listed write-backs described below.")
        lines.append("")

        lines.append("## Task")
        lines.append("")
        let body = (run.promptBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(body.isEmpty ? "_(This run carries no prompt body.)_" : body)
        lines.append("")

        lines.append(contentsOf: writebackSection(run: run, workerID: workerID))

        lines.append("## Finishing")
        lines.append("")
        lines.append("When you are done, write your result as JSON to `\(resultFileName)` in this directory. "
            + "This is how Crow reports your outcome back to Corveil — a run with no result file is completed "
            + "with an error. Shape:")
        lines.append("")
        lines.append("```json")
        lines.append("""
        {
          "title": "one-line summary of what you did",
          "content": "what you changed and why (the human-readable result)",
          "output": { "entities_written": 0 },
          "error": ""
        }
        """)
        lines.append("```")
        lines.append("")
        lines.append("- `title` / `content` are required on success. `output` is an optional typed object. "
            + "Leave `error` empty (or omit it) on success.")
        lines.append("- If the task **failed**, set `error` to a concise reason and leave the rest as-is; "
            + "Crow will fail the run with that message.")

        return lines.joined(separator: "\n") + "\n"
    }

    /// The write-back guidance block, derived from the run's snapshotted policy.
    private static func writebackSection(run: WorkerRun, workerID: String) -> [String] {
        var lines: [String] = ["## Write-backs"]
        lines.append("")
        let policy = run.writebackPolicy ?? [:]
        guard !policy.isEmpty else {
            lines.append("This run grants **no** write-back tools. Produce your result and finish; do not "
                + "attempt any `worker-run mcp-call` (it will be rejected).")
            lines.append("")
            return lines
        }

        lines.append("All state changes go through Corveil so no credentials live on this host. Call an "
            + "allow-listed tool with:")
        lines.append("")
        lines.append("```")
        lines.append("corveil worker-run mcp-call \(run.id) \\")
        lines.append("  --worker-id \(workerID) \\")
        lines.append("  --server <server> --tool <tool> --args '<json>'")
        lines.append("```")
        lines.append("")
        lines.append("Permitted server/tool pairs for this run:")
        for server in policy.keys.sorted() {
            guard let binding = policy[server] else { continue }
            let tools = binding.allowed.isEmpty ? "(none)" : binding.allowed.joined(separator: ", ")
            let dryRun = binding.dryRun ? "  _(dry-run: calls are previewed, not executed)_" : ""
            lines.append("- **\(server)** → \(tools)\(dryRun)")
        }
        lines.append("")
        lines.append("Rules: respect dry-run bindings (a preview is not a write); a `403` means the call is "
            + "outside policy — stop, don't retry. Every ontology write needs a concise `reason`.")
        lines.append("")
        return lines
    }
}
