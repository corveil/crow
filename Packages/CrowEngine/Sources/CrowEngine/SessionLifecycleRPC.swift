import CrowCore
import CrowIPC
import Foundation

/// Pure param-decode / precondition / response helpers for the session-lifecycle
/// RPC handlers — `mark-in-review`, `mark-issue-done`, `complete-session`,
/// `set-session-active`, `add-merge-label` (CROW-816).
///
/// Kept out of the router so the guards and response shapes are unit-testable
/// without a socket (same pattern as `JobRPC`). Callers pass already-extracted
/// values rather than an `AppState`, so nothing here needs main-actor isolation.
///
/// `requireTicketURL` mirrors the web UI's menu gating in `web/app.js`: the
/// browser hides "Mark In Review" when the session has no ticket, so it never
/// reaches a handler that would half-do the action. The CLI has no such
/// affordance, so the check lives server-side.
///
/// The provider-side verbs (`mark-issue-done`, `add-merge-label`) do **not**
/// guard here — their preconditions and failures are reported by
/// `IssueTracker` as `SessionActionError`, which covers the cases a handler
/// can't see (missing provider, absent capability, unparseable repo slug, and
/// every failed provider call). One source of truth, not two.
public enum SessionLifecycleRPC {
    /// Decode the `session_id` param every lifecycle verb takes.
    ///
    /// - Throws: `RPCError.invalidParams` when missing or not a UUID.
    public static func sessionID(from params: [String: JSONValue]) throws -> UUID {
        guard let raw = params["session_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw RPCError.invalidParams("session_id required (UUID)")
        }
        return id
    }

    /// Require a session to carry a linked ticket URL.
    ///
    /// - Throws: `RPCError.applicationError` when absent or blank.
    public static func requireTicketURL(_ url: String?, verb: String) throws -> String {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            throw RPCError.applicationError(
                "\(verb) needs a linked ticket — attach one with `crow set-ticket --url …`")
        }
        return url
    }

    /// Response body for the three status-transition verbs, matching `set-status`.
    public static func statusResult(id: UUID, status: SessionStatus) -> [String: JSONValue] {
        ["session_id": .string(id.uuidString), "status": .string(status.rawValue)]
    }

    /// Response body for the two provider-side verbs. `ok` is what the web UI
    /// has always read; `session_id` is additive, so a CLI caller piping to `jq`
    /// can correlate the receipt with the session it acted on.
    ///
    /// `warning` is additive in the same spirit, and answers a different
    /// question than `ok`: the verb *did* what it says (so `ok` stays true),
    /// but a `crow:merge` label merges nothing when the watcher is off or the
    /// repo forbids auto-merge — and the old receipt was silent about that,
    /// which is how a labeled PR could sit unmerged forever with no signal
    /// (#888). Omitted entirely when there's nothing to say, so `jq -e .warning`
    /// is a clean test and no existing consumer sees a new null.
    public static func okResult(id: UUID, warning: String? = nil) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["ok": .bool(true), "session_id": .string(id.uuidString)]
        if let warning, !warning.isEmpty { body["warning"] = .string(warning) }
        return body
    }
}
