import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `agents-*` RPC handlers behind
/// `crow agents` (CROW-811) — `AppConfig.defaultAgentKind` and
/// `AppConfig.agentsByKind`, the Settings → General "Agent" group.
///
/// Same contract as `SettingsRPC` / `NotificationRPC`: no socket, no disk, and
/// crucially no `AgentRegistry`, so every gate below is a pure function of its
/// arguments and unit-testable in isolation. The handler snapshots the registry
/// once per call and passes it in as `[KnownAgent]`.
///
/// `agents-set` is a PATCH: an absent (or explicitly null) param leaves the
/// stored value alone.
public enum AgentsRPC {

    /// One coding agent the daemon knows about, as a plain value.
    ///
    /// Mirrors `AgentRegistry.KnownAgentListing` minus its `isDefault` flag —
    /// deliberately, unlike the `list-agents` response. That flag means the
    /// *registry* default (whichever agent registered first, always Claude Code);
    /// in this payload it would sit inches from `default_agent_kind`, which means
    /// the *configured* default. Two different "defaults" in one object is a bug
    /// factory, so there is only one.
    ///
    /// `available` is a **boot-time snapshot** of whether the binary resolved on
    /// PATH. Known-but-unavailable agents are listed (so an off-PATH harness reads
    /// as "not installed" rather than vanishing — #879) but are not selectable:
    /// `decodeAgentKind` gates on this flag, matching the registry, which never
    /// enters them into its launchable map.
    public struct KnownAgent: Sendable, Equatable {
        public let kind: AgentKind
        public let name: String
        /// The PATH token Crow resolves (`claude`, `agy`, …), for the "install it"
        /// hint. Never the resolved absolute path — the payload must not leak the
        /// daemon host's install locations.
        public let binary: String
        public let available: Bool

        public init(kind: AgentKind, name: String, binary: String, available: Bool) {
            self.kind = kind
            self.name = name
            self.binary = binary
            self.available = available
        }
    }

    // MARK: - Param decoding

    /// The registry gate, as a pure predicate over a caller-supplied snapshot.
    ///
    /// `AgentKind` is an open `RawRepresentable` struct with a total
    /// `init(rawValue:)`, so `"clade-code"` is a perfectly well-formed value.
    /// Writing one into config would persist sessions whose `launchAgent`
    /// silently no-ops on the registry miss (#834) — and unlike `new-session`
    /// there is no later `?? default` to catch it, because the *configured* kind
    /// is trusted as-is at launch time. So this rejects rather than falls back,
    /// and the handler does every decode before touching `mutateConfig` so a
    /// rejection writes nothing at all.
    public static func decodeAgentKind(
        _ raw: String, available: [KnownAgent], label: String
    ) throws -> AgentKind {
        let kind = AgentKind(rawValue: raw)
        let selectable = available.filter(\.available)
        guard selectable.contains(where: { $0.kind == kind }) else {
            // Known but off-PATH gets its own message: "expected one of" would be
            // actively misleading when the agent the caller named is right there
            // in `crow agents list`, just not installed (#879/#880 surface it
            // rather than hiding it). Name the binary and the fix instead.
            if let known = available.first(where: { $0.kind == kind }) {
                throw RPCError.invalidParams(
                    "'\(raw)' is known but not installed (\(label)) — \(known.binary) was not found "
                        + "on PATH when crowd started. Install it and restart crowd to select it.")
            }
            guard !selectable.isEmpty else {
                throw RPCError.invalidParams(
                    "'\(raw)' is not an available agent (\(label)) — no agents are registered on this daemon.")
            }
            let names = selectable.map(\.kind.rawValue).sorted().joined(separator: ", ")
            throw RPCError.invalidParams(
                "'\(raw)' is not an available agent (\(label)). Expected one of: \(names)")
        }
        return kind
    }

    /// - Returns: `nil` when the key is absent or null ("leave unchanged").
    /// - Throws: `RPCError.invalidParams` when present but not a string, or when
    ///   the kind isn't registered on this daemon.
    public static func decodeDefaultAgentKind(
        _ params: [String: JSONValue],
        available: [KnownAgent],
        _ key: String = "default_agent_kind"
    ) throws -> AgentKind? {
        guard let value = params[key], value != .null else { return nil }
        guard let raw = value.stringValue else {
            throw RPCError.invalidParams("\(key) must be a string")
        }
        return try decodeAgentKind(raw, available: available, label: key)
    }

