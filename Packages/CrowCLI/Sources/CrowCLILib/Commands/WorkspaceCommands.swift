import ArgumentParser
import CrowIPC
import Foundation

/// Parent command for workspace management: `crow workspace <subcommand>`.
///
/// Reads and writes `AppConfig.workspaces` — the same list the web
/// Settings → Workspaces tab edits — over the daemon's RPC socket, so the change
/// lands under the shared config lock and an open web tab picks it up within a
/// couple of seconds (CROW-809).
///
/// The per-workspace **AI gateway** is deliberately not here: it holds
/// credentials and is local-only, so it stays with `crow gateway`. These verbs
/// preserve a workspace's stored gateway across every edit and report only
/// whether one is set.
public struct Workspace: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Manage workspaces (Settings → Workspaces)",
        discussion: """
        A workspace maps to a folder under the dev root and decides which forge \
        its repos live on, where its tickets come from, and what extra context \
        its sessions get. --workspace accepts a name (case-insensitive) or a \
        workspace UUID.

        `add` and `edit` take the same field flags. On `edit` only the flags you \
        pass change; an optional scalar clears with an empty string \
        (--host ""), and a list or map clears with its --clear-* flag.
        """,
        subcommands: [
            WorkspaceList.self,
            WorkspaceGet.self,
            WorkspaceAdd.self,
            WorkspaceEdit.self,
            WorkspaceRemove.self,
        ]
    )

    public init() {}
}

public struct WorkspaceList: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List every configured workspace")

    public init() {}

    public func run() throws {
        let result = try rpc("workspace-list")
        printJSON(result)
        // `config_readable: false` means config.json exists but wouldn't decode,
        // so an empty list is the fallback rather than the truth. Saying so on
        // stderr keeps stdout pure JSON.
        if result["config_readable"]?.boolValue == false {
            warn("config.json could not be decoded — this list is a default, not your configuration.")
        }
    }
}

public struct WorkspaceGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show one workspace's full configuration")

    @Option(name: .long, help: "Workspace name or UUID") var workspace: String

    public init() {}

    public func validate() throws {
        guard !workspace.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--workspace must not be blank.")
        }
    }

    public func run() throws {
        let result = try rpc("workspace-get", params: ["workspace": .string(workspace)])
        printJSON(result)
    }
}

public struct WorkspaceAdd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a workspace",
        discussion: """
        Only --name is required; every other field takes its documented default \
        and can be set later with `crow workspace edit`. The name becomes a \
        directory under the dev root, so it cannot contain / or :, cannot be \
        "." or "..", and must not collide with an existing workspace \
        (case-insensitively).

        Creating a workspace does not create its directory — the daemon \
        scaffolds it on next launch.
        """
    )

    @Option(name: .long, help: "Workspace name (becomes a folder under the dev root)")
    var name: String
    @OptionGroup var fields: WorkspaceFieldArgs

    public init() {}

    public func validate() throws {
        // Shape only. Uniqueness needs the config, which lives server-side, so
        // that half of `WorkspaceInfo.validateName` runs there.
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--name must not be blank.")
        }
        try fields.validate()
    }

    public func run() throws {
        var params = try fields.paramsJSON()
        params["name"] = .string(name)
        let result = try rpc("workspace-add", params: params)
        printJSON(result)
    }
}

public struct WorkspaceEdit: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Change fields on an existing workspace",
        discussion: """
        Only the provided flags change. A repeatable list flag replaces the \
        whole list rather than appending, matching `crow job edit`; use the \
        matching --clear-* flag to empty one. The --jira-status-* flags patch \
        individually — each sets one mapping and leaves the other four alone.

        Renaming is guarded. Sessions are tied to a workspace only by their \
        worktree living under {devRoot}/{workspace}/, and jobs only by the \
        workspace name string, so a rename silently orphans both — it does not \
        move any directory. --force renames anyway and reports the counts.

        An edit whose values already hold is reported as "saved": false and \
        skips the write, so re-running the same command doesn't churn \
        config.json.
        """
    )

    @Option(name: .long, help: "Workspace name or UUID") var workspace: String
    @Option(name: .long, help: "New workspace name (see the rename guard above)")
    var name: String?
    @OptionGroup var fields: WorkspaceFieldArgs
    @Flag(name: .long, help: "Rename even when sessions or jobs reference this workspace")
    var force: Bool = false

    public init() {}

    public func validate() throws {
        guard !workspace.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--workspace must not be blank.")
        }
        if let name, name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--name must not be blank.")
        }
        guard name != nil || fields.hasAnyField else {
            throw ValidationError("Nothing to edit — provide at least one field flag.")
        }
        try fields.validate()
    }

    public func run() throws {
        var params = try fields.paramsJSON()
        params["workspace"] = .string(workspace)
        if let name { params["name"] = .string(name) }
        if force { params["force"] = .bool(true) }
        let result = try rpc("workspace-edit", params: params)
        printJSON(result)
        if result["saved"]?.boolValue == false {
            warn("no field changed — config.json was left untouched.")
        }
        let orphaned = (result["orphaned_sessions"]?.intValue ?? 0)
            + (result["orphaned_jobs"]?.intValue ?? 0)
        if orphaned > 0 {
            warn("renamed with --force: \(result["orphaned_sessions"]?.intValue ?? 0) session(s) and \(result["orphaned_jobs"]?.intValue ?? 0) job(s) still reference the old name.")
        }
    }
}

public struct WorkspaceRemove: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a workspace from the configuration",
        discussion: """
        Removes the config entry only. The workspace directory under the dev \
        root, its worktrees, and its branches are left on disk — same as the \
        web UI. Any AI gateway stored for this workspace is discarded with it, \
        and there is no undo.

        Refuses when sessions or jobs still reference the workspace; --force \
        removes it anyway.
        """
    )

    @Option(name: .long, help: "Workspace name or UUID") var workspace: String
    @Flag(name: .long, help: "Remove even when sessions or jobs reference this workspace")
    var force: Bool = false

    public init() {}

    public func validate() throws {
        guard !workspace.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--workspace must not be blank.")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["workspace": .string(workspace)]
        if force { params["force"] = .bool(true) }
        let result = try rpc("workspace-remove", params: params)
        printJSON(result)
        if result["gateway_discarded"]?.boolValue == true {
            warn("the workspace's AI gateway was discarded — re-add it with `crow gateway set` if you recreate the workspace.")
        }
    }
}
