import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `workspace-*` RPC handlers behind
/// `crow workspace` (CROW-809).
///
/// Same contract as `JobRPC` / `SettingsRPC`: no socket, no disk, so the param
/// validation and response shapes are unit-testable in isolation.
///
/// `workspace-edit` is a PATCH — a param that is absent (or explicitly null)
/// leaves the stored value alone. Two things follow from that, and they're the
/// reason this file exists rather than a handful of inline `params[…]?.stringValue`
/// reads:
///
/// 1. **A present-but-wrong-typed value throws** rather than being silently
///    dropped. (`job-edit`'s `params["workspace"]?.stringValue` idiom conflates
///    "absent" with "not a string" and reports success for a value it ignored.)
/// 2. **Optional scalars clear with an empty string**, matching the web form,
///    where blanking a text input stores `undefined`. Collections can't express
///    "empty" that way — an empty array is indistinguishable from "unchanged"
///    once it round-trips — so they take explicit `clear_*` booleans instead.
public enum WorkspaceRPC {

    // MARK: - Valid enum values

    /// Code/PR hosts, and task/ticket hosts. Both come from the model
    /// (``WorkspaceInfo/validProviders``), which derives them from ``Provider``,
    /// so the CLI's rejection messages and this validation share one source.
    public static var providers: [String] { WorkspaceInfo.validProviders }
    public static var taskProviders: [String] { WorkspaceInfo.validTaskProviders }

    /// The five `jiraStatusMap` keys, from ``TicketStatus/pipelineStatuses`` so
    /// this can't drift from the model.
    public static var jiraStatusKeys: [String] { TicketStatus.pipelineStatuses.map(\.rawValue) }

    // MARK: - Patch param decoding

    /// Every param ``applyPatch(_:to:name:)`` reads. `workspace` (the selector)
    /// and `force` are deliberately absent: neither changes a field, so an edit
    /// carrying only those is a no-op the handler must reject.
    public static let fieldKeys = [
        "name", "provider", "host", "task_provider",
        "jira_site", "jira_project_key", "jira_jql", "jira_status_map",
        "corveil_host", "custom_instructions", "session_env",
        "always_include", "auto_review_repos", "exclude_review_repos",
        "clear_always_include", "clear_auto_review_repos", "clear_exclude_review_repos",
        "clear_jira_status_map", "clear_session_env",
    ]

    /// Whether the params name at least one field to write. A `clear_*` sent as
    /// `false` doesn't count — it asks for nothing.
    public static func hasAnyField(_ params: [String: JSONValue]) -> Bool {
        fieldKeys.contains { key in
            guard let value = params[key], value != .null else { return false }
            if key.hasPrefix("clear_") { return value.boolValue == true }
            return true
        }
    }

    /// - Returns: `nil` when the key is absent or null ("leave unchanged").
    /// - Throws: `RPCError.invalidParams` when present but not a JSON string.
    public static func patchString(_ params: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = params[key], value != .null else { return nil }
        guard let text = value.stringValue else {
            throw RPCError.invalidParams("\(key) must be a string")
        }
        return text
    }

