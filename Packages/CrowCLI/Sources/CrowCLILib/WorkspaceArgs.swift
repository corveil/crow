import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// Lets `--review-blocking-severity` parse straight into the model enum
/// (CROW-963), the same way `AgentCommands` does for `SessionKind`:
/// ArgumentParser derives `init?(argument:)` from the `String` raw value and —
/// because `ReviewSeverity` is `CaseIterable` — `allValueStrings`, so `red`,
/// `yellow`, `green` appear in `--help` and in the rejection message. A typo is a
/// parse error rather than a value that silently stops blocking.
extension ReviewSeverity: @retroactive ExpressibleByArgument {}

/// The `WorkspaceInfo` field flags shared by `crow workspace add` and
/// `crow workspace edit` (CROW-809).
///
/// One `@OptionGroup` rather than two copies of ~20 flags: `add` and `edit`
/// accept exactly the same fields, and the only difference is that `add`
/// requires `--name` while `edit` treats it as a rename. Each declares `--name`
/// itself for that reason; everything else lives here.
///
/// **Clearing.** Optional scalars clear with an empty string (`--host ""`),
/// mirroring the Settings form, where blanking a text input stores `undefined`.
/// Collections can't say "empty" that way — an empty repeated flag is
/// indistinguishable from an omitted one — so they get explicit `--clear-*`
/// flags. `--jira-status-<stage> ""` clears one map entry;
/// `--clear-jira-status-map` drops the whole block.
struct WorkspaceFieldArgs: ParsableArguments {
    @Option(name: .long, help: "Code/PR host: github or gitlab")
    var provider: String?

    @Option(name: .long, help: "GitLab host, e.g. gitlab.example.com (GitLab workspaces only; \"\" clears)")
    var host: String?

    @Option(name: .customLong("task-provider"),
            help: "Where tickets live: github, gitlab, or jira (\"\" follows the code provider)")
    var taskProvider: String?

    @Option(name: .customLong("jira-site"), help: "Atlassian site, e.g. acme.atlassian.net (\"\" clears)")
    var jiraSite: String?
    @Option(name: .customLong("jira-project-key"), help: "Jira project key, e.g. PROPS (\"\" clears)")
    var jiraProjectKey: String?
    @Option(name: .customLong("jira-jql"), help: "JQL for this workspace's ticket board (\"\" clears)")
    var jiraJQL: String?

    // One flag per pipeline status, mirroring the five text fields in the
    // Settings form. A repeatable "Crow=Jira" flag would make the Crow-side key
    // a free string to typo; these can't be.
    @Option(name: .customLong("jira-status-backlog"), help: "Jira status name for Backlog (\"\" clears)")
    var jiraStatusBacklog: String?
    @Option(name: .customLong("jira-status-ready"), help: "Jira status name for Ready (\"\" clears)")
    var jiraStatusReady: String?
    @Option(name: .customLong("jira-status-in-progress"), help: "Jira status name for In Progress (\"\" clears)")
    var jiraStatusInProgress: String?
    @Option(name: .customLong("jira-status-in-review"), help: "Jira status name for In Review (\"\" clears)")
    var jiraStatusInReview: String?
    @Option(name: .customLong("jira-status-done"), help: "Jira status name for Done (\"\" clears)")
    var jiraStatusDone: String?
    @Flag(name: .customLong("clear-jira-status-map"), help: "Drop every Crow→Jira status mapping")
    var clearJiraStatusMap: Bool = false

    @Option(name: .customLong("custom-instructions"),
            help: "Free text appended to this workspace's session prompts (\"\" clears)")
    var customInstructions: String?
    @Option(name: .customLong("custom-instructions-file"),
            help: "Read --custom-instructions from a file; '-' reads stdin")
    var customInstructionsFile: String?

    @Option(name: .customLong("always-include"), parsing: .singleValue,
            help: "Repo always listed in the prompt table (repeatable; replaces the whole list)")
    var alwaysInclude: [String] = []
    @Flag(name: .customLong("clear-always-include"), help: "Empty the always-include list")
    var clearAlwaysInclude: Bool = false

    @Option(name: .customLong("auto-review-repo"), parsing: .singleValue,
            help: "Repo whose review requests auto-create a session (repeatable; replaces the whole list)")
    var autoReviewRepos: [String] = []
    @Flag(name: .customLong("clear-auto-review-repos"), help: "Empty the auto-review list")
    var clearAutoReviewRepos: Bool = false

    @Option(name: .customLong("exclude-review-repo"), parsing: .singleValue,
            help: "Repo hidden from the review board (repeatable; replaces the whole list)")
    var excludeReviewRepos: [String] = []
    @Flag(name: .customLong("clear-exclude-review-repos"), help: "Empty the exclude-from-reviews list")
    var clearExcludeReviewRepos: Bool = false

    @Option(name: .customLong("session-env"), parsing: .singleValue,
            help: "KEY=VALUE exported into agents in this workspace (repeatable; replaces the whole map)")
    var sessionEnv: [String] = []
    @Flag(name: .customLong("clear-session-env"), help: "Drop every session env var")
    var clearSessionEnv: Bool = false

    @Option(name: .customLong("upload-session-logs"),
            help: "Upload this workspace's coding-session transcripts to Corveil, reusing its gateway credential: true or false (needs the local-only log-sync master switch on)")
    var uploadSessionLogs: Bool?

