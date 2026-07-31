import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding and response shapes for the session-lifecycle verbs (#816).
///
/// The ticket guard that used to live here (`requireTicketURL`, for the
/// status-only `mark-in-review`) went away in #876, when the verb started
/// moving the provider's board: its preconditions now come from `IssueTracker`
/// as `SessionActionError`, like every other provider-side verb — see
/// `SessionActionReportingTests`.
@Suite("Session lifecycle RPC support") struct SessionLifecycleRPCTests {
    private let id = UUID()

    // MARK: - session_id

    @Test func decodesSessionID() throws {
        let decoded = try SessionLifecycleRPC.sessionID(from: ["session_id": .string(id.uuidString)])
        #expect(decoded == id)
    }

    @Test func rejectsMissingOrMalformedSessionID() {
        let bad: [[String: JSONValue]] = [
            [:],
            ["session_id": .null],
            ["session_id": .string("")],
            ["session_id": .string("not-a-uuid")],
            ["session_id": .int(7)],
        ]
        for params in bad {
            #expect(throws: RPCError.self) { _ = try SessionLifecycleRPC.sessionID(from: params) }
        }
    }

    // MARK: - response shapes

    @Test func statusResultMatchesSetStatusShape() {
        let result = SessionLifecycleRPC.statusResult(id: id, status: .inReview)
        #expect(result["session_id"]?.stringValue == id.uuidString)
        #expect(result["status"]?.stringValue == "inReview")
    }

    /// `warning` is additive (#876, following #888's shape): omitted entirely
    /// when there's nothing to say, so `jq -e .warning` stays a clean test and
    /// `complete-session` / `set-session-active` responses are unchanged.
    @Test func statusResultOmitsEmptyWarning() {
        for warning: String? in [nil, ""] {
            let result = SessionLifecycleRPC.statusResult(id: id, status: .inReview, warning: warning)
            #expect(result["warning"] == nil)
            #expect(result.count == 2)
        }
    }

    @Test func statusResultCarriesWarningWithoutDisturbingStatus() {
        let result = SessionLifecycleRPC.statusResult(
            id: id, status: .inReview, warning: "board did not move")
        #expect(result["warning"]?.stringValue == "board did not move")
        #expect(result["status"]?.stringValue == "inReview")
        #expect(result["session_id"]?.stringValue == id.uuidString)
    }

    /// `ok` is what the web UI has always read; dropping it would break the
    /// browser, so pin it alongside the additive `session_id`.
    @Test func okResultKeepsOkAndAddsSessionID() {
        let result = SessionLifecycleRPC.okResult(id: id)
        #expect(result["ok"]?.boolValue == true)
        #expect(result["session_id"]?.stringValue == id.uuidString)
    }
}