    /// - Returns: `nil` when the key is absent or null ("leave unchanged"), else
    ///   the list trimmed, blank-stripped and deduped preserving first-seen order.
    /// - Throws: `RPCError.invalidParams` when present but not an array of strings.
    public static func patchStringList(_ params: [String: JSONValue], _ key: String) throws -> [String]? {
        guard let value = params[key], value != .null else { return nil }
        guard let items = value.arrayValue else {
            throw RPCError.invalidParams("\(key) must be an array of strings")
        }
        var seen = Set<String>()
        return try items
            .map { item -> String in
                guard let text = item.stringValue else {
                    throw RPCError.invalidParams("\(key) must be an array of strings")
                }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// - Returns: `nil` when the key is absent or null ("leave unchanged").
    ///   Keys are **trimmed**, matching the CLI's `parseSessionEnv`; without that
    ///   a padded `" AWS_PROFILE"` sent over `/rpc` would be stored as a distinct
    ///   key from the one the CLI writes.
    /// - Throws: `RPCError.invalidParams` when present but not an object of
    ///   strings, or when any key is blank.
    public static func patchStringMap(_ params: [String: JSONValue], _ key: String) throws -> [String: String]? {
        guard let value = params[key], value != .null else { return nil }
        guard let object = value.objectValue else {
            throw RPCError.invalidParams("\(key) must be an object of string values")
        }
        var result: [String: String] = [:]
        for (name, item) in object {
            guard let text = item.stringValue else {
                throw RPCError.invalidParams("\(key)[\(name)] must be a string")
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw RPCError.invalidParams("\(key) keys must not be blank")
            }
            result[trimmed] = text
        }
        return result
    }

    /// A `clear_*` / `force` boolean. Absent means false; a present non-boolean
    /// throws, so a typo'd `"true"` string fails loudly instead of reading false.
    public static func flag(_ params: [String: JSONValue], _ key: String) throws -> Bool {
        guard let value = params[key], value != .null else { return false }
        guard let flag = value.boolValue else {
            throw RPCError.invalidParams("\(key) must be a boolean (true or false)")
        }
        return flag
    }

    /// Validate a code provider, listing the valid values on failure — the CLI
    /// surfaces the message verbatim.
    public static func decodeProvider(_ value: String) throws -> String {
        let provider = value.trimmingCharacters(in: .whitespaces)
        guard providers.contains(provider) else {
            throw RPCError.invalidParams(
                "provider must be one of: \(providers.joined(separator: ", ")) (got \"\(value)\")")
        }
        return provider
    }

    /// Validate a task provider. An empty string is legal and means "follow the
    /// code provider" — the Settings dropdown's blank option, stored as nil.
    public static func decodeTaskProvider(_ value: String) throws -> String? {
        let provider = value.trimmingCharacters(in: .whitespaces)
        if provider.isEmpty { return nil }
        guard taskProviders.contains(provider) else {
            throw RPCError.invalidParams(
                "task_provider must be one of: \(taskProviders.joined(separator: ", ")) or \"\" to follow the code provider (got \"\(value)\")")
        }
        return provider
    }

    /// Validate that every `jira_status_map` key is a pipeline status.
    ///
    /// A typo'd key would be stored and then never consulted — `JiraTaskBackend`
    /// looks the map up by ``TicketStatus`` raw value — so it fails here instead.
    public static func decodeJiraStatusMap(_ map: [String: String]) throws -> [String: String] {
        let valid = Set(jiraStatusKeys)
        for key in map.keys where !valid.contains(key) {
            throw RPCError.invalidParams(
                "jira_status_map key \"\(key)\" is not a pipeline status. Expected one of: \(jiraStatusKeys.joined(separator: ", "))")
        }
        return map
    }

    /// Validate a `session_env` map against the round-trip its consumer performs.
    ///
    /// This is a **delimiter-integrity** guard, not tidiness. The map's consumer
    /// is `skills/crow-workspace/setup.sh`, which flattens it to one
    /// `KEY=VALUE` per line and then splits each line back apart:
    ///
    /// ```
    /// jq -r '… | .sessionEnv // {} | to_entries[] | "\(.key)=\(.value)"'   # flatten
    /// key="${kv%%=*}"; value="${kv#*=}"                                     # split
    /// ```
    ///
    /// That round-trip has exactly two delimiters — the newline between entries
    /// and the first `=` within one — so a key or value carrying either comes
    /// back as something the operator never wrote:
    ///
    /// - **Newline in a value.** `{"FOO": "bar\nEVIL=injected"}` emits two lines,
    ///   and the second parses as its own pair — smuggling `EVIL=injected` into
    ///   the session's `settings.local.json` `.env` block.
    /// - **`=` in a key.** `{"FOO=BAR": "baz"}` emits `FOO=BAR=baz`, which splits
    ///   at the *first* `=` back into key `FOO`, value `BAR=baz` — a different
    ///   variable than the one stored.
    ///
    /// A `=` in a **value** is fine and common (connection strings, base64), since
    /// the split takes only the first one.
    ///
    /// Whitespace and control characters in a key are rejected too. They aren't a
    /// delimiter problem — they're simply not addressable: no shell can reference
    /// `FOO BAR`, so accepting one writes an entry that can never be read.
    ///
    /// The CLI already refuses these in `validateSessionEnvEntry`, but the CLI is
    /// not the only writer: `workspace-*` is intentionally reachable from a
    /// remote `/rpc` peer (see `RPCWebSocketHandler.localOnlyDenial`'s ledger),
    /// which never passes through `ParsableCommand.validate()`. The check has to
    /// live here to actually hold.
    ///
    /// Reads are never validated — a config hand-authored before these rules
    /// still loads unchanged; only writes are constrained.
    public static func decodeSessionEnv(_ map: [String: String]) throws -> [String: String] {
        for (key, value) in map {
            // CharacterSet, not `contains("\n")`: Swift treats CRLF as a single
            // Character, so a grapheme comparison misses "\r\n" entirely.
            guard key.rangeOfCharacter(from: .newlines) == nil else {
                throw RPCError.invalidParams(
                    "session_env keys must not contain a newline (key: \"\(key)\")")
            }
            guard !key.contains("=") else {
                throw RPCError.invalidParams(
                    "session_env keys must not contain '=' — the consumer splits each entry at the first '=', so \"\(key)\" would come back as a different variable")
            }
            guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  key.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw RPCError.invalidParams(
                    "session_env keys must not contain whitespace or control characters — no shell can reference \"\(key)\"")
            }
            guard value.rangeOfCharacter(from: .newlines) == nil else {
                throw RPCError.invalidParams(
                    "session_env values must not contain a newline — one entry must mean one variable (key: \"\(key)\")")
            }
        }
        return map
    }

    // MARK: - Lookup

    /// Find a workspace by UUID, falling back to a case-insensitive name match.
    ///
    /// ``WorkspaceInfo/validateName(_:existingNames:)`` enforces case-insensitive
    /// uniqueness, so a name matches at most one workspace — but nothing enforced
    /// it before CROW-809, so a config written by an older build (or by hand) can
    /// hold duplicates. Ambiguity is an error rather than a coin flip.
    public static func resolveIndex(_ ref: String, in config: AppConfig) throws -> Int {
        if let uid = UUID(uuidString: ref),
           let index = config.workspaces.firstIndex(where: { $0.id == uid }) {
            return index
        }
        let lowered = ref.lowercased()
        let matches = config.workspaces.indices.filter {
            config.workspaces[$0].name.lowercased() == lowered
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw RPCError.invalidParams("Unknown workspace '\(ref)'")
        default:
            throw RPCError.invalidParams(
                "'\(ref)' matches \(matches.count) workspaces — use the workspace UUID")
        }
    }

    // MARK: - Name validation

    /// Validate a new or changed workspace name against the model's own rules.
    ///
    /// This is ``WorkspaceInfo/validateName(_:existingNames:)``'s first production
    /// caller: the Settings form checks only "non-blank", so until now a duplicate
    /// or `/`-bearing name persisted fine. `excludingID` drops the workspace being
    /// renamed from the uniqueness check so re-stating its own name isn't a clash.
    ///
    /// - Returns: the trimmed name (`validateName` documents that it does not trim).
    public static func validateName(
        _ raw: String, in config: AppConfig, excludingID: UUID? = nil
    ) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let existing = config.workspaces
            .filter { $0.id != excludingID }
            .map(\.name)
        if let problem = WorkspaceInfo.validateName(name, existingNames: existing) {
            throw RPCError.invalidParams("\(problem) (name: \"\(raw)\")")
        }
        return name
    }