    /// Decode the per-role override map. Keys are `SessionKind` raw values.
    ///
    /// - Returns: empty when the key is absent or null ("leave unchanged").
    /// - Throws: `RPCError.invalidParams` for a non-object, an unknown role name,
    ///   a non-string value, or an unregistered agent kind. A wrong-typed value
    ///   throws rather than being silently dropped — `params[k]?.stringValue`
    ///   would conflate it with "absent" and report success for a value it
    ///   ignored (the bug class `SettingsRPC` documents).
    public static func decodeByKind(
        _ params: [String: JSONValue],
        available: [KnownAgent],
        _ key: String = "by_kind"
    ) throws -> [SessionKind: AgentKind] {
        guard let value = params[key], value != .null else { return [:] }
        guard let object = value.objectValue else {
            throw RPCError.invalidParams("\(key) must be an object of role -> agent kind")
        }
        var result: [SessionKind: AgentKind] = [:]
        for (roleName, kindValue) in object {
            let role = try decodeRole(roleName, context: key)
            guard let raw = kindValue.stringValue else {
                throw RPCError.invalidParams("\(key).\(roleName) must be a string")
            }
            let kind = try decodeAgentKind(raw, available: available, label: "\(key).\(roleName)")
            try validateRoleSupportsAgent(role: role, kind: kind, label: "\(key).\(roleName)")
            result[role] = kind
        }
        return result
    }

    /// Decode the list of roles whose override should be removed.
    ///
    /// - Returns: empty when the key is absent or null. Duplicates collapse — the
    ///   removal is idempotent, and echoing `["work", "work"]` back in an error
    ///   message reads like a bug.
    public static func decodeClear(
        _ params: [String: JSONValue], _ key: String = "clear"
    ) throws -> Set<SessionKind> {
        guard let value = params[key], value != .null else { return [] }
        guard let array = value.arrayValue else {
            throw RPCError.invalidParams("\(key) must be an array of role names")
        }
        var result: Set<SessionKind> = []
        for entry in array {
            guard let raw = entry.stringValue else {
                throw RPCError.invalidParams("\(key) entries must be strings")
            }
            result.insert(try decodeRole(raw, context: key))
        }
        return result
    }

    /// Resolve a role name to a `SessionKind`, listing the four valid names.
    public static func decodeRole(_ raw: String, context: String) throws -> SessionKind {
        guard let role = SessionKind(rawValue: raw) else {
            throw RPCError.invalidParams(
                "'\(raw)' is not a session role (\(context)). Expected one of: \(allRoleNames)")
        }
        return role
    }

    /// Reject pinning a role to an agent that cannot run that kind of session.
    ///
    /// **No agent is role-incapable today** — review-on-Antigravity was the last
    /// such case and its review dispatch landed in #902, so
    /// `shouldRefuseReviewHandoff` is now `false` for every kind and this never
    /// throws. It is retained as the coupling point that keeps `crow agents set`
    /// in lockstep with `handoffAgent`: were a future harness to ship without
    /// review dispatch, gating it in `shouldRefuseReviewHandoff` would refuse it
    /// on both surfaces at once, preventing a "configured but unlaunchable"
    /// outcome — the same failure `decodeAgentKind`'s registry gate prevents,
    /// reached by a different route.
    ///
    /// Delegates to `SessionService.shouldRefuseReviewHandoff`, the predicate
    /// `handoffAgent` already throws on, so the two surfaces cannot drift.
    ///
    /// Scope note: this validates only what the caller is *changing*, not the
    /// resolved outcome of the whole config. Rejecting on resolution would mean
    /// a pre-existing `defaultAgentKind: antigravity` (settable from web
    /// Settings, which does not run this gate) made every later `agents set`
    /// fail — including patches to unrelated roles. A default that resolves
    /// review to a review-incapable agent instead surfaces at launch time, where
    /// `SessionService` already writes an explanatory line into the terminal.
    public static func validateRoleSupportsAgent(
        role: SessionKind, kind: AgentKind, label: String
    ) throws {
        guard SessionService.shouldRefuseReviewHandoff(targetKind: kind, sessionKind: role) else {
            return
        }
        throw RPCError.invalidParams(
            "'\(kind.rawValue)' cannot run \(role.rawValue) sessions (\(label)) — it has no "
                + "review dispatch, so review sessions would be created but never launch an agent. "
                + "Pick a different agent for this role.")
    }