    @Option(name: .customLong("review-blocking-severity"), parsing: .singleValue,
            help: "Review finding severity that forces --request-changes (repeatable; replaces the whole list; default red + yellow)")
    var reviewBlockingSeverities: [ReviewSeverity] = []
    @Flag(name: .customLong("clear-review-blocking-severities"),
          help: "Restore the default review blocking set (red + yellow)")
    var clearReviewBlockingSeverities: Bool = false

    /// The `--jira-status-*` flags paired with the `TicketStatus` raw value each
    /// one writes, so the mapping is stated once.
    private var jiraStatusFlags: [(status: TicketStatus, value: String?)] {
        [
            (.backlog, jiraStatusBacklog),
            (.ready, jiraStatusReady),
            (.inProgress, jiraStatusInProgress),
            (.inReview, jiraStatusInReview),
            (.done, jiraStatusDone),
        ]
    }

    /// Whether any field flag was given. `add` doesn't consult this (a bare
    /// `--name` is a valid create); `edit` rejects an invocation without it.
    var hasAnyField: Bool {
        provider != nil || host != nil || taskProvider != nil
            || jiraSite != nil || jiraProjectKey != nil || jiraJQL != nil
            || customInstructions != nil || customInstructionsFile != nil
            || !alwaysInclude.isEmpty || !autoReviewRepos.isEmpty || !excludeReviewRepos.isEmpty
            || !sessionEnv.isEmpty || !reviewBlockingSeverities.isEmpty
            || uploadSessionLogs != nil
            || jiraStatusFlags.contains { $0.value != nil }
            || clearAlwaysInclude || clearAutoReviewRepos || clearExcludeReviewRepos
            || clearJiraStatusMap || clearSessionEnv || clearReviewBlockingSeverities
    }

    func validate() throws {
        if let provider { try validateWorkspaceProvider(provider) }
        if let taskProvider { try validateWorkspaceTaskProvider(taskProvider) }
        for entry in sessionEnv { try validateSessionEnvEntry(entry) }
        guard customInstructions == nil || customInstructionsFile == nil else {
            throw ValidationError(
                "--custom-instructions and --custom-instructions-file are mutually exclusive.")
        }
    }

    /// Build the RPC params for the fields that were actually provided.
    ///
    /// An omitted flag contributes no key at all, which is what makes the server
    /// side a PATCH — see `WorkspaceRPC.applyPatch`.
    func paramsJSON() throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let provider { params["provider"] = .string(provider) }
        if let host { params["host"] = .string(host) }
        if let taskProvider { params["task_provider"] = .string(taskProvider) }
        if let jiraSite { params["jira_site"] = .string(jiraSite) }
        if let jiraProjectKey { params["jira_project_key"] = .string(jiraProjectKey) }
        if let jiraJQL { params["jira_jql"] = .string(jiraJQL) }

        if let customInstructions { params["custom_instructions"] = .string(customInstructions) }
        if let customInstructionsFile {
            params["custom_instructions"] = .string(
                try JobScheduleArgs.readPromptText(customInstructionsFile))
        }

        if !alwaysInclude.isEmpty { params["always_include"] = .array(alwaysInclude.map { .string($0) }) }
        if !autoReviewRepos.isEmpty { params["auto_review_repos"] = .array(autoReviewRepos.map { .string($0) }) }
        if !excludeReviewRepos.isEmpty {
            params["exclude_review_repos"] = .array(excludeReviewRepos.map { .string($0) })
        }
        if clearAlwaysInclude { params["clear_always_include"] = .bool(true) }
        if clearAutoReviewRepos { params["clear_auto_review_repos"] = .bool(true) }
        if clearExcludeReviewRepos { params["clear_exclude_review_repos"] = .bool(true) }

        let statusMap = jiraStatusFlags.reduce(into: [String: JSONValue]()) { map, flag in
            if let value = flag.value { map[flag.status.rawValue] = .string(value) }
        }
        if !statusMap.isEmpty { params["jira_status_map"] = .object(statusMap) }
        if clearJiraStatusMap { params["clear_jira_status_map"] = .bool(true) }

        if !sessionEnv.isEmpty {
            params["session_env"] = .object(WorkspaceFieldArgs.parseSessionEnv(sessionEnv))
        }
        if clearSessionEnv { params["clear_session_env"] = .bool(true) }

        // Deduped and canonicalized here so `--review-blocking-severity yellow
        // --review-blocking-severity red` and the reverse produce one stored
        // order, and a repeated flag isn't stored twice (CROW-963).
        if !reviewBlockingSeverities.isEmpty {
            params["review_blocking_severities"] = .array(
                ReviewSeverity.canonicalize(reviewBlockingSeverities).map { .string($0.rawValue) })
        }
        if clearReviewBlockingSeverities {
            params["clear_review_blocking_severities"] = .bool(true)
        }
        if let uploadSessionLogs { params["upload_session_logs"] = .bool(uploadSessionLogs) }
        return params
    }

    /// Split `KEY=VALUE` entries into a map. The key is trimmed; the value is
    /// taken verbatim after the first `=`, so a value may itself contain `=`
    /// (common in connection strings) and may be empty.
    ///
    /// Later entries win on a repeated key — the same last-one-wins rule a shell
    /// applies to a repeated `export`.
    static func parseSessionEnv(_ entries: [String]) -> [String: JSONValue] {
        entries.reduce(into: [String: JSONValue]()) { map, entry in
            guard let split = entry.firstIndex(of: "=") else { return }
            let key = String(entry[..<split]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            map[key] = .string(String(entry[entry.index(after: split)...]))
        }
    }
}