    // MARK: - Patch application

    /// Apply a `workspace-add` / `workspace-edit` param set to `workspace`
    /// **in place**.
    ///
    /// In place is load-bearing, not stylistic: `SettingsSecrets.preservingSecrets`
    /// matches stored gateways to workspaces by `id`, so rebuilding the struct
    /// through `WorkspaceInfo(name:…)` would mint a fresh UUID and silently drop
    /// the workspace's AI-gateway credentials. `id` and `gateway` are the two
    /// fields this function must never touch.
    ///
    /// - Returns: whether any field actually changed, so the handler can reject a
    ///   no-op instead of bumping `config.json`'s mtime and firing a spurious
    ///   "Config reloaded" chime in every open browser.
    @discardableResult
    public static func applyPatch(
        _ params: [String: JSONValue], to workspace: inout WorkspaceInfo, name: String? = nil
    ) throws -> Bool {
        let before = workspace

        if let name { workspace.name = name }

        if let provider = try patchString(params, "provider") {
            workspace.provider = try decodeProvider(provider)
        }
        // `cli` is derived, never sent: it's kept only for config-file compat with
        // builds that read it instead of `derivedCLI`. Re-derive on every write so
        // a stale value can't outlive a provider change (`settings.js` does the
        // same on commit).
        workspace.cli = workspace.derivedCLI

        if let host = try patchString(params, "host") { workspace.host = blankToNil(host) }
        if let taskProvider = try patchString(params, "task_provider") {
            workspace.taskProvider = try decodeTaskProvider(taskProvider)
        }
        if let site = try patchString(params, "jira_site") { workspace.jiraSite = blankToNil(site) }
        if let key = try patchString(params, "jira_project_key") {
            workspace.jiraProjectKey = blankToNil(key)
        }
        if let jql = try patchString(params, "jira_jql") { workspace.jiraJQL = blankToNil(jql) }
        if let host = try patchString(params, "corveil_host") {
            workspace.corveilHost = blankToNil(host)
        }
        // Custom instructions are free text: trimmed only at the ends, and never
        // blank-stripped in the middle. An all-whitespace value clears.
        if let instructions = try patchString(params, "custom_instructions") {
            workspace.customInstructions = blankToNil(instructions)
        }

        if try flag(params, "clear_always_include") { workspace.alwaysInclude = [] }
        if let repos = try patchStringList(params, "always_include") { workspace.alwaysInclude = repos }
        if try flag(params, "clear_auto_review_repos") { workspace.autoReviewRepos = [] }
        if let repos = try patchStringList(params, "auto_review_repos") { workspace.autoReviewRepos = repos }
        if try flag(params, "clear_exclude_review_repos") { workspace.excludeReviewRepos = [] }
        if let repos = try patchStringList(params, "exclude_review_repos") { workspace.excludeReviewRepos = repos }

        // The status map patches per key — each `--jira-status-*` flag sets one
        // entry and leaves the other four alone — so a blank value clears just
        // that entry, and `clear_jira_status_map` drops the whole block.
        if try flag(params, "clear_jira_status_map") { workspace.jiraStatusMap = nil }
        if let patch = try patchStringMap(params, "jira_status_map") {
            var map = workspace.jiraStatusMap ?? [:]
            for (key, value) in try decodeJiraStatusMap(patch) {
                if value.trimmingCharacters(in: .whitespaces).isEmpty {
                    map.removeValue(forKey: key)
                } else {
                    map[key] = value
                }
            }
            workspace.jiraStatusMap = map.isEmpty ? nil : map
        }

        // Unlike the status map, session env replaces wholesale: every
        // `--session-env` flag on one invocation is the complete set, matching how
        // the repo lists behave.
        if try flag(params, "clear_session_env") { workspace.sessionEnv = nil }
        if let env = try patchStringMap(params, "session_env").map(decodeSessionEnv) {
            workspace.sessionEnv = env.isEmpty ? nil : env
        }

        try validateCoherence(workspace, params: params)
        return workspace != before
    }

