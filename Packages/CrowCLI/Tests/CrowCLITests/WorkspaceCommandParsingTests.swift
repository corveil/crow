import ArgumentParser
import CrowCore
import CrowIPC
import Testing
@testable import CrowCLILib

// MARK: - `crow workspace` command parsing (CROW-809)

@Test func workspaceGroupRoutesToSubcommands() throws {
    #expect(try Workspace.parseAsRoot(["list"]) is WorkspaceList)
    #expect(try Workspace.parseAsRoot(["get", "--workspace", "Acme"]) is WorkspaceGet)
    #expect(try Workspace.parseAsRoot(["add", "--name", "Acme"]) is WorkspaceAdd)
    #expect(try Workspace.parseAsRoot(["edit", "--workspace", "Acme", "--jira-jql", "x"]) is WorkspaceEdit)
    #expect(try Workspace.parseAsRoot(["remove", "--workspace", "Acme"]) is WorkspaceRemove)
}

// MARK: - add

@Test func workspaceAddRequiresOnlyName() throws {
    let cmd = try WorkspaceAdd.parse(["--name", "Acme"])
    #expect(cmd.name == "Acme")
    // A bare create is legal — every other field has a documented default.
    #expect(try cmd.fields.paramsJSON().isEmpty)
}

@Test func workspaceAddRejectsBlankName() {
    #expect(throws: (any Error).self) { _ = try WorkspaceAdd.parse(["--name", "   "]) }
    #expect(throws: (any Error).self) { _ = try WorkspaceAdd.parse([]) }
}

@Test func workspaceAddSendsNameAlongsideFields() throws {
    let cmd = try WorkspaceAdd.parse(["--name", "Acme", "--provider", "gitlab"])
    var params = try cmd.fields.paramsJSON()
    params["name"] = .string(cmd.name)
    #expect(params["name"] == .string("Acme"))
    #expect(params["provider"] == .string("gitlab"))
}

// MARK: - scalar fields

@Test func workspaceScalarFieldsMapToSnakeCaseParams() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--provider", "gitlab",
        "--host", "gitlab.acme.io",
        "--task-provider", "jira",
        "--jira-site", "acme.atlassian.net",
        "--jira-project-key", "PROPS",
        "--jira-jql", "assignee = currentUser()",
        "--custom-instructions", "Always run make test.",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["provider"] == .string("gitlab"))
    #expect(params["host"] == .string("gitlab.acme.io"))
    #expect(params["task_provider"] == .string("jira"))
    #expect(params["jira_site"] == .string("acme.atlassian.net"))
    #expect(params["jira_project_key"] == .string("PROPS"))
    #expect(params["jira_jql"] == .string("assignee = currentUser()"))
    #expect(params["custom_instructions"] == .string("Always run make test."))
}

/// An omitted flag must contribute no key at all — that absence is what makes
/// the server side a patch rather than a replace.
@Test func workspaceOmittedFieldsSendNoKey() throws {
    let cmd = try WorkspaceEdit.parse(["--workspace", "Acme", "--host", "h.io"])
    let params = try cmd.fields.paramsJSON()
    #expect(params.count == 1)
    #expect(params["provider"] == nil)
    #expect(params["task_provider"] == nil)
    #expect(params["jira_status_map"] == nil)
}

/// Empty string is how an optional scalar clears — it must reach the server as
/// a present-but-empty value, not get dropped as "nothing to do".
@Test func workspaceEmptyStringClearsScalars() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme", "--host", "", "--task-provider", "", "--corveil-host", "",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["host"] == .string(""))
    #expect(params["task_provider"] == .string(""))
    #expect(params["corveil_host"] == .string(""))
}

// MARK: - repo lists

@Test func workspaceRepeatableListFlagsAccumulate() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--always-include", "acme/api", "--always-include", "acme/web",
        "--auto-review-repo", "acme/api",
        "--exclude-review-repo", "acme/legacy",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["always_include"] == .array([.string("acme/api"), .string("acme/web")]))
    #expect(params["auto_review_repos"] == .array([.string("acme/api")]))
    #expect(params["exclude_review_repos"] == .array([.string("acme/legacy")]))
}

@Test func workspaceClearFlagsSendClearKeys() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--clear-always-include", "--clear-auto-review-repos",
        "--clear-exclude-review-repos", "--clear-jira-status-map", "--clear-session-env",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["clear_always_include"] == .bool(true))
    #expect(params["clear_auto_review_repos"] == .bool(true))
    #expect(params["clear_exclude_review_repos"] == .bool(true))
    #expect(params["clear_jira_status_map"] == .bool(true))
    #expect(params["clear_session_env"] == .bool(true))
}

