import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding and response encoding for the `agents-*` RPC handlers behind
/// `crow agents` (CROW-811).
@Suite("Agents RPC support")
struct AgentsRPCSupportTests {

    /// A registry snapshot, supplied by hand — the whole point of threading
    /// `[KnownAgent]` through instead of reaching for `AgentRegistry.shared`,
    /// which is process-global and seeded by whichever tests ran first.
    private let available: [AgentsRPC.KnownAgent] = [
        .init(kind: .claudeCode, name: "Claude Code", binary: "claude", available: true),
        .init(kind: .codex, name: "OpenAI Codex", binary: "codex", available: true),
    ]

    /// The post-#880 case: a known agent whose binary wasn't on PATH at boot. It
    /// is listed for discoverability but must not be selectable.
    private let withUnavailable: [AgentsRPC.KnownAgent] = [
        .init(kind: .claudeCode, name: "Claude Code", binary: "claude", available: true),
        .init(kind: .codex, name: "OpenAI Codex", binary: "codex", available: true),
        .init(kind: .cursor, name: "Cursor", binary: "agent", available: false),
    ]

    // MARK: - decodeAgentKind (the registry gate)

    @Test func decodeAgentKindAcceptsARegisteredKind() throws {
        #expect(try AgentsRPC.decodeAgentKind("codex", available: available, label: "x") == .codex)
    }

