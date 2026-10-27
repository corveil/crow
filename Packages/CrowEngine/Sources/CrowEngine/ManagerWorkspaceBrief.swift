import CrowCore
import Foundation

/// The starting brief for an extra Manager tagged with a workspace (CROW-1382).
///
/// An untagged Manager is cross-workspace and needs no brief: the devRoot
/// `CLAUDE.md` already tells it how to drive every workspace. A tagged one is
/// meant to work *in* one, so it is told which provider, which repos, and that
/// workspace's `customInstructions` — enough for `/crow-create-ticket` to know
/// where to file without asking.
///
/// It rides the existing one-shot seed path (`createManagerTerminal`'s
/// `initialPrompt`, the same argv delivery Explore uses — CROW-1327), so it is
/// given once at creation and never replayed on Recreate or after a reboot,
/// when the conversation is resumed and already carries it.
enum ManagerWorkspaceBrief {
    /// The brief, or the brief followed by `followUp` when the Manager was
    /// created with a prompt of its own (a Scratch Explore / Ticket brief).
    /// Without one the Manager is told to acknowledge and wait, so seeding
    /// context never makes it start work nobody asked for.
    static func prompt(workspace: WorkspaceInfo, devRoot: String?, followUp: String?) -> String {
        var lines: [String] = []
        lines.append("# Workspace context")
        lines.append("")
        lines.append(
            "This Manager session is tagged with the **\(workspace.name)** workspace. "
            + "Work, tickets and sessions you start belong to it unless the operator says otherwise.")
        lines.append("")
        var provider = "- Code provider: \(workspace.provider)"
        if let host = workspace.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            provider += " (\(host))"
        }
        provider += ", CLI `\(workspace.derivedCLI)`"
        lines.append(provider)
        var tasks = "- Ticket provider: \(workspace.derivedTaskProvider)"
        if workspace.derivedTaskProvider == "jira" {
            if let key = workspace.jiraProjectKey, !key.isEmpty { tasks += ", project \(key)" }
            if let site = workspace.jiraSite, !site.isEmpty { tasks += " on \(site)" }
        }
        lines.append(tasks)
        if !workspace.alwaysInclude.isEmpty {
            lines.append("- Repos: " + workspace.alwaysInclude.map { "`\($0)`" }.joined(separator: ", "))
        }
        if let devRoot {
            let folder = (devRoot as NSString).appendingPathComponent(workspace.name)
            lines.append("- Worktrees live directly under `\(folder)/`")
        }
        lines.append("")
        lines.append(
            "When you file a ticket (for example with `/crow-create-ticket`) or start a "
            + "workspace session, default to this workspace's provider and repos.")
        if let instructions = workspace.customInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            lines.append("")
            lines.append("## Workspace instructions")
            lines.append("")
            lines.append(instructions)
        }
        lines.append("")
        if let followUp = followUp?.trimmingCharacters(in: .whitespacesAndNewlines), !followUp.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append(followUp)
        } else {
            lines.append(
                "Reply with one line confirming the workspace, then wait for the operator's instructions.")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