    /// `--clear X` alongside `--X <kind>` is contradictory, not a precedence
    /// puzzle. `applyByKind` deletes then sets, so the set would silently win and
    /// a caller who meant "clear" would get a write they never asked for behind a
    /// success response. Reject instead.
    ///
    /// The handler runs this *before* its "nothing to set" guard: a call carrying
    /// both passes the emptiness check, so checking emptiness first would bury the
    /// real mistake.
    public static func validateNoClearConflict(
        setting: [SessionKind: AgentKind], clearing: Set<SessionKind>
    ) throws {
        let conflicts = clearing.intersection(setting.keys).map(\.rawValue).sorted()
        guard conflicts.isEmpty else {
            throw RPCError.invalidParams(
                "Cannot set and clear the same role in one call: \(conflicts.joined(separator: ", "))")
        }
    }

    // MARK: - Mutation

    /// Apply the decoded patch to `AppConfig.agentsByKind`.
    ///
    /// A cleared role's key is **removed**, never set to null. `agentsByKind` is
    /// `[String: AgentKind]`, `AgentKind` decodes from a single-value String
    /// container, and `AppConfig.init(from:)` decodes the map with `try`, not
    /// `try?` — so one `{"work": null}` makes the **entire** config.json
    /// undecodable. Every workspace, job, gateway and credential goes invisible,
    /// and `mutateConfig` then refuses every later write. The web does
    /// `delete cfg.agentsByKind[key]` for exactly this reason (`web/settings.js`).
    ///
    /// Delete-then-set. The caller has already rejected any overlap, so order
    /// isn't load-bearing — but it is deliberate, so a future caller that drops
    /// the conflict check degrades to "set wins" rather than "clear wins".
    ///
    /// Roles absent from both arguments are untouched: that is the PATCH.
    public static func applyByKind(
        _ stored: inout [String: AgentKind],
        setting: [SessionKind: AgentKind],
        clearing: Set<SessionKind>
    ) {
        for role in clearing { stored.removeValue(forKey: role.rawValue) }
        for (role, kind) in setting { stored[role.rawValue] = kind }
    }

    // MARK: - Response encoding

    /// Canonical `agents` payload: what this daemon can launch, what the user
    /// configured, and what each role actually resolves to.
    ///
    /// `effective` goes through `AppConfig.agentKind(for:)` — the same call the
    /// session-creation path makes — so it can never drift from what launches.
    ///
    /// `by_kind` echoes the stored map **verbatim**, including a hand-edited key
    /// that isn't a real role (`{"deploy": "codex"}` decodes fine; the map's keys
    /// are unvalidated `String`s). The resolver ignores such a key, so hiding it
    /// would hide exactly the drift the user needs to see: it shows up in
    /// `by_kind`, is absent from `effective`, and that difference is the tell.
    /// Silently stripping it would also delete user data, since `mutateConfig`
    /// rewrites the whole file.
    ///
    /// `known` lists every agent the daemon knows about, each with an `available`
    /// flag, rather than silently omitting off-PATH ones — the same
    /// surface-but-disable contract #879/#880 gave the web pickers, so `crow
    /// agents list` and Settings show the same roster. Only `available: true`
    /// rows are selectable by `agents set`. (Named `known`, not `available`,
    /// because it no longer *is* the available set — that distinction is now the
    /// per-row flag.)
    ///
    /// - Parameter configReadable: false when config.json exists but couldn't be
    ///   decoded, so the caller isn't shown invented defaults as fact.
    public static func agentsJSON(
        _ config: AppConfig,
        available: [KnownAgent],
        configReadable: Bool = true
    ) -> JSONValue {
        var byKind: [String: JSONValue] = [:]
        for (role, kind) in config.agentsByKind { byKind[role] = .string(kind.rawValue) }

        var effective: [String: JSONValue] = [:]
        for role in SessionKind.allCases {
            effective[role.rawValue] = .string(config.agentKind(for: role).rawValue)
        }

        return .object([
            "known": .array(available.map {
                .object([
                    "kind": .string($0.kind.rawValue),
                    "name": .string($0.name),
                    "binary": .string($0.binary),
                    "available": .bool($0.available),
                ])
            }),
            "default_agent_kind": .string(config.defaultAgentKind.rawValue),
            "by_kind": .object(byKind),
            "effective": .object(effective),
            "config_readable": .bool(configReadable),
        ])
    }

    /// Every role raw value, for error messages.
    private static var allRoleNames: String {
        SessionKind.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