/// A clear flag left off sends nothing, rather than `false` — otherwise every
/// edit would carry five no-op keys.
@Test func workspaceUnsetClearFlagsSendNothing() throws {
    let cmd = try WorkspaceEdit.parse(["--workspace", "Acme", "--host", "h.io"])
    let params = try cmd.fields.paramsJSON()
    #expect(params["clear_always_include"] == nil)
    #expect(params["clear_session_env"] == nil)
    #expect(params["clear_review_blocking_severities"] == nil)
    #expect(params["review_blocking_severities"] == nil)
}

// MARK: - review blocking severities (CROW-963)

@Test func workspaceReviewBlockingSeverityFlagIsRepeatableAndCanonicalized() throws {
    // Repeatable, and stored severest-first regardless of the order given, so two
    // equivalent invocations don't produce two different config values.
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--review-blocking-severity", "yellow",
        "--review-blocking-severity", "red",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["review_blocking_severities"] == .array([.string("red"), .string("yellow")]))
}

@Test func workspaceReviewBlockingSeverityAcceptsASingleSeverity() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme", "--review-blocking-severity", "red",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["review_blocking_severities"] == .array([.string("red")]))
}

/// The clear flag restores the default (red + yellow) by removing the key — it
/// is the only way to say "no custom policy", since an empty repeated flag is
/// indistinguishable from an omitted one.
@Test func workspaceClearReviewBlockingSeveritiesSendsItsClearKey() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme", "--clear-review-blocking-severities",
    ])
    let params = try cmd.fields.paramsJSON()
    #expect(params["clear_review_blocking_severities"] == .bool(true))
    #expect(params["review_blocking_severities"] == nil)
    // The clear flag alone is a real edit, so `edit` must not reject it.
    #expect(cmd.fields.hasAnyField)
}

/// A typo is a parse error, not a value that silently stops blocking — that is
/// the whole reason the flag parses into the model enum rather than `[String]`.
@Test func workspaceReviewBlockingSeverityRejectsAnUnknownSeverity() {
    #expect(throws: (any Error).self) {
        try WorkspaceEdit.parse([
            "--workspace", "Acme", "--review-blocking-severity", "chartreuse",
        ])
    }
}

@Test func workspaceReviewBlockingSeverityCountsAsAField() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme", "--review-blocking-severity", "red",
    ])
    #expect(cmd.fields.hasAnyField)
}

// MARK: - jira status map

/// Each `--jira-status-*` flag must land on its own `TicketStatus` raw value —
/// the keys `JiraTaskBackend` looks the map up by.
@Test func workspaceJiraStatusFlagsMapToPipelineStatusKeys() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--jira-status-backlog", "Backlog",
        "--jira-status-ready", "Selected",
        "--jira-status-in-progress", "In Dev",
        "--jira-status-in-review", "Code Review",
        "--jira-status-done", "Closed",
    ])
    #expect(try cmd.fields.paramsJSON()["jira_status_map"] == .object([
        "Backlog": .string("Backlog"),
        "Ready": .string("Selected"),
        "In Progress": .string("In Dev"),
        "In Review": .string("Code Review"),
        "Done": .string("Closed"),
    ]))
}

@Test func workspaceJiraStatusKeysAreExactlyThePipelineStatuses() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--jira-status-backlog", "a", "--jira-status-ready", "b",
        "--jira-status-in-progress", "c", "--jira-status-in-review", "d",
        "--jira-status-done", "e",
    ])
    let keys = try cmd.fields.paramsJSON()["jira_status_map"]?.objectValue?.keys.sorted()
    #expect(keys == TicketStatus.pipelineStatuses.map(\.rawValue).sorted())
}

/// One blank status clears just that mapping, so it must survive as an empty
/// string rather than being filtered out of the map.
@Test func workspaceBlankJiraStatusIsSentToClearOneEntry() throws {
    let cmd = try WorkspaceEdit.parse(["--workspace", "Acme", "--jira-status-ready", ""])
    #expect(try cmd.fields.paramsJSON()["jira_status_map"] == .object(["Ready": .string("")]))
}

// MARK: - session env

@Test func workspaceSessionEnvParsesKeyValuePairs() throws {
    let cmd = try WorkspaceEdit.parse([
        "--workspace", "Acme",
        "--session-env", "AWS_PROFILE=dev",
        "--session-env", "NODE_ENV=development",
    ])
    #expect(try cmd.fields.paramsJSON()["session_env"] == .object([
        "AWS_PROFILE": .string("dev"),
        "NODE_ENV": .string("development"),
    ]))
}

