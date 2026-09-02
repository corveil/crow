import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `defaults-*` RPC handlers behind
/// `crow defaults` (CROW-810).
///
/// Same contract as `SettingsRPC`: no socket, no disk, so the param validation
/// and response shapes are unit-testable in isolation. `defaults-set` is a PATCH
/// — a param that is absent (or explicitly null) leaves the stored value alone,
/// and a *present but wrong-typed* value throws rather than being silently
/// dropped.
///
/// This is the one settings subtree that can reach `defaults.binaries`, so
/// `RPCWebSocketHandler.localOnlyDenial` gates `defaults-set` on the presence of
/// that param. `mergeBinaries` below is deliberately the *single* merge
/// implementation — the gate does not call it, which is what keeps the gate a
/// key lookup rather than a second copy of these semantics.
public enum DefaultsRPC {

    // The accepted provider/CLI spellings, the reserved binary name and the
    // binary-name predicate all live on `ConfigDefaults` in CrowCore, next to
    // `isValidBranchPrefix` — so `crow defaults set` and this handler validate
    // against one list rather than the hand-kept copies `validQuickActions`
    // warns about.

    // MARK: - Scalar patch params

    /// - Returns: `nil` when the key is absent or null ("leave unchanged").
    /// - Throws: `RPCError.invalidParams` when present but not one of
    ///   `validProviders`.
    public static func patchProvider(
        _ params: [String: JSONValue], _ key: String = "provider"
    ) throws -> String? {
        guard let raw = try patchString(params, key) else { return nil }
        guard ConfigDefaults.validProviders.contains(raw) else {
            throw RPCError.invalidParams(
                "\(key) must be one of: \(ConfigDefaults.validProviders.joined(separator: ", "))")
        }
        return raw
    }

    /// - Returns: `nil` when the key is absent or null.
    /// - Throws: `RPCError.invalidParams` when present but not one of `validCLIs`.
    public static func patchCLI(
        _ params: [String: JSONValue], _ key: String = "cli"
    ) throws -> String? {
        guard let raw = try patchString(params, key) else { return nil }
        guard ConfigDefaults.validCLIs.contains(raw) else {
            throw RPCError.invalidParams(
                "\(key) must be one of: \(ConfigDefaults.validCLIs.joined(separator: ", "))")
        }
        return raw
    }

    /// Branch prefix for new session branches.
    ///
    /// Validated with `ConfigDefaults.isValidBranchPrefix` rather than a second
    /// copy of the rules — it is the model's own predicate and already has tests
    /// pinning it. Empty is legal there and means "no prefix", so this does not
    /// reject a blank; it only trims, since a prefix with a leading or trailing
    /// space produces a branch name git will refuse at `worktree add` time
    /// (well after the config write looked successful).
    ///
    /// - Returns: `nil` when the key is absent or null.
    /// - Throws: `RPCError.invalidParams` for a prefix git would reject as a ref.
    public static func patchBranchPrefix(
        _ params: [String: JSONValue], _ key: String = "branch_prefix"
    ) throws -> String? {
        guard let raw = try patchString(params, key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ConfigDefaults.isValidBranchPrefix(trimmed) else {
            throw RPCError.invalidParams(
                "\(key) '\(raw)' is not a valid git ref prefix — it must not contain a space, "
              + "any of ~^:?*[\\, '..', '@{', or end in '.'")
        }
        return trimmed
    }

    private static func patchString(
        _ params: [String: JSONValue], _ key: String
    ) throws -> String? {
        guard let value = params[key], value != .null else { return nil }
        guard let string = value.stringValue else {
            throw RPCError.invalidParams("\(key) must be a string")
        }
        return string
    }

    // MARK: - String-list patches

    /// A decoded add/remove/clear patch for one of `ConfigDefaults`' string lists.
    ///
    /// A value type rather than the `((inout [String]) -> Void)?` the `patch*`
    /// family's shape first suggests: everything is validated by the time this
    /// exists, so a closure would be an opaque box around data — and the
    /// `SettingsRPCSupportTests` house style pins every patch helper by comparing
    /// *returned values*, which a closure can't support.
    public struct StringListPatch: Equatable, Sendable {
        public let add: [String]
        public let remove: [String]
        public let clear: Bool

        public init(add: [String] = [], remove: [String] = [], clear: Bool = false) {
            self.add = add
            self.remove = remove
            self.clear = clear
        }

        /// Apply this patch to the stored list.
        ///
        /// Matching is case-INSENSITIVE, matching the *consumers*:
        /// `repoMatchesPatterns` (AppState) lowercases both sides, and
        /// `ignoreReviewLabels` is matched through a lowercased `Set`. So
        /// `Corveil/Crow` and `corveil/crow` filter exactly the same repos — one
        /// entry as far as the product is concerned. An exact-match remove would
        /// answer `{"saved": true}` while the repo stayed excluded, which is the
        /// worst outcome available: a receipt for a write that didn't do the
        /// thing. (The web's × button removes by exact `!==` and its add dedupes
        /// by exact `includes`, so the UI *can* hold two functionally identical
        /// entries; this deliberately does not.)
        ///
        /// Remove runs before add, so `--remove-x foo --add-x foo` re-adds rather
        /// than silently dropping — a caller naming a value in both most
        /// plausibly means "ensure it's there". A dedupe hit keeps the STORED
        /// casing: the caller asked to add, not to re-case, and rewriting would
        /// churn config.json and fire a spurious `configReloaded` in every open
        /// browser.
        public func apply(to list: [String]) -> [String] {
            if clear { return [] }
            var result = list.filter { stored in
                !remove.contains { $0.caseInsensitiveCompare(stored) == .orderedSame }
            }
            for value in add
            where !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                result.append(value)
            }
            return result
        }
    }

