import Foundation
import CrowCore

/// Assigned-issue JSON parsers for Jira work items.
///
/// Extracted from `JiraTaskBackend` (CROW-1270). Symbols stay on
/// `JiraTaskBackend` via this extension so `@testable` tests keep
/// `JiraTaskBackend.firstInt` / `ticketStatus(forJiraName:)` /
/// `parseAssigned` and so `listAssigned` / `fetchTask` / `createTask` keep
/// calling the same statics. JQL, REST vs `acli` selection, `AssignedIssue`
/// field meaning, closed-total badge math, status-map inverse, and `acli`
/// argv are unchanged.
///
/// REST `JiraSearchClient` / `JiraTransitionClient` stay in CrowCore; this
/// extension only maps already-unwrapped issue dicts (and `acli` stdout)
/// into `AssignedIssue` / `TicketInfo`. `jiraStatusName(for:)` stays on
/// the adapter — it is the write path used by `setTaskStatus` / `closeTask`.

extension JiraTaskBackend {
    // MARK: - JSON parsing

    /// acli emits a JSON array of work items even for single-item `view`. Return
    /// the `fields` dict of the first element (or of a bare object, defensively).
    static func firstFields(_ output: String) -> [String: Any]? {
        guard let obj = firstObject(output) else { return nil }
        return obj["fields"] as? [String: Any]
    }

    static func firstKey(_ output: String) -> String? {
        firstObject(output)?["key"] as? String
    }

    private static func firstObject(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = json as? [[String: Any]] { return arr.first }
        if let obj = json as? [String: Any] { return obj }
        return nil
    }

    /// Priority name from a work item's `fields` dict (`fields.priority.name`).
    /// Nil-safe: absent for GitHub-style payloads, pre-#696 fixtures, and Jira
    /// projects without a priority field.
    static func priorityName(_ fields: [String: Any]?) -> String? {
        (fields?["priority"] as? [String: Any])?["name"] as? String
    }

    /// Epic/parent link from a work item's `fields` dict (#696). On Jira Cloud
    /// `parent` is the unified field for both team- and company-managed
    /// projects (classic "Epic Link" customfields were migrated into it);
    /// Server/DC classic epic links don't surface here and degrade to nil.
    static func parentInfo(_ fields: [String: Any]?) -> (key: String?, summary: String?) {
        guard let parent = fields?["parent"] as? [String: Any] else { return (nil, nil) }
        let summary = (parent["fields"] as? [String: Any])?["summary"] as? String
        return (parent["key"] as? String, summary)
    }

    /// Leniently pull the first integer out of `acli … --count` output, whose
    /// exact shape isn't contract ("96", "96 work items", `{"count":96}` all parse).
    static func firstInt(_ output: String) -> Int? {
        guard let range = output.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(output[range])
    }

    /// Fallback when `create --json` returns non-JSON: scrape the first KEY-123
    /// token out of the output.
    static func scrapeKey(_ output: String) -> String? {
        let pattern = #"[A-Z][A-Z0-9]+-\d+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// Resolve a Jira workflow **status name** back to a Crow ``TicketStatus`` —
    /// the inverse of ``jiraStatusName(for:)`` (the #529 write path), honoring the
    /// per-workspace ``JiraConfig/statusMap`` (#523). For each pipeline status,
    /// resolve the Jira name it maps to (override or default) and match
    /// case-insensitively; otherwise fall back to the built-in alias table
    /// (`TicketStatus(projectBoardName:)`, which handles "Doing"/"Closed"/etc.).
    /// This is what makes a renamed status (e.g. "In Development" → In Progress)
    /// land in the right board column instead of collapsing to Backlog (#533).
    static func ticketStatus(forJiraName name: String, statusMap: [String: String]?) -> TicketStatus {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unknown }
        for status in TicketStatus.pipelineStatuses {
            let jiraName = statusMap?[status.rawValue]?.nonBlank ?? Self.defaultJiraStatusName(for: status)
            if jiraName.caseInsensitiveCompare(trimmed) == .orderedSame {
                return status
            }
        }
        return TicketStatus(projectBoardName: trimmed)
    }

    /// Decode `acli`'s top-level-array JSON output, then map via the shared
    /// `parseAssigned(items:…)` core. The REST path passes its unwrapped `issues`
    /// array directly to that core instead.
    static func parseAssigned(_ output: String, site: String?, statusOverride: TicketStatus?, statusMap: [String: String]?) -> [AssignedIssue] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return parseAssigned(items: items, site: site, statusOverride: statusOverride, statusMap: statusMap)
    }

    static func parseAssigned(items: [[String: Any]], site: String?, statusOverride: TicketStatus?, statusMap: [String: String]?) -> [AssignedIssue] {
        return items.compactMap { item -> AssignedIssue? in
            guard let key = item["key"] as? String,
                  let parsed = JiraKey.parse(key) else { return nil }
            let fields = item["fields"] as? [String: Any]
            let title = (fields?["summary"] as? String) ?? key
            let statusDict = fields?["status"] as? [String: Any]
            let statusName = statusDict?["name"] as? String ?? ""
            let categoryKey = (statusDict?["statusCategory"] as? [String: Any])?["key"] as? String ?? ""
            let status = statusOverride ?? Self.ticketStatus(forJiraName: statusName, statusMap: statusMap)
            let state = (statusOverride == .done || categoryKey == "done") ? "closed" : "open"
            // Jira labels are plain strings (no color); surface them so
            // label-driven flows (e.g. auto-create) work for Jira too.
            let labels = (fields?["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            let priorityName = Self.priorityName(fields)
            let parent = Self.parentInfo(fields)
            let url = site.flatMap { s -> String? in
                let host = s.hasPrefix("http") ? s : "https://\(s)"
                return "\(host)/browse/\(parsed.key)"
            } ?? parsed.key
            return AssignedIssue(
                id: "jira:\(parsed.key)",
                number: parsed.number,
                title: title,
                state: state,
                url: url,
                repo: parsed.project,
                labels: labels,
                provider: .jira,
                priority: priorityName.map { TicketPriority(jiraName: $0) },
                priorityName: priorityName,
                parentKey: parent.key,
                parentSummary: parent.summary,
                projectStatus: status
            )
        }
    }
}
