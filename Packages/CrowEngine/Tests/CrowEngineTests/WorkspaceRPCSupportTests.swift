import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding, patch application and response encoding for the
/// `workspace-*` RPC handlers behind `crow workspace` (CROW-809).
@Suite("Workspace RPC support")
struct WorkspaceRPCSupportTests {

    private func workspace(_ name: String = "Acme") -> WorkspaceInfo {
        WorkspaceInfo(name: name)
    }

    // MARK: - patch tri-state

    /// The whole point of the `patch*` family: absent and null both mean "leave
    /// alone", and a present-but-wrong-typed value throws instead of silently
    /// reading as absent.
    @Test func patchHelpersDistinguishAbsentNullAndWrongType() throws {
        #expect(try WorkspaceRPC.patchString([:], "host") == nil)
        #expect(try WorkspaceRPC.patchString(["host": .null], "host") == nil)
        #expect(try WorkspaceRPC.patchString(["host": .string("h")], "host") == "h")
        #expect(throws: RPCError.self) { _ = try WorkspaceRPC.patchString(["host": .int(1)], "host") }

        #expect(try WorkspaceRPC.patchStringList([:], "always_include") == nil)
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.patchStringList(["always_include": .string("a")], "always_include")
        }
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.patchStringList(["always_include": .array([.int(1)])], "always_include")
        }

        #expect(try WorkspaceRPC.patchStringMap([:], "session_env") == nil)
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.patchStringMap(["session_env": .array([])], "session_env")
        }
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.patchStringMap(["session_env": .object(["K": .int(1)])], "session_env")
        }
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.patchStringMap(["session_env": .object(["  ": .string("v")])], "session_env")
        }
    }

    @Test func patchStringListTrimsBlanksAndDedupes() throws {
        let list = try WorkspaceRPC.patchStringList(
            ["always_include": .array([
                .string(" acme/api "), .string(""), .string("   "),
                .string("acme/api"), .string("acme/web"),
            ])], "always_include")
        // First-seen order preserved.
        #expect(list == ["acme/api", "acme/web"])
    }

    @Test func flagRejectsNonBooleans() throws {
        #expect(try WorkspaceRPC.flag([:], "force") == false)
        #expect(try WorkspaceRPC.flag(["force": .bool(true)], "force") == true)
        // A stringly-typed "true" would otherwise read as false and silently
        // skip the guard it was meant to override.
        #expect(throws: RPCError.self) { _ = try WorkspaceRPC.flag(["force": .string("true")], "force") }
    }

    @Test func hasAnyFieldIgnoresSelectorsAndFalseClears() {
        #expect(WorkspaceRPC.hasAnyField([:]) == false)
        #expect(WorkspaceRPC.hasAnyField(["workspace": .string("Acme"), "force": .bool(true)]) == false)
        #expect(WorkspaceRPC.hasAnyField(["clear_session_env": .bool(false)]) == false)
        #expect(WorkspaceRPC.hasAnyField(["clear_session_env": .bool(true)]) == true)
        #expect(WorkspaceRPC.hasAnyField(["host": .string("")]) == true)
    }

    // MARK: - enum decoding

    @Test func decodeProviderAcceptsCodeHostsOnly() throws {
        #expect(try WorkspaceRPC.decodeProvider("github") == "github")
        #expect(try WorkspaceRPC.decodeProvider(" gitlab ") == "gitlab")
        // Task-only providers have no git surface.
        for taskOnly in ["jira", "bitbucket"] {
            #expect(throws: RPCError.self) { _ = try WorkspaceRPC.decodeProvider(taskOnly) }
        }
    }

    @Test func decodeTaskProviderTreatsBlankAsFollowCodeProvider() throws {
        for provider in WorkspaceRPC.taskProviders {
            #expect(try WorkspaceRPC.decodeTaskProvider(provider) == provider)
        }
        #expect(try WorkspaceRPC.decodeTaskProvider("") == nil)
        #expect(try WorkspaceRPC.decodeTaskProvider("   ") == nil)
        #expect(throws: RPCError.self) { _ = try WorkspaceRPC.decodeTaskProvider("trello") }
    }

    /// The error has to name the valid values — the CLI surfaces it verbatim.
    @Test func providerErrorsListValidValues() {
        for (message, expected) in [
            (errorMessage { _ = try WorkspaceRPC.decodeProvider("nope") }, WorkspaceRPC.providers),
            (errorMessage { _ = try WorkspaceRPC.decodeTaskProvider("nope") }, WorkspaceRPC.taskProviders),
        ] {
            for value in expected { #expect(message.contains(value)) }
        }
    }

    @Test func decodeJiraStatusMapRejectsNonPipelineKeys() throws {
        #expect(try WorkspaceRPC.decodeJiraStatusMap(["In Progress": "In Dev"]) == ["In Progress": "In Dev"])
        // "Unknown" is a TicketStatus case but not a pipeline stage.
        for bad in ["in progress", "Unknown", "Todo"] {
            #expect(throws: RPCError.self) { _ = try WorkspaceRPC.decodeJiraStatusMap([bad: "x"]) }
        }
        let message = errorMessage { _ = try WorkspaceRPC.decodeJiraStatusMap(["Todo": "x"]) }
        for key in WorkspaceRPC.jiraStatusKeys { #expect(message.contains(key)) }
    }

    // MARK: - resolveIndex

    @Test func resolveIndexMatchesUUIDAndCaseInsensitiveName() throws {
        let acme = WorkspaceInfo(name: "Acme")
        let other = WorkspaceInfo(name: "Other")
        let config = AppConfig(workspaces: [acme, other])

        #expect(try WorkspaceRPC.resolveIndex(acme.id.uuidString, in: config) == 0)
        #expect(try WorkspaceRPC.resolveIndex("Acme", in: config) == 0)
        #expect(try WorkspaceRPC.resolveIndex("acme", in: config) == 0)
        #expect(try WorkspaceRPC.resolveIndex("OTHER", in: config) == 1)
        #expect(throws: RPCError.self) { _ = try WorkspaceRPC.resolveIndex("Nope", in: config) }
    }

    /// Nothing enforced name uniqueness before CROW-809, so a config written by
    /// an older build can hold duplicates. Ambiguity errors rather than picking.
    @Test func resolveIndexRefusesAmbiguousNames() {
        let config = AppConfig(workspaces: [WorkspaceInfo(name: "Acme"), WorkspaceInfo(name: "acme")])
        let message = errorMessage { _ = try WorkspaceRPC.resolveIndex("Acme", in: config) }
        #expect(message.contains("matches 2 workspaces"))
        // …but the UUID still resolves unambiguously.
        #expect(throws: Never.self) {
            _ = try WorkspaceRPC.resolveIndex(config.workspaces[1].id.uuidString, in: config)
        }
    }

    // MARK: - validateName

    @Test func validateNameAppliesTheModelRulesAndTrims() throws {
        let config = AppConfig(workspaces: [WorkspaceInfo(name: "Acme")])
        #expect(try WorkspaceRPC.validateName("  New  ", in: config) == "New")
        for bad in ["", "   ", "a/b", "a:b", ".", "..", "acme"] {
            #expect(throws: RPCError.self) { _ = try WorkspaceRPC.validateName(bad, in: config) }
        }
    }

    /// A rename must be able to restate the workspace's own name (or just change
    /// its case) without colliding with itself.
    @Test func validateNameExcludesTheWorkspaceBeingRenamed() throws {
        let acme = WorkspaceInfo(name: "Acme")
        let config = AppConfig(workspaces: [acme, WorkspaceInfo(name: "Other")])
        #expect(try WorkspaceRPC.validateName("ACME", in: config, excludingID: acme.id) == "ACME")
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.validateName("Other", in: config, excludingID: acme.id)
        }
    }

    // MARK: - applyPatch

    @Test func applyPatchWritesOnlyProvidedFields() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "gitlab", host: "old.io")
        target.alwaysInclude = ["acme/api"]
        try WorkspaceRPC.applyPatch(["host": .string("new.io")], to: &target)
        #expect(target.host == "new.io")
        #expect(target.alwaysInclude == ["acme/api"])
        #expect(target.name == "Acme")
    }

    @Test func applyPatchClearsScalarsWithEmptyString() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "gitlab", host: "old.io",
                                   customInstructions: "keep me")
        try WorkspaceRPC.applyPatch(
            ["host": .string(""), "custom_instructions": .string("  ")], to: &target)
        #expect(target.host == nil)
        #expect(target.customInstructions == nil)
    }

    /// `id` and `gateway` are the two fields a patch must never touch:
    /// `SettingsSecrets.preservingSecrets` matches stored gateways to workspaces
    /// by id, so rebuilding the struct would mint a new UUID and silently drop
    /// the credential.
    @Test func applyPatchPreservesIDAndGateway() throws {
        let gateway = WorkspaceGateway(baseURL: "https://gw.acme.io", customHeaders: ["X-Key": "sk-1"])
        var target = WorkspaceInfo(name: "Acme", gateway: gateway)
        let id = target.id
        try WorkspaceRPC.applyPatch([
            "provider": .string("gitlab"), "always_include": .array([.string("acme/api")]),
        ], to: &target, name: "Renamed")
        #expect(target.id == id)
        #expect(target.gateway == gateway)
        #expect(target.name == "Renamed")
    }

    /// `cli` is derived, never sent — re-deriving on every write keeps a stale
    /// value from outliving a provider change.
    @Test func applyPatchRederivesCLIFromProvider() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "github", cli: "gh")
        try WorkspaceRPC.applyPatch(["provider": .string("gitlab")], to: &target)
        #expect(target.cli == "glab")
        try WorkspaceRPC.applyPatch(["provider": .string("github")], to: &target)
        #expect(target.cli == "gh")
    }

    /// A config written before this rule can carry a `cli` that contradicts its
    /// provider; any edit repairs it.
    @Test func applyPatchRepairsStaleCLI() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "gitlab", cli: "gh")
        try WorkspaceRPC.applyPatch(["host": .string("h.io")], to: &target)
        #expect(target.cli == "glab")
    }

    @Test func applyPatchReplacesListsAndHonorsClearFlags() throws {
        var target = WorkspaceInfo(name: "Acme", alwaysInclude: ["acme/old"])
        try WorkspaceRPC.applyPatch(
            ["always_include": .array([.string("acme/api"), .string("acme/web")])], to: &target)
        #expect(target.alwaysInclude == ["acme/api", "acme/web"])

        try WorkspaceRPC.applyPatch(["clear_always_include": .bool(true)], to: &target)
        #expect(target.alwaysInclude.isEmpty)
    }

    /// The status map patches per key, so setting one entry leaves the rest.
    @Test func applyPatchMergesJiraStatusMapPerKey() throws {
        var target = WorkspaceInfo(name: "Acme", taskProvider: "jira",
                                   jiraStatusMap: ["Backlog": "Backlog", "Ready": "To Do"])
        try WorkspaceRPC.applyPatch(
            ["jira_status_map": .object(["In Progress": .string("In Dev")])], to: &target)
        #expect(target.jiraStatusMap == ["Backlog": "Backlog", "Ready": "To Do", "In Progress": "In Dev"])

        // A blank value clears just that entry…
        try WorkspaceRPC.applyPatch(
            ["jira_status_map": .object(["Ready": .string("")])], to: &target)
        #expect(target.jiraStatusMap == ["Backlog": "Backlog", "In Progress": "In Dev"])

        // …and the clear flag drops the whole block.
        try WorkspaceRPC.applyPatch(["clear_jira_status_map": .bool(true)], to: &target)
        #expect(target.jiraStatusMap == nil)
    }

    // MARK: - Review blocking severities (CROW-963)

    @Test func applyPatchReplacesReviewBlockingSeverities() throws {
        var target = WorkspaceInfo(name: "Acme")
        #expect(target.reviewBlockingSeverities == nil)
        #expect(target.effectiveReviewBlockingSeverities == [.red, .yellow])

        try WorkspaceRPC.applyPatch(
            ["review_blocking_severities": .array([.string("red")])], to: &target)
        #expect(target.reviewBlockingSeverities == [.red])
        #expect(target.effectiveReviewBlockingSeverities == [.red])

        // Canonicalized, so an input order can't produce a second stored form.
        try WorkspaceRPC.applyPatch(
            ["review_blocking_severities": .array([.string("yellow"), .string("red")])], to: &target)
        #expect(target.reviewBlockingSeverities == [.red, .yellow])
    }

    /// Clearing REMOVES the key rather than storing `[]`. The two are different
    /// policies — absent is Crow's default, `[]` would be "approve everything" —
    /// and the same nil-vs-absent discipline `crow agents set --clear` follows.
    @Test func applyPatchClearReviewBlockingSeveritiesRestoresTheDefault() throws {
        var target = WorkspaceInfo(name: "Acme", reviewBlockingSeverities: [.red])
        try WorkspaceRPC.applyPatch(
            ["clear_review_blocking_severities": .bool(true)], to: &target)
        #expect(target.reviewBlockingSeverities == nil)
        #expect(target.effectiveReviewBlockingSeverities == [.red, .yellow])
    }

    /// An empty blocking set means nothing gates the verdict, so every review
    /// approves — and with the auto-merge watcher on, merges. That posture is not
    /// offered; the error names the flag that does what the caller meant.
    @Test func applyPatchRejectsAnEmptyReviewBlockingSet() {
        for empty in [JSONValue.array([]), .array([.string("  ")])] {
            var target = WorkspaceInfo(name: "Acme", reviewBlockingSeverities: [.red])
            #expect(throws: RPCError.self) {
                _ = try WorkspaceRPC.applyPatch(["review_blocking_severities": empty], to: &target)
            }
            #expect(target.reviewBlockingSeverities == [.red], "a rejected patch must store nothing")
        }
    }

    /// Unknown severities are rejected on the write path even though the decoder
    /// drops them — a stored typo would silently relax the policy.
    @Test func applyPatchRejectsAnUnknownReviewSeverity() {
        var target = WorkspaceInfo(name: "Acme")
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(
                ["review_blocking_severities": .array([.string("red"), .string("chartreuse")])],
                to: &target)
        }
        #expect(target.reviewBlockingSeverities == nil)
    }

    /// Both keys are field keys, so `workspace edit` carrying only one of them is
    /// a real edit rather than "Nothing to edit".
    @Test func reviewBlockingSeverityKeysCountAsFields() {
        #expect(WorkspaceRPC.hasAnyField(
            ["review_blocking_severities": .array([.string("red")])]))
        #expect(WorkspaceRPC.hasAnyField(["clear_review_blocking_severities": .bool(true)]))
        #expect(WorkspaceRPC.hasAnyField(["clear_review_blocking_severities": .bool(false)]) == false)
    }

    /// `workspace get` echoes the effective list plus an explicit flag, so a
    /// caller can tell "inheriting the default" from "pinned to red + yellow".
    @Test func workspaceJSONEchoesTheEffectiveSeveritiesAndWhetherTheyArePinned() {
        let unset = WorkspaceRPC.workspaceJSON(WorkspaceInfo(name: "Acme")).objectValue
        #expect(unset?["review_blocking_severities"] == .array([.string("red"), .string("yellow")]))
        #expect(unset?["review_blocking_severities_explicit"] == .bool(false))

        let pinned = WorkspaceRPC.workspaceJSON(
            WorkspaceInfo(name: "Acme", reviewBlockingSeverities: [.red, .yellow])).objectValue
        #expect(pinned?["review_blocking_severities"] == .array([.string("red"), .string("yellow")]))
        #expect(pinned?["review_blocking_severities_explicit"] == .bool(true))
    }

    /// Session env replaces wholesale, unlike the status map — every
    /// `--session-env` on one invocation is the complete set.
    @Test func applyPatchReplacesSessionEnv() throws {
        var target = WorkspaceInfo(name: "Acme", sessionEnv: ["OLD": "1"])
        try WorkspaceRPC.applyPatch(["session_env": .object(["NEW": .string("2")])], to: &target)
        #expect(target.sessionEnv == ["NEW": "2"])

        try WorkspaceRPC.applyPatch(["clear_session_env": .bool(true)], to: &target)
        #expect(target.sessionEnv == nil)
    }

    /// Line injection: `setup.sh` reads `sessionEnv` as one `KEY=VALUE` per line
    /// (`jq -r '… | "\(.key)=\(.value)"'` into `while IFS= read -r kv`), so a
    /// value carrying a newline emits a *second* pair and smuggles an extra
    /// variable into the session's `settings.local.json` `.env`.
    ///
    /// The CLI refuses this in `validateSessionEnvEntry`, but `workspace-*` is
    /// reachable from a remote `/rpc` peer that never runs the CLI's `validate()`
    /// — so the guard has to hold here to hold at all.
    @Test func applyPatchRejectsNewlinesInSessionEnv() {
        for value in ["bar\nEVIL=injected", "bar\r\nEVIL=injected", "bar\rEVIL=injected"] {
            var target = WorkspaceInfo(name: "Acme")
            #expect(throws: RPCError.self) {
                _ = try WorkspaceRPC.applyPatch(
                    ["session_env": .object(["FOO": .string(value)])], to: &target)
            }
            #expect(target.sessionEnv == nil, "a rejected patch must store nothing")
        }
        // A newline in the *key* splits the line just as effectively.
        var target = WorkspaceInfo(name: "Acme")
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(
                ["session_env": .object(["FOO\nEVIL": .string("x")])], to: &target)
        }
    }

    /// The other half of the same delimiter contract. `setup.sh` splits each
    /// flattened line at the **first** `=` (`key="${kv%%=*}"`), so a key carrying
    /// one comes back as a different variable than the one stored:
    /// `{"FOO=BAR": "baz"}` flattens to `FOO=BAR=baz` and splits back to key
    /// `FOO`, value `BAR=baz`.
    ///
    /// Unreachable from the CLI — `parseSessionEnv` splits on the first `=`, so a
    /// key can never contain one — which is exactly why it has to be caught here,
    /// on the remote `/rpc` path.
    @Test func applyPatchRejectsEqualsInSessionEnvKeys() {
        for key in ["FOO=BAR", "=LEADING", "TRAILING="] {
            var target = WorkspaceInfo(name: "Acme")
            #expect(throws: RPCError.self, "expected key '\(key)' to be rejected") {
                _ = try WorkspaceRPC.applyPatch(
                    ["session_env": .object([key: .string("baz")])], to: &target)
            }
            #expect(target.sessionEnv == nil, "a rejected patch must store nothing")
        }
    }

    /// Whitespace and control characters in a key aren't a delimiter problem —
    /// they're simply not addressable, so an entry carrying one could never be
    /// read back by any shell.
    @Test func applyPatchRejectsUnaddressableSessionEnvKeys() {
        for key in ["FOO BAR", "FOO\tBAR", "FOO\u{0}BAR", "FOO\u{7}"] {
            var target = WorkspaceInfo(name: "Acme")
            #expect(throws: RPCError.self, "expected key '\(key)' to be rejected") {
                _ = try WorkspaceRPC.applyPatch(
                    ["session_env": .object([key: .string("v")])], to: &target)
            }
        }
    }

    /// The guard must not over-reach: values with `=`, spaces, or `#` are ordinary
    /// env values, and an empty value differs meaningfully from an unset one.
    @Test func applyPatchAllowsOrdinarySessionEnvValues() throws {
        var target = WorkspaceInfo(name: "Acme")
        try WorkspaceRPC.applyPatch(["session_env": .object([
            "DSN": .string("postgres://u:p@h/db?a=1&b=2"),
            "MSG": .string("hello world # not a comment"),
            "EMPTY": .string(""),
        ])], to: &target)
        #expect(target.sessionEnv?["DSN"] == "postgres://u:p@h/db?a=1&b=2")
        #expect(target.sessionEnv?["EMPTY"] == "")
    }

    /// Keys arrive trimmed regardless of writer, so a padded key sent over `/rpc`
    /// can't become a second entry alongside the CLI's (which trims in
    /// `parseSessionEnv`).
    @Test func applyPatchTrimsSessionEnvKeys() throws {
        var target = WorkspaceInfo(name: "Acme")
        try WorkspaceRPC.applyPatch(
            ["session_env": .object(["  AWS_PROFILE  ": .string("dev")])], to: &target)
        #expect(target.sessionEnv == ["AWS_PROFILE": "dev"])
    }

    /// Drives the handler's skip-the-write path, so re-running an idempotent
    /// edit doesn't churn config.json and chime in every open browser.
    @Test func applyPatchReportsWhetherAnythingChanged() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "gitlab", cli: "glab", host: "h.io")
        #expect(try WorkspaceRPC.applyPatch(["host": .string("h.io")], to: &target) == false)
        #expect(try WorkspaceRPC.applyPatch(["host": .string("other.io")], to: &target) == true)
    }

    /// …but repairing a stale `cli` *is* a change, so the write must happen even
    /// though the user's own flag was a no-op.
    @Test func applyPatchReportsChangedWhenOnlyTheStaleCLIIsRepaired() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "gitlab", cli: "gh", host: "h.io")
        #expect(try WorkspaceRPC.applyPatch(["host": .string("h.io")], to: &target) == true)
        #expect(target.cli == "glab")
    }

    // MARK: - Cross-field coherence

    /// Writing a field the workspace's configuration never reads is an error, not
    /// a silent no-effect — the Settings form hides these inputs for the same
    /// reason.
    @Test func applyPatchRejectsFieldsTheProviderNeverReads() {
        var github = WorkspaceInfo(name: "Acme", provider: "github")
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(["host": .string("gitlab.acme.io")], to: &github)
        }
        for key in ["jira_site", "jira_project_key", "jira_jql"] {
            var target = WorkspaceInfo(name: "Acme")
            #expect(throws: RPCError.self) {
                _ = try WorkspaceRPC.applyPatch([key: .string("x")], to: &target)
            }
        }
    }

    /// The check runs against the *merged* result, so setting the provider and
    /// its dependent field in one call is fine.
    @Test func applyPatchAllowsProviderAndDependentFieldTogether() throws {
        var target = WorkspaceInfo(name: "Acme")
        try WorkspaceRPC.applyPatch([
            "provider": .string("gitlab"), "host": .string("gitlab.acme.io"),
        ], to: &target)
        #expect(target.host == "gitlab.acme.io")

        var jira = WorkspaceInfo(name: "Acme")
        try WorkspaceRPC.applyPatch([
            "task_provider": .string("jira"), "jira_site": .string("acme.atlassian.net"),
            "jira_status_map": .object(["Done": .string("Closed")]),
        ], to: &jira)
        #expect(jira.jiraSite == "acme.atlassian.net")
    }

    /// A workspace whose taskProvider follows a GitHub/GitLab code provider is
    /// still not a Jira workspace.
    @Test func applyPatchUsesDerivedTaskProviderForJiraChecks() {
        var target = WorkspaceInfo(name: "Acme", provider: "gitlab")
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(["jira_jql": .string("x")], to: &target)
        }
    }

    /// Clearing must always be allowed — otherwise a value stranded by a provider
    /// change could never be removed.
    @Test func applyPatchAllowsClearingAStrandedField() throws {
        var target = WorkspaceInfo(name: "Acme", provider: "github", jiraJQL: "old")
        try WorkspaceRPC.applyPatch(["jira_jql": .string("")], to: &target)
        #expect(target.jiraJQL == nil)

        var stranded = WorkspaceInfo(name: "Acme", provider: "github", host: "gitlab.acme.io")
        try WorkspaceRPC.applyPatch(["host": .string("")], to: &stranded)
        #expect(stranded.host == nil)

        // …including a single entry of the status map, which is a *map* patch
        // rather than a scalar. The coherence check has to look inside it to
        // tell a clear from a write, or the documented per-key clear becomes
        // unreachable the moment a workspace leaves Jira.
        var strandedMap = WorkspaceInfo(
            name: "Acme", provider: "github",
            jiraStatusMap: ["Ready": "To Do", "Done": "Closed"])
        try WorkspaceRPC.applyPatch(
            ["jira_status_map": .object(["Ready": .string("")])], to: &strandedMap)
        #expect(strandedMap.jiraStatusMap == ["Done": "Closed"])

        // And clearing the whole map stays available too.
        try WorkspaceRPC.applyPatch(["clear_jira_status_map": .bool(true)], to: &strandedMap)
        #expect(strandedMap.jiraStatusMap == nil)
    }

    /// The other side of that: a map patch carrying any real value is still a
    /// write, so it must still be refused on a non-Jira workspace.
    @Test func applyPatchStillRejectsAStrandedStatusMapWrite() {
        var target = WorkspaceInfo(name: "Acme", provider: "github")
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(
                ["jira_status_map": .object(["Ready": .string("To Do")])], to: &target)
        }
        // Mixed clear-and-write counts as a write — the write is the part that
        // would be silently ignored.
        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(
                ["jira_status_map": .object(["Ready": .string(""), "Done": .string("Closed")])],
                to: &target)
        }
    }

    // MARK: - workspaceJSON

    @Test func workspaceJSONEmitsEveryFieldInSnakeCase() throws {
        let workspace = WorkspaceInfo(
            name: "Acme", provider: "gitlab", cli: "glab", host: "gitlab.acme.io",
            alwaysInclude: ["acme/api"], autoReviewRepos: ["acme/web"],
            excludeReviewRepos: ["acme/legacy"], customInstructions: "Run make test.",
            taskProvider: "jira", jiraProjectKey: "PROPS", jiraJQL: "assignee = currentUser()",
            jiraSite: "acme.atlassian.net", jiraStatusMap: ["In Progress": "In Dev"],
            sessionEnv: ["AWS_PROFILE": "dev"])
        let object = try #require(WorkspaceRPC.workspaceJSON(workspace).objectValue)

        #expect(object["id"] == .string(workspace.id.uuidString))
        #expect(object["name"] == .string("Acme"))
        #expect(object["provider"] == .string("gitlab"))
        #expect(object["cli"] == .string("glab"))
        #expect(object["host"] == .string("gitlab.acme.io"))
        #expect(object["task_provider"] == .string("jira"))
        #expect(object["task_provider_explicit"] == .bool(true))
        #expect(object["always_include"] == .array([.string("acme/api")]))
        #expect(object["jira_status_map"] == .object(["In Progress": .string("In Dev")]))
        #expect(object["session_env"] == .object(["AWS_PROFILE": .string("dev")]))
    }

    /// `task_provider` reports the *effective* provider, so the extra flag is the
    /// only way to tell "follow the code provider" from an explicit equal value.
    @Test func workspaceJSONDistinguishesFollowFromExplicitTaskProvider() throws {
        let follow = try #require(
            WorkspaceRPC.workspaceJSON(WorkspaceInfo(name: "A", provider: "gitlab")).objectValue)
        #expect(follow["task_provider"] == .string("gitlab"))
        #expect(follow["task_provider_explicit"] == .bool(false))

        let explicit = try #require(WorkspaceRPC.workspaceJSON(
            WorkspaceInfo(name: "A", provider: "gitlab", taskProvider: "gitlab")).objectValue)
        #expect(explicit["task_provider"] == .string("gitlab"))
        #expect(explicit["task_provider_explicit"] == .bool(true))
    }

    /// The security-relevant assertion: unlike `gateway-get`, these methods are
    /// reachable from a remote `/rpc` peer, so a gateway's header values must
    /// never appear in the payload at any depth.
    @Test func workspaceJSONNeverEmitsGatewayHeaders() throws {
        let workspace = WorkspaceInfo(
            name: "Acme",
            gateway: WorkspaceGateway(
                baseURL: "https://gw.acme.io",
                customHeaders: ["X-Api-Key": "sk-super-secret", "X-Org": "acme-secret-org"]))
        let json = WorkspaceRPC.workspaceJSON(workspace)
        let encoded = try String(data: JSONEncoder().encode(json), encoding: .utf8) ?? ""

        #expect(!encoded.contains("sk-super-secret"))
        #expect(!encoded.contains("acme-secret-org"))
        // Not even the header *names*, which leak which vendor is in use.
        #expect(!encoded.contains("X-Api-Key"))
        #expect(!encoded.contains("customHeaders"))

        let object = try #require(json.objectValue)
        #expect(object["gateway"] == nil)
        #expect(object["gateway_set"] == .bool(true))
        // The base URL is not a credential and `gateway-get` returns it unrevealed.
        #expect(object["gateway_base_url"] == .string("https://gw.acme.io"))
    }

    @Test func workspaceJSONReportsNoGatewayWhenUnset() throws {
        let object = try #require(WorkspaceRPC.workspaceJSON(workspace()).objectValue)
        #expect(object["gateway_set"] == .bool(false))
        #expect(object["gateway_base_url"] == .null)
    }

    /// The per-workspace session-log opt-in is a plain bool PATCH (CROW-1066):
    /// present writes it, absent leaves it, a non-bool throws.
    @Test func applyPatchWritesUploadSessionLogs() throws {
        var target = WorkspaceInfo(name: "Acme")
        #expect(target.uploadSessionLogs == false)

        #expect(try WorkspaceRPC.applyPatch(["upload_session_logs": .bool(true)], to: &target))
        #expect(target.uploadSessionLogs == true)

        // Absent ⇒ untouched (a PATCH), unlike a clear-flag that defaults to false.
        _ = try WorkspaceRPC.applyPatch(["custom_instructions": .string("x")], to: &target)
        #expect(target.uploadSessionLogs == true)

        #expect(try WorkspaceRPC.applyPatch(["upload_session_logs": .bool(false)], to: &target))
        #expect(target.uploadSessionLogs == false)

        #expect(throws: RPCError.self) {
            _ = try WorkspaceRPC.applyPatch(["upload_session_logs": .string("true")], to: &target)
        }
    }

    /// `upload_session_logs` is a field key, so `workspace edit` carrying only it
    /// is a real edit; `workspace get` echoes the stored bool.
    @Test func uploadSessionLogsIsAFieldAndIsEchoed() {
        #expect(WorkspaceRPC.hasAnyField(["upload_session_logs": .bool(true)]))
        #expect(WorkspaceRPC.hasAnyField(["upload_session_logs": .bool(false)]))
        let on = WorkspaceRPC.workspaceJSON(WorkspaceInfo(name: "Acme", uploadSessionLogs: true)).objectValue
        #expect(on?["upload_session_logs"] == .bool(true))
        let off = WorkspaceRPC.workspaceJSON(WorkspaceInfo(name: "Acme")).objectValue
        #expect(off?["upload_session_logs"] == .bool(false))
    }

    /// Capture the message a caller would see, for asserting it names the valid
    /// values rather than merely throwing something.
    private func errorMessage(_ body: () throws -> Void) -> String {
        do {
            try body()
            Issue.record("expected a throw")
            return ""
        } catch let error as RPCError {
            guard case .invalidParams(let message) = error else {
                Issue.record("expected invalidParams")
                return ""
            }
            return message
        } catch {
            Issue.record("expected RPCError, got \(error)")
            return ""
        }
    }
}