    /// Decode one list's `add_<field>` / `remove_<field>` / `clear_<field>` trio.
    ///
    /// - Returns: `nil` when all three are absent or null — "leave this list
    ///   alone", the same contract as every `SettingsRPC.patch*`.
    /// - Throws: `RPCError.invalidParams` when `add`/`remove` isn't an array of
    ///   strings or has no non-blank entry, `clear` isn't a boolean, or `clear`
    ///   is combined with `add`/`remove` for the same list.
    public static func patchStringList(
        _ params: [String: JSONValue], _ field: String
    ) throws -> StringListPatch? {
        let addKey = "add_\(field)"
        let removeKey = "remove_\(field)"
        let clearKey = "clear_\(field)"
        let add = try decodeStringArray(params, addKey)
        let remove = try decodeStringArray(params, removeKey)
        let clear = try SettingsRPC.patchBool(params, clearKey) ?? false
        guard add != nil || remove != nil || clear else { return nil }
        // Exclusive per list, not globally: `clear_exclude_review_repos` plus
        // `add_ignore_review_labels` is a perfectly good call.
        if clear, add != nil || remove != nil {
            throw RPCError.invalidParams(
                "\(clearKey) cannot be combined with \(addKey) or \(removeKey) — clear empties the list.")
        }
        return StringListPatch(add: add ?? [], remove: remove ?? [], clear: clear)
    }

    /// Array-of-strings param: trimmed, blanks dropped, deduped first-seen
    /// (case-insensitively, keeping the first casing), at least one survivor.
    ///
    /// Strict about element type: a bare `compactMap` drops a non-string
    /// element, so a malformed payload applies a *subset* of the request and
    /// still reports success.
    ///
    /// - Returns: `nil` when the key is absent or null.
    private static func decodeStringArray(
        _ params: [String: JSONValue], _ key: String
    ) throws -> [String]? {
        guard let value = params[key], value != .null else { return nil }
        guard let items = value.arrayValue else {
            throw RPCError.invalidParams("\(key) must be an array of strings")
        }
        let strings = items.compactMap(\.stringValue)
        guard strings.count == items.count else {
            throw RPCError.invalidParams("\(key) must contain only strings")
        }
        var seen = Set<String>()
        let cleaned = strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        // An empty or all-blank array is a caller bug: it either means "clear"
        // (which has its own key) or the caller's own list-building produced
        // nothing. Accepting it makes an inert write look successful.
        guard !cleaned.isEmpty else {
            throw RPCError.invalidParams("\(key) must contain at least one non-blank value")
        }
        return cleaned
    }

