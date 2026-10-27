import CrowCore
import CrowIPC
import Foundation

/// Which agent and workspace a Scratch item carries, and which Manager
/// Explore / Ticket launch for it (CROW-1387). Pure: config and sessions in,
/// decision out, so the resolution order is unit-testable without a daemon.
extension TodoRPC {
    /// Decode an `agent_kind` param. Nil when absent, null or blank; an
    /// unregistered kind is rejected so an item can never carry an agent no
    /// Manager can launch. `isRegistered` defaults to the live `AgentRegistry`.
    public static func decodeAgentKind(
        _ value: JSONValue?,
        isRegistered: (AgentKind) -> Bool = { AgentRegistry.shared.registeredKind($0) != nil }
    ) throws -> AgentKind? {
        guard let value, value != .null else { return nil }
        guard let raw = value.stringValue else {
            throw RPCError.invalidParams("agent_kind must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let kind = AgentKind(rawValue: trimmed)
        guard isRegistered(kind) else {
            throw RPCError.invalidParams("Unknown agent '\(trimmed)' — `crow agents list` shows the installed ones")
        }
        return kind
    }

    /// The workspace and agent a new item is captured with.
    public struct CaptureTarget: Equatable, Sendable {
        public var workspace: String
        public var agentKind: AgentKind
    }

    /// Resolve what `todo-add` stores. Each value is resolved on its own, in
    /// this order:
    /// 1. the explicit param (`workspace` / `agent_kind`);
    /// 2. the creating session, when it is a Manager tagged with a workspace
    ///    that still exists: its workspace and its agent;
    /// 3. the defaults: `defaults.managerWorkspace`, and
    ///    `agentsByKind.manager ?? defaultAgentKind`.
    ///
    /// The workspace goes through ``ManagerWorkspaceTag/resolve(requested:context:config:)``,
    /// the same rule a new extra Manager uses (CROW-1386), so an item always
    /// names a workspace its Explore / Ticket Manager can be tagged with.
    ///
    /// - Throws: `RPCError.invalidParams` when an explicit value is unknown, or
    ///   when no workspace resolves at all. A stale default is not guessed past.
    public static func captureTarget(
        params: [String: JSONValue],
        creator: Session?,
        config: AppConfig,
        isRegistered: (AgentKind) -> Bool = { AgentRegistry.shared.registeredKind($0) != nil }
    ) throws -> CaptureTarget {
        let creatorWorkspace = creator.flatMap { taggedWorkspace(of: $0, config: config) }
        let workspace = try ManagerWorkspaceTag.resolve(
            requested: try workspaceParam(params["workspace"]),
            context: creatorWorkspace?.id.uuidString, config: config)
        let agentKind = try decodeAgentKind(params["agent_kind"], isRegistered: isRegistered)
            ?? (creatorWorkspace != nil ? creator?.agentKind : nil)
            ?? config.agentKind(for: .manager)
        return CaptureTarget(workspace: workspace.workspaceName, agentKind: agentKind)
    }

    /// A `workspace` param as a raw string, nil when absent, null or blank.
    static func workspaceParam(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let raw = value.stringValue else {
            throw RPCError.invalidParams("workspace must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The workspace a session is tagged with, when it is an extra Manager
    /// whose tag still names a configured workspace.
    static func taggedWorkspace(of session: Session, config: AppConfig) -> WorkspaceInfo? {
        guard let id = session.managerWorkspaceTag else { return nil }
        return config.workspaces.first(where: { $0.id == id })
    }

    /// The Manager Explore / Ticket launch for an item.
    public struct LaunchTarget: Equatable, Sendable {
        /// The workspace the Manager is (or would be) tagged with. Always set
        /// for a new Manager; nil only when re-seeding a live one and nothing
        /// resolves.
        public var workspace: WorkspaceInfo?
        /// Nil means the configured Manager agent.
        public var agentKind: AgentKind?
    }

    /// Resolve the Manager launch for `item`. `agent_kind` and `workspace`
    /// params override the item's values for this launch only; the item is
    /// not changed. The workspace follows ``ManagerWorkspaceTag`` (CROW-1386):
    /// the override, else the item's workspace, else
    /// `defaults.managerWorkspace`.
    ///
    /// - Parameter newManager: true when a Manager will be created, so a
    ///   workspace is required and a miss throws. False when re-seeding the
    ///   item's live Manager: nothing is created, so a miss is just nil.
    public static func launchTarget(
        for item: TodoItem,
        params: [String: JSONValue],
        config: AppConfig,
        newManager: Bool = true,
        isRegistered: (AgentKind) -> Bool = { AgentRegistry.shared.registeredKind($0) != nil }
    ) throws -> LaunchTarget {
        let agentKind = try decodeAgentKind(params["agent_kind"], isRegistered: isRegistered)
            ?? item.agentKind
        let requested = try workspaceParam(params["workspace"])
        let decision: ManagerWorkspaceTag.Decision?
        if newManager {
            decision = try ManagerWorkspaceTag.resolve(
                requested: requested, context: item.workspace, config: config)
        } else {
            // An explicit but unknown override is still the caller's mistake.
            if let requested { _ = try WorkspaceRPC.resolveIndex(requested, in: config) }
            decision = try? ManagerWorkspaceTag.resolve(
                requested: requested, context: item.workspace, config: config)
        }
        let workspace = decision.flatMap { d in config.workspaces.first { $0.id == d.workspaceID } }
        return LaunchTarget(workspace: workspace, agentKind: agentKind)
    }

    /// The warning for re-seeding an item's live Manager when its workspace
    /// tag differs from the launch workspace. The brief is still delivered and
    /// the Manager is never re-tagged (tags are immutable — CROW-1382). Nil
    /// when they match, or when the launch has no workspace to compare.
    public static func existingManagerWarning(
        managerTag: UUID?, launch: WorkspaceInfo?, config: AppConfig
    ) -> String? {
        guard let launch, managerTag != launch.id else { return nil }
        let current = managerTag.flatMap { id in config.workspaces.first(where: { $0.id == id })?.name }
        let tagged = current.map { "tagged with '\($0)'" } ?? "not tagged with a workspace"
        return "The brief went to this item's existing Manager, which is \(tagged), not '\(launch.name)'. "
            + "Managers are never re-tagged; delete that Manager and run this again for one in '\(launch.name)'."
    }

    /// The lines that tell a filing agent where the ticket goes (CROW-1387):
    /// the workspace's ticket provider and its repos, so it never guesses.
    static func ticketDestination(_ workspace: WorkspaceInfo) -> [String] {
        var lines: [String] = []
        let provider = workspace.derivedTaskProvider
        if provider == "jira" {
            var jira = "File it in Jira"
            if let key = workspace.jiraProjectKey, !key.isEmpty { jira += ", project \(key)" }
            if let site = workspace.jiraSite, !site.isEmpty { jira += " on \(site)" }
            lines.append(jira + ", for the **\(workspace.name)** workspace.")
        } else {
            lines.append(
                "File it with `\(provider == "gitlab" ? "glab issue create" : "gh issue create")` "
                + "in the **\(workspace.name)** workspace's \(provider) provider.")
        }
        if provider == "jira" {
            if !workspace.alwaysInclude.isEmpty {
                let repos = workspace.alwaysInclude.map { "`\($0)`" }.joined(separator: ", ")
                lines.append("The code lives in: \(repos).")
            }
        } else if workspace.alwaysInclude.isEmpty {
            lines.append("Pick the \(workspace.name) repo that owns the work. Do not file it outside this workspace.")
        } else {
            let repos = workspace.alwaysInclude.map { "`\($0)`" }.joined(separator: ", ")
            lines.append("The repo is one of: \(repos). Pick the one that owns the work; do not file anywhere else.")
        }
        return lines
    }
}