    /// Reject a write that would land in a field the workspace's own configuration
    /// never reads.
    ///
    /// The Settings form hides these inputs for exactly this reason — `host` only
    /// appears for GitLab, the Jira block only for `taskProvider == "jira"`. Since
    /// the CLI has no such affordance, writing one turns a silent no-effect
    /// ("I set jiraJQL and nothing happened") into an error.
    ///
    /// Only *written* fields are checked, against the **merged** result. Values
    /// already stored on the workspace are left alone, so flipping a workspace off
    /// Jira doesn't force you to clear its Jira block first.
    public static func validateCoherence(
        _ workspace: WorkspaceInfo, params: [String: JSONValue]
    ) throws {
        // Clearing a field is always allowed — you must be able to blank a value
        // that a provider change has stranded, and refusing that would make the
        // stranded value unreachable rather than merely inert.
        //
        // "Is this a clear?" has to be asked of the *contents*, not the JSON
        // type. A map patch is a set of independent per-key edits, so
        // `{"Ready": ""}` is a clear while `{"Ready": "To Do"}` is a write — and
        // a mix counts as a write, since the write is the half that would be
        // silently ignored.
        func isBlank(_ value: JSONValue) -> Bool {
            if let text = value.stringValue {
                return text.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if let object = value.objectValue { return object.values.allSatisfy(isBlank) }
            return false
        }

        func wrote(_ key: String) -> Bool {
            guard let value = params[key], value != .null else { return false }
            return !isBlank(value)
        }

        if wrote("host"), workspace.provider != "gitlab" {
            throw RPCError.invalidParams(
                "host applies to GitLab workspaces only — this workspace's provider is \"\(workspace.provider)\"")
        }
        let jiraKeys = ["jira_site", "jira_project_key", "jira_jql", "jira_status_map"]
        if let written = jiraKeys.first(where: wrote), workspace.derivedTaskProvider != "jira" {
            throw RPCError.invalidParams(
                "\(written) applies to Jira workspaces only — set task_provider=\"jira\" (currently \"\(workspace.derivedTaskProvider)\")")
        }
        if wrote("corveil_host"), workspace.derivedTaskProvider != "corveil" {
            throw RPCError.invalidParams(
                "corveil_host applies to Corveil workspaces only — set task_provider=\"corveil\" (currently \"\(workspace.derivedTaskProvider)\")")
        }
    }

    /// Trim, and treat an all-whitespace value as "cleared".
    private static func blankToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Response encoding

    /// Encode one workspace for a `workspace-*` response.
    ///
    /// **The gateway never crosses this boundary.** `WorkspaceGateway.customHeaders`
    /// holds API keys, and unlike `gateway-get` these methods are reachable from a
    /// remote `/rpc` peer (see the `localOnlyDenial` ledger), so the gateway
    /// collapses to a `gateway_set` flag plus its non-secret base URL. Reading or
    /// writing the credential itself stays with `crow gateway`, which is gated.
    ///
    /// Built as an object literal rather than a `JSONEncoder` round-trip: the
    /// point is that the wire shape is reviewable at a glance and that adding a
    /// field to `WorkspaceInfo` can never auto-publish it here.
    public static func workspaceJSON(_ workspace: WorkspaceInfo) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(workspace.id.uuidString),
            "name": .string(workspace.name),
            "provider": .string(workspace.provider),
            "cli": .string(workspace.derivedCLI),
            "task_provider": .string(workspace.derivedTaskProvider),
            "always_include": .array(workspace.alwaysInclude.map { .string($0) }),
            "auto_review_repos": .array(workspace.autoReviewRepos.map { .string($0) }),
            "exclude_review_repos": .array(workspace.excludeReviewRepos.map { .string($0) }),
            "gateway_set": .bool(!(workspace.gateway?.isEmpty ?? true)),
        ]
        // `task_provider_explicit` distinguishes "follow the code provider" from a
        // taskProvider that happens to equal it — the two round-trip differently.
        object["task_provider_explicit"] = .bool(workspace.taskProvider != nil)
        object["host"] = workspace.host.map { .string($0) } ?? .null
        object["custom_instructions"] = workspace.customInstructions.map { .string($0) } ?? .null
        object["jira_site"] = workspace.jiraSite.map { .string($0) } ?? .null
        object["jira_project_key"] = workspace.jiraProjectKey.map { .string($0) } ?? .null
        object["jira_jql"] = workspace.jiraJQL.map { .string($0) } ?? .null
        object["corveil_host"] = workspace.corveilHost.map { .string($0) } ?? .null
        object["jira_status_map"] = workspace.jiraStatusMap
            .map { JSONValue.object($0.mapValues { .string($0) }) } ?? .null
        object["session_env"] = workspace.sessionEnv
            .map { JSONValue.object($0.mapValues { .string($0) }) } ?? .null
        object["gateway_base_url"] = workspace.gateway.map { .string($0.baseURL) } ?? .null
        return .object(object)
    }
}