    // MARK: - Binary overrides

    /// Decode the `binaries` param: an object of tool name → absolute path,
    /// MERGED into the stored map by `mergeBinaries`.
    ///
    /// An **empty-string value removes the key** — the map has no natural unset
    /// sentinel, and `null` already means "leave the whole param alone" in this
    /// patch family, so the blank string carries the delete.
    ///
    /// - Returns: `nil` when the key is absent or null.
    /// - Throws: `RPCError.invalidParams` for a non-object, an empty object, a
    ///   non-string value, a name that isn't a plain filename, the reserved
    ///   `crow` name, or a non-absolute path.
    public static func patchBinaries(
        _ params: [String: JSONValue], _ key: String = "binaries"
    ) throws -> [String: String]? {
        guard let value = params[key], value != .null else { return nil }
        guard let object = value.objectValue else {
            throw RPCError.invalidParams("\(key) must be an object of name -> absolute path")
        }
        // Inert write reporting success, same call as the empty add array.
        guard !object.isEmpty else {
            throw RPCError.invalidParams("\(key) must contain at least one entry")
        }
        var result: [String: String] = [:]
        for (rawName, rawValue) in object {
            guard let path = rawValue.stringValue else {
                throw RPCError.invalidParams(
                    "\(key).\(rawName) must be a string ('' removes the entry)")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            try validateBinaryName(name, rawName: rawName, key: key)
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            // Blank clears; anything else must be absolute. `Scaffolder` checks
            // the target with `isExecutableFile(atPath:)`, which resolves a
            // relative path against the *daemon's* cwd — not the caller's shell,
            // and not stably. `ConfigDefaults.binaries`' own docstring says
            // "Absolute-path overrides".
            //
            // A literal leading `/`, not `NSString.isAbsolutePath`: that property
            // counts `~/bin/corveil` as absolute, but `isExecutableFile(atPath:)`
            // does no tilde expansion, so such a path would simply never resolve
            // and the override would be silently inert. The CLI expands `~`
            // before it gets here; a non-CLI caller gets told to.
            if !trimmed.isEmpty, !trimmed.hasPrefix("/") {
                throw RPCError.invalidParams(
                    "\(key).\(name) must be an absolute path (got '\(trimmed)'); '' removes the entry")
            }
            result[name] = trimmed
        }
        return result
    }

    /// Wrap `ConfigDefaults.isValidBinaryName` with the wire-level messages —
    /// the predicate itself lives on the model so the CLI enforces the same one.
    /// See its docstring for why a blank or path-like name is a real hazard
    /// rather than a tidiness rule.
    private static func validateBinaryName(
        _ name: String, rawName: String, key: String
    ) throws {
        guard !name.isEmpty else {
            throw RPCError.invalidParams("\(key) keys must not be blank")
        }
        guard name != ConfigDefaults.reservedBinaryName else {
            throw RPCError.invalidParams(
                "'\(ConfigDefaults.reservedBinaryName)' is reserved — Scaffolder always points "
              + "{devRoot}/.claude/bin/crow at the running app's own CLI, so an override here is "
              + "silently overwritten on every launch.")
        }
        guard ConfigDefaults.isValidBinaryName(name) else {
            throw RPCError.invalidParams(
                "'\(rawName)' is not a valid binary name — expected a plain name like 'corveil' or 'codex'")
        }
    }

    /// Merge a decoded `binaries` patch into the stored map: a non-empty value
    /// sets, an empty value removes, an absent key is untouched.
    ///
    /// A PATCH, not the whole-map replace `set-config` performs — which matters
    /// because the map is shared by two callers (`AgentKind`-keyed binary
    /// discovery and tool-name-keyed installers), so a replace would drop the
    /// other caller's keys.
    ///
    /// Named and pure on purpose: it is the SINGLE merge implementation, which
    /// is what makes `RPCWebSocketHandler.localOnlyDenial`'s presence-based gate
    /// defensible — the gate deliberately does not call it.
    public static func mergeBinaries(
        _ patch: [String: String], into stored: [String: String]
    ) -> [String: String] {
        var result = stored
        for (name, path) in patch {
            if path.isEmpty {
                result.removeValue(forKey: name)
            } else {
                result[name] = path
            }
        }
        return result
    }

    // MARK: - Response encoding

    /// The whole `ConfigDefaults` subtree, snake_cased.
    ///
    /// Built as an object literal rather than a `JSONEncoder(.convertToSnakeCase)`
    /// round-trip for the reason `SettingsRPC`'s encoders give: it keeps the wire
    /// shape reviewable at a glance and free of any Bool-vs-number coercion
    /// difference between Darwin Foundation and swift-corelibs-foundation.
    ///
    /// All nine fields are echoed even though `defaults-set` writes seven —
    /// `exclude_dirs` and `mirror_claude_mcp_to_codex` have no web editor either,
    /// and hiding them would make `get` a worse answer to "what is my config?".
    /// Carries no credentials, so unlike `get-config` this needs no
    /// `SettingsSecrets.strippedForTransport` pass.
    public static func defaultsJSON(_ defaults: ConfigDefaults) -> JSONValue {
        .object([
            "provider": .string(defaults.provider),
            "cli": .string(defaults.cli),
            "branch_prefix": .string(defaults.branchPrefix),
            "exclude_dirs": .array(defaults.excludeDirs.map { .string($0) }),
            "exclude_review_repos": .array(defaults.excludeReviewRepos.map { .string($0) }),
            "exclude_ticket_repos": .array(defaults.excludeTicketRepos.map { .string($0) }),
            "ignore_review_labels": .array(defaults.ignoreReviewLabels.map { .string($0) }),
            "binaries": .object(defaults.binaries.mapValues { .string($0) }),
            "mirror_claude_mcp_to_codex": .bool(defaults.mirrorClaudeMCPToCodex),
        ])
    }

    /// Whether a defaults change needs a `crowd` restart to take effect.
    ///
    /// Only `binaries` does. Both of its consumers are boot-time:
    /// `CrowDaemon.registerAgents` calls `BinaryOverrides.shared.set(...)` once at
    /// startup, and `LaunchScaffold` hands the same map to `Scaffolder`, which
    /// materializes the `{devRoot}/.claude/bin/<name>` symlinks the tmux PATH
    /// prepend resolves against. A live daemon adopts neither — and nothing
    /// re-scaffolds on a config change, so after a *deletion* the stale symlink
    /// keeps shadowing PATH until the next launch. That makes this load-bearing
    /// rather than advisory.
    ///
    /// Every other field is live: `provider`/`cli` are re-read per repo scan
    /// (`GitManager`), the three board lists are mirrored into `AppState` on each
    /// board tick (`CrowDaemon.applyConfigToAppState`), and `branchPrefix` is
    /// read out of config.json by the `/crow-workspace` skill at use time.
    ///
    /// Old-vs-new rather than "was `binaries` passed", matching
    /// `SettingsRPC.telemetryRestartRequired`: re-setting a path to the value it
    /// already had is a no-op, and reporting a restart for a no-op trains users
    /// to ignore the flag. Takes whole `ConfigDefaults` values so a future
    /// boot-only field is one `||` in one body.
    public static func restartRequired(old: ConfigDefaults, new: ConfigDefaults) -> Bool {
        old.binaries != new.binaries
    }

    /// `gitlab` + `gh`, or `github` + `glab`.
    ///
    /// `GitManager` reads `defaults.provider` and `defaults.cli` as an
    /// independent pair, and the web's Default-provider select has no `cli`
    /// counterpart at all — so an existing config can legitimately already be in
    /// this state, and flipping only the provider from the web has always left
    /// the CLI behind. Advisory, not an error, and deliberately NOT auto-paired:
    /// writing a field the caller didn't name would break the "only what you pass
    /// changes" contract and make the odd-but-legal `--provider gitlab --cli gh`
    /// inexpressible. Computed post-merge, so setting both in one call is clean.
    public static func providerCLIMismatch(provider: String, cli: String) -> Bool {
        (provider == "gitlab" && cli == "gh") || (provider == "github" && cli == "glab")
    }
}
