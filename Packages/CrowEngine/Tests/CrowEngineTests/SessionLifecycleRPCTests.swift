import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// The guards behind the session-lifecycle verbs (#816). These exist because the
/// underlying `IssueTracker` entry points are `async -> Void` that return early
/// on a missing ticket / PR — without them a CLI caller gets `{"ok":true}` for a
/// no-op. Pinned here so a refactor can't quietly drop one.
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

    // MARK: - ticket guard

    @Test func acceptsTicketURL() throws {
        let url = try SessionLifecycleRPC.requireTicketURL(
            "https://github.com/corveil/crow/issues/816", verb: "mark-in-review")
        #expect(url == "https://github.com/corveil/crow/issues/816")
    }

    @Test func rejectsMissingOrBlankTicketURL() {
        for value: String? in [nil, "", "   ", "\n"] {
            #expect(throws: RPCError.self) {
                _ = try SessionLifecycleRPC.requireTicketURL(value, verb: "mark-in-review")
            }
        }
    }

    /// The message has to name a fix — a bare "invalid" leaves a CLI user stuck.
    @Test func ticketErrorNamesTheVerbAndTheFix() {
        do {
            _ = try SessionLifecycleRPC.requireTicketURL(nil, verb: "mark-issue-done")
            Issue.record("expected a throw")
        } catch let error as RPCError {
            #expect(error.errorDescription?.contains("mark-issue-done") == true)
            #expect(error.errorDescription?.contains("crow set-ticket") == true)
        } catch {
            Issue.record("expected RPCError, got \(error)")
        }
    }

    // MARK: - PR guard

    @Test func findsPRLinkAmongOtherLinkTypes() throws {
        let links = [
            SessionLink(sessionID: id, label: "Issue", url: "https://example.com/i/1", linkType: .ticket),
            SessionLink(sessionID: id, label: "PR", url: "https://example.com/pr/2", linkType: .pr),
            SessionLink(sessionID: id, label: "Repo", url: "https://example.com/r", linkType: .repo),
        ]
        let url = try SessionLifecycleRPC.requirePRURL(in: links, verb: "add-merge-label")
        #expect(url == "https://example.com/pr/2")
    }

    @Test func rejectsWhenNoPRLinkAttached() {
        // A ticket link is not a PR link — this is exactly the case the web UI
        // hides the menu item for, and the CLI must reject rather than no-op.
        let links = [
            SessionLink(sessionID: id, label: "Issue", url: "https://example.com/i/1", linkType: .ticket),
        ]
        #expect(throws: RPCError.self) {
            _ = try SessionLifecycleRPC.requirePRURL(in: links, verb: "add-merge-label")
        }
        #expect(throws: RPCError.self) {
            _ = try SessionLifecycleRPC.requirePRURL(in: [], verb: "add-merge-label")
        }
    }

    // MARK: - response shapes

    @Test func statusResultMatchesSetStatusShape() {
        let result = SessionLifecycleRPC.statusResult(id: id, status: .inReview)
        #expect(result["session_id"]?.stringValue == id.uuidString)
        #expect(result["status"]?.stringValue == "inReview")
    }

    /// `ok` is what the web UI has always read; dropping it would break the
    /// browser, so pin it alongside the additive `session_id`.
    @Test func okResultKeepsOkAndAddsSessionID() {
        let result = SessionLifecycleRPC.okResult(id: id)
        #expect(result["ok"]?.boolValue == true)
        #expect(result["session_id"]?.stringValue == id.uuidString)
    }
}
