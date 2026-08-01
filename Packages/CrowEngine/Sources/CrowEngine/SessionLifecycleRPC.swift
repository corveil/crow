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
/// The provider-side verbs (`mark-in-review`, `mark-issue-done`,
/// `add-merge-label`) do **not** guard here — their preconditions and failures
/// are reported by `IssueTracker` as `SessionActionError`, which covers the
/// cases a handler can't see (missing provider, absent capability, unparseable
/// repo slug, and every failed provider call). One source of truth, not two.
///
/// `mark-in-review` joined that group in #876, when it stopped being a
/// status-only write and started moving the provider's board. That retired the
/// `requireTicketURL` helper this enum used to carry for it — the ticket check
/// now lives in `IssueTracker.markInReview` alongside the provider, Manager and
/// session-existence checks, as `SessionActionError.noTicketURL`.
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

    /// Response body for the three status-transition verbs, matching `set-status`.
    ///
    /// `warning` carries the same contract as ``okResult(id:warning:)``'s: the
    /// transition named in `status` really happened, so there is no error — but
    /// something the verb also implies did not. `mark-in-review` moves the
    /// session *and* the provider's board; when the provider has no In Review
    /// status to move the ticket to, only half of that is possible, and saying
    /// so beats a silent half-action (#876, the shape #888 established).
    /// Omitted entirely when there is nothing to say, so `jq -e .warning` stays
    /// a clean test and `complete-session` / `set-session-active` responses are
    /// byte-identical to before.
    public static func statusResult(
        id: UUID, status: SessionStatus, warning: String? = nil
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "session_id": .string(id.uuidString),
            "status": .string(status.rawValue),
        ]
        if let warning, !warning.isEmpty { body["warning"] = .string(warning) }
        return body
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