/// Only the *first* `=` separates; a value may contain more (connection strings,
/// base64) and may be empty — an env var set to "" differs from an unset one.
@Test func workspaceSessionEnvKeepsValueVerbatimAfterFirstEquals() {
    let parsed = WorkspaceFieldArgs.parseSessionEnv([
        "DSN=postgres://u:p@h/db?a=1&b=2", "EMPTY=", "  PADDED  =v",
    ])
    #expect(parsed["DSN"] == .string("postgres://u:p@h/db?a=1&b=2"))
    #expect(parsed["EMPTY"] == .string(""))
    // The key is trimmed; the value is not.
    #expect(parsed["PADDED"] == .string("v"))
}

/// Last one wins on a repeated key — the rule a shell applies to a repeated
/// `export`.
@Test func workspaceSessionEnvLastEntryWinsOnRepeatedKey() {
    #expect(WorkspaceFieldArgs.parseSessionEnv(["K=first", "K=second"])["K"] == .string("second"))
}

@Test func workspaceSessionEnvRejectsMalformedEntries() {
    for bad in ["NOEQUALS", "=novalue", "  =v", "K=v\nINJECTED=x"] {
        #expect(throws: (any Error).self) {
            let cmd = try WorkspaceEdit.parse(["--workspace", "Acme", "--session-env", bad])
            try cmd.validate()
        }
    }
}

// MARK: - custom instructions

@Test func workspaceRejectsBothCustomInstructionsSources() {
    #expect(throws: (any Error).self) {
        let cmd = try WorkspaceEdit.parse([
            "--workspace", "Acme", "--custom-instructions", "a", "--custom-instructions-file", "/x",
        ])
        try cmd.validate()
    }
}

// MARK: - enum validation

@Test func workspaceRejectsUnknownProviders() {
    #expect(throws: (any Error).self) {
        let cmd = try WorkspaceAdd.parse(["--name", "A", "--provider", "bitbucket"])
        try cmd.validate()
    }
    // Jira and Corveil are task-only — they have no git surface, so they are
    // never a code provider.
    for taskOnly in ["jira", "corveil"] {
        #expect(throws: (any Error).self) {
            let cmd = try WorkspaceAdd.parse(["--name", "A", "--provider", taskOnly])
            try cmd.validate()
        }
    }
}

@Test func workspaceAcceptsEveryTaskProviderAndTheFollowOption() throws {
    for provider in WorkspaceInfo.validTaskProviders + [""] {
        let cmd = try WorkspaceAdd.parse(["--name", "A", "--task-provider", provider])
        try cmd.validate()
    }
    #expect(throws: (any Error).self) {
        let cmd = try WorkspaceAdd.parse(["--name", "A", "--task-provider", "trello"])
        try cmd.validate()
    }
}

// MARK: - edit / remove guards

@Test func workspaceEditRejectsNoFields() {
    #expect(editParseError(["--workspace", "Acme"]).contains("Nothing to edit"))
}

/// `--force` alone is not a field: it changes nothing, so it must not satisfy
/// the "at least one field" check.
@Test func workspaceEditForceAloneIsNotAField() {
    #expect(editParseError(["--workspace", "Acme", "--force"]).contains("Nothing to edit"))
}

@Test func workspaceEditAcceptsRenameAsTheOnlyChange() throws {
    let cmd = try WorkspaceEdit.parse(["--workspace", "Acme", "--name", "Acme2"])
    try cmd.validate()
    #expect(cmd.name == "Acme2")
    #expect(cmd.force == false)
}

@Test func workspaceEditAndRemoveRejectBlankSelector() {
    #expect(throws: (any Error).self) {
        let cmd = try WorkspaceEdit.parse(["--workspace", "  ", "--host", "h"])
        try cmd.validate()
    }
    #expect(throws: (any Error).self) {
        let cmd = try WorkspaceRemove.parse(["--workspace", "  "])
        try cmd.validate()
    }
}

@Test func workspaceRemoveParsesForce() throws {
    #expect(try WorkspaceRemove.parse(["--workspace", "Acme"]).force == false)
    #expect(try WorkspaceRemove.parse(["--workspace", "Acme", "--force"]).force == true)
}

/// The message a user actually sees on stderr — `parse` runs `validate`, so the
/// rejection surfaces here.
private func editParseError(_ args: [String]) -> String {
    do {
        _ = try WorkspaceEdit.parse(args)
        return ""
    } catch {
        return String(describing: error)
    }
}