    /// `AgentKind(rawValue:)` is total, so this gate is the only thing between a
    /// typo and a config that persists unlaunchable sessions.
    @Test func decodeAgentKindRejectsAnUnavailableKindAndNamesTheAlternatives() {
        do {
            _ = try AgentsRPC.decodeAgentKind("clade-code", available: available, label: "x")
            Issue.record("expected a rejection")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("clade-code"))
            #expect(message.contains("claude-code"))
            #expect(message.contains("codex"))
        }
    }

    /// A daemon with nothing registered would otherwise say "Expected one of: ",
    /// which reads like a bug rather than a diagnosis.
    @Test func decodeAgentKindSaysSoWhenNothingIsRegistered() {
        do {
            _ = try AgentsRPC.decodeAgentKind("codex", available: [], label: "x")
            Issue.record("expected a rejection")
        } catch {
            #expect(String(describing: error).contains("no agents are registered"))
        }
    }

    // MARK: - decodeDefaultAgentKind

    /// The PATCH contract: only a genuinely provided value changes anything.
    @Test func decodeDefaultAgentKindReturnsNilForAbsentAndNull() throws {
        #expect(try AgentsRPC.decodeDefaultAgentKind([:], available: available) == nil)
        #expect(
            try AgentsRPC.decodeDefaultAgentKind(
                ["default_agent_kind": .null], available: available) == nil)
    }

    @Test func decodeDefaultAgentKindAcceptsARegisteredKind() throws {
        let params: [String: JSONValue] = ["default_agent_kind": .string("codex")]
        #expect(try AgentsRPC.decodeDefaultAgentKind(params, available: available) == .codex)
    }

    /// A wrong-typed value must throw rather than be treated as absent — the
    /// `params[key]?.stringValue` idiom would report success for a dropped write.
    @Test func decodeDefaultAgentKindRejectsWrongTypes() {
        let bad: [JSONValue] = [.bool(true), .int(1), .double(1.0), .object([:]), .array([])]
        for value in bad {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try AgentsRPC.decodeDefaultAgentKind(
                    ["default_agent_kind": value], available: available)
            }
        }
    }

    @Test func decodeDefaultAgentKindRejectsAnUnavailableKind() {
        #expect(throws: RPCError.self) {
            _ = try AgentsRPC.decodeDefaultAgentKind(
                ["default_agent_kind": .string("cursor")], available: available)
        }
    }

    // MARK: - decodeByKind

    @Test func decodeByKindReturnsEmptyForAbsentAndNull() throws {
        #expect(try AgentsRPC.decodeByKind([:], available: available).isEmpty)
        #expect(try AgentsRPC.decodeByKind(["by_kind": .null], available: available).isEmpty)
    }

    @Test func decodeByKindAcceptsEveryRole() throws {
        for role in SessionKind.allCases {
            let params: [String: JSONValue] = [
                "by_kind": .object([role.rawValue: .string("codex")])
            ]
            #expect(try AgentsRPC.decodeByKind(params, available: available) == [role: .codex])
        }
    }

    @Test func decodeByKindRejectsANonObject() {
        for value: JSONValue in [.string("codex"), .array([]), .int(1), .bool(true)] {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try AgentsRPC.decodeByKind(["by_kind": value], available: available)
            }
        }
    }

    @Test func decodeByKindRejectsAnUnknownRoleAndNamesTheValidOnes() {
        do {
            _ = try AgentsRPC.decodeByKind(
                ["by_kind": .object(["deploy": .string("codex")])], available: available)
            Issue.record("expected a rejection")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("deploy"))
            for role in SessionKind.allCases { #expect(message.contains(role.rawValue)) }
        }
    }

    @Test func decodeByKindRejectsANonStringValue() {
        #expect(throws: RPCError.self) {
            _ = try AgentsRPC.decodeByKind(
                ["by_kind": .object(["work": .bool(true)])], available: available)
        }
    }

    @Test func decodeByKindRejectsAnUnavailableKindForARole() {
        #expect(throws: RPCError.self) {
            _ = try AgentsRPC.decodeByKind(
                ["by_kind": .object(["work": .string("cursor")])], available: available)
        }
    }

    // MARK: - Role/agent capability gate (#886 review)

    /// A registry snapshot that includes Antigravity, so the capability gate is
    /// reached rather than short-circuited by the availability gate. Injected as
    /// a value — deliberately not registered in `AgentRegistry.shared`, which is
    /// process-wide and shared with every parallel suite.
    private var availableWithAntigravity: [AgentsRPC.KnownAgent] {
        // `available: true` on purpose — the capability gate must reject review
        // even for an Antigravity that IS installed. Marking it unavailable would
        // pass the test for the wrong reason (the availability gate firing first).
        available + [.init(kind: .antigravity, name: "Antigravity", binary: "agy", available: true)]
    }

    /// Review-on-Antigravity would create sessions that persist the kind and then
    /// never launch (`autoLaunchCommand(.review)` → nil). Refusing here matches
    /// `handoffAgent`, which already throws `reviewNotSupported` for the same
    /// pair — it would be incoherent to refuse the handoff but configure it.
    @Test func decodeByKindRejectsAnAgentThatCannotRunTheRole() {
        do {
            _ = try AgentsRPC.decodeByKind(
                ["by_kind": .object(["review": .string("antigravity")])],
                available: availableWithAntigravity)
            Issue.record("expected a rejection")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("antigravity"))
            #expect(message.contains("review"))
            // Must not be mistaken for the availability gate — it *is* available.
            #expect(!message.contains("Expected one of"))
        }
    }

    /// The gate is per-role, not a blanket ban: Antigravity runs work and job
    /// sessions fine, and only `.review` is unsupported.
    @Test func decodeByKindAllowsAntigravityForRolesItCanRun() throws {
        for role in SessionKind.allCases where role != .review {
            let params: [String: JSONValue] = [
                "by_kind": .object([role.rawValue: .string("antigravity")])
            ]
            #expect(
                try AgentsRPC.decodeByKind(params, available: availableWithAntigravity)
                    == [role: .antigravity])
        }
    }

    /// …and review itself stays open to every other agent.
    @Test func decodeByKindAllowsReviewCapableAgents() throws {
        for kind in [AgentKind.claudeCode, .codex] {
            let params: [String: JSONValue] = [
                "by_kind": .object(["review": .string(kind.rawValue)])
            ]
            #expect(
                try AgentsRPC.decodeByKind(params, available: availableWithAntigravity)
                    == [.review: kind])
        }
    }

    @Test func validateRoleSupportsAgentMirrorsTheHandoffPredicate() throws {
        // Exactly the pair `handoffAgent` refuses, and nothing else.
        for role in SessionKind.allCases {
            for kind in [AgentKind.claudeCode, .codex, .cursor, .openCode, .antigravity] {
                let refused = SessionService.shouldRefuseReviewHandoff(
                    targetKind: kind, sessionKind: role)
                if refused {
                    #expect(throws: RPCError.self) {
                        try AgentsRPC.validateRoleSupportsAgent(role: role, kind: kind, label: "x")
                    }
                } else {
                    try AgentsRPC.validateRoleSupportsAgent(role: role, kind: kind, label: "x")
                }
            }
        }
    }

    /// The gate deliberately does NOT fire on `default_agent_kind`. Validating the
    /// *resolved* outcome would make a pre-existing default (settable from web
    /// Settings, which doesn't run this gate) fail every later patch — including
    /// ones touching unrelated roles.
    @Test func defaultAgentKindIsNotSubjectToTheRoleCapabilityGate() throws {
        let params: [String: JSONValue] = ["default_agent_kind": .string("antigravity")]
        #expect(
            try AgentsRPC.decodeDefaultAgentKind(params, available: availableWithAntigravity)
                == .antigravity)
    }

    // MARK: - decodeClear

    @Test func decodeClearReturnsEmptyForAbsentAndNull() throws {
        #expect(try AgentsRPC.decodeClear([:]).isEmpty)
        #expect(try AgentsRPC.decodeClear(["clear": .null]).isEmpty)
    }

    @Test func decodeClearAcceptsEveryRoleAndDedupes() throws {
        let all: JSONValue = .array(SessionKind.allCases.map { .string($0.rawValue) })
        #expect(try AgentsRPC.decodeClear(["clear": all]) == Set(SessionKind.allCases))
        #expect(
            try AgentsRPC.decodeClear(["clear": .array([.string("work"), .string("work")])])
                == [.work])
    }

    @Test func decodeClearRejectsNonArrayAndNonStringEntries() {
        #expect(throws: RPCError.self) { _ = try AgentsRPC.decodeClear(["clear": .string("work")]) }
        #expect(throws: RPCError.self) { _ = try AgentsRPC.decodeClear(["clear": .array([.int(1)])]) }
    }

    @Test func decodeClearRejectsAnUnknownRole() {
        #expect(throws: RPCError.self) {
            _ = try AgentsRPC.decodeClear(["clear": .array([.string("deploy")])])
        }
    }

    // MARK: - validateNoClearConflict

    @Test func validateNoClearConflictRejectsOverlapAndNamesTheRole() {
        do {
            try AgentsRPC.validateNoClearConflict(setting: [.review: .codex], clearing: [.review])
            Issue.record("expected a rejection")
        } catch {
            #expect(String(describing: error).contains("review"))
        }
    }

    @Test func validateNoClearConflictAllowsDisjointRoles() throws {
        try AgentsRPC.validateNoClearConflict(setting: [.work: .codex], clearing: [.review])
    }

    // MARK: - applyByKind

    /// The load-bearing behaviour of the whole ticket. A cleared role's key must be
    /// GONE, not present-and-null: `[String: AgentKind]` cannot decode a JSON null,
    /// and `AppConfig.init(from:)` decodes this map with `try`, so one null value
    /// makes the entire config.json undecodable.
    @Test func applyByKindDeletesClearedRolesRatherThanNullingThem() {
        var stored: [String: AgentKind] = ["work": .codex, "review": .claudeCode]
        AgentsRPC.applyByKind(&stored, setting: [:], clearing: [.review])
        #expect(!stored.keys.contains("review"))
        #expect(stored == ["work": .codex])
    }

    /// PATCH semantics at the pure layer: an unmentioned role keeps its value.
    @Test func applyByKindLeavesUnmentionedRolesAlone() {
        var stored: [String: AgentKind] = ["review": .codex]
        AgentsRPC.applyByKind(&stored, setting: [.work: .claudeCode], clearing: [])
        #expect(stored == ["review": .codex, "work": .claudeCode])
    }

    @Test func applyByKindClearingAnAbsentRoleIsANoOp() {
        var stored: [String: AgentKind] = ["work": .codex]
        AgentsRPC.applyByKind(&stored, setting: [:], clearing: [.manager])
        #expect(stored == ["work": .codex])
    }

    // MARK: - agentsJSON

    @Test func agentsJSONReportsEffectiveResolutionPerRole() {
        var config = AppConfig()
        config.defaultAgentKind = .claudeCode
        config.agentsByKind = ["review": .codex]

        let json = AgentsRPC.agentsJSON(config, available: available).objectValue
        #expect(json?["default_agent_kind"] == .string("claude-code"))
        #expect(json?["by_kind"] == .object(["review": .string("codex")]))
        #expect(json?["effective"] == .object([
            "work": .string("claude-code"),
            "review": .string("codex"),
            "job": .string("claude-code"),
            "manager": .string("claude-code"),
            "workerRun": .string("claude-code"),
        ]))
        #expect(json?["config_readable"] == .bool(true))
    }

    /// Pins the decision that a `known` row carries no `default` field. The older
    /// `list-agents` has one meaning the *registry* default; here it would sit
    /// beside `default_agent_kind`, the *configured* default, and be misread.
    @Test func agentsJSONKnownEntriesCarryKindNameBinaryAndAvailability() {
        let json = AgentsRPC.agentsJSON(AppConfig(), available: available).objectValue
        let entries = json?["known"]?.arrayValue ?? []
        #expect(entries.count == 2)
        for entry in entries {
            #expect(Set(entry.objectValue?.keys ?? [:].keys)
                == ["kind", "name", "binary", "available"])
        }
        #expect(entries.first?.objectValue?["kind"] == .string("claude-code"))
        #expect(entries.first?.objectValue?["name"] == .string("Claude Code"))
        #expect(entries.first?.objectValue?["binary"] == .string("claude"))
    }

    /// #879/#880's surface-but-disable contract, mirrored on the CLI: an off-PATH
    /// agent is *listed* (so it reads as "not installed" rather than vanishing)
    /// but flagged unavailable.
    @Test func agentsJSONListsKnownButUnavailableAgents() {
        let json = AgentsRPC.agentsJSON(AppConfig(), available: withUnavailable).objectValue
        let entries = json?["known"]?.arrayValue ?? []
        #expect(entries.count == 3)
        let cursor = entries.first { $0.objectValue?["kind"] == .string("cursor") }
        #expect(cursor?.objectValue?["available"] == .bool(false))
        #expect(cursor?.objectValue?["binary"] == .string("agent"))
    }

    /// …and listing it must not make it selectable — the launch gate is the
    /// per-row flag, matching the registry, which never enters an unavailable
    /// agent into its launchable map.
    @Test func aKnownButUnavailableAgentIsNotSelectable() {
        for params: [String: JSONValue] in [
            ["default_agent_kind": .string("cursor")],
            ["by_kind": .object(["work": .string("cursor")])],
        ] {
            #expect(throws: RPCError.self, "cursor is listed but not installed") {
                _ = try AgentsRPC.decodeDefaultAgentKind(params, available: withUnavailable)
                _ = try AgentsRPC.decodeByKind(params, available: withUnavailable)
            }
        }
    }

    /// The rejection names the binary and the fix rather than "expected one of",
    /// which would be actively confusing when the agent IS in `crow agents list`.
    @Test func theNotInstalledRejectionNamesTheBinary() {
        do {
            _ = try AgentsRPC.decodeAgentKind("cursor", available: withUnavailable, label: "x")
            Issue.record("expected a rejection")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("known but not installed"))
            #expect(message.contains("agent"))  // the PATH token
            #expect(!message.contains("Expected one of"))
        }
    }

    /// A hand-edited key that isn't a real role decodes fine (the map's keys are
    /// unvalidated Strings) and the resolver ignores it. Echoing it in `by_kind`
    /// while omitting it from `effective` is what makes that drift visible.
    @Test func agentsJSONEchoesAnUnknownStoredRoleButOmitsItFromEffective() {
        var config = AppConfig()
        config.agentsByKind = ["deploy": .codex]

        let json = AgentsRPC.agentsJSON(config, available: available).objectValue
        #expect(json?["by_kind"] == .object(["deploy": .string("codex")]))
        #expect(json?["effective"]?.objectValue?["deploy"] == nil)
        #expect(json?["effective"]?.objectValue?.count == SessionKind.allCases.count)
    }

    @Test func agentsJSONReportsConfigUnreadable() {
        let json = AgentsRPC.agentsJSON(
            AppConfig(), available: available, configReadable: false
        ).objectValue
        #expect(json?["config_readable"] == .bool(false))
    }

    @Test func agentsJSONHandlesAnEmptyRegistry() {
        let json = AgentsRPC.agentsJSON(AppConfig(), available: []).objectValue
        #expect(json?["known"] == .array([]))
        // Resolution is still reported: the config says what it says regardless of
        // what this daemon happens to have found on PATH.
        #expect(json?["effective"]?.objectValue?.count == SessionKind.allCases.count)
    }
}
