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
/// The `require*` guards mirror the web UI's menu gating in `web/app.js`: the
/// browser hides "Close Issue" / "Add Merge Label" when the session has no
/// ticket URL / PR link, so it never reaches a handler that would no-op. The
/// CLI has no such affordance, and the underlying `IssueTracker` entry points
/// are `async -> Void` that swallow every failure — without these guards
/// `crow add-merge-label` would print `{"ok":true}` for a session with no PR.
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

    /// Require a session to carry a linked PR, returning its URL.
    ///
    /// - Throws: `RPCError.applicationError` when no `.pr` link is attached.
    public static func requirePRURL(in links: [SessionLink], verb: String) throws -> String {
        guard let pr = links.first(where: { $0.linkType == .pr }) else {
            throw RPCError.applicationError(
                "\(verb) needs a linked PR — attach one with `crow add-link --type pr --url …`")
        }
        return pr.url
    }

    /// Response body for the three status-transition verbs, matching `set-status`.
    public static func statusResult(id: UUID, status: SessionStatus) -> [String: JSONValue] {
        ["session_id": .string(id.uuidString), "status": .string(status.rawValue)]
    }

    /// Response body for the two provider-side verbs. `ok` is what the web UI
    /// has always read; `session_id` is additive, so a CLI caller piping to `jq`
    /// can correlate the receipt with the session it acted on.
    public static func okResult(id: UUID) -> [String: JSONValue] {
        ["ok": .bool(true), "session_id": .string(id.uuidString)]
    }
}
