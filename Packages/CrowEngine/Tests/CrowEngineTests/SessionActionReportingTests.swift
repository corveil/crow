import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// `markIssueDone` / `addMergeLabel` used to be `async -> Void` that returned
/// early on every unmet precondition and swallowed every provider error, so
/// `crow mark-issue-done` printed `{"ok":true}` for a call that did nothing
/// (CROW-816 review, Yellow #1). They now throw `SessionActionError`.
///
/// These pin the *reporting*, not the provider round-trip: each case is one the
/// old code exited silently from.
@Suite("Session action reporting") @MainActor struct SessionActionReportingTests {
    private static func tempStore() -> JSONStore {
        JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-816-action-\(UUID().uuidString)"))
    }

    private func tracker(_ appState: AppState) -> IssueTracker {
        IssueTracker(appState: appState, providerManager: ProviderManager(), store: Self.tempStore())
    }

    /// Seed a session and return (appState, tracker, session).
    private func seed(
        kind: SessionKind = .work,
        ticketURL: String? = nil,
        provider: Provider? = nil,
        links: [SessionLink] = []
    ) -> (AppState, IssueTracker, Session) {
        let appState = AppState()
        var session = Session(name: "s", kind: kind, agentKind: .claudeCode)
        session.ticketURL = ticketURL
        session.provider = provider
        appState.sessions = [session]
        if !links.isEmpty { appState.links[session.id] = links }
        return (appState, tracker(appState), session)
    }

    // MARK: - mark-issue-done

    @Test func markIssueDoneReportsUnknownSession() async {
        let (_, tracker, _) = seed()
        await #expect(throws: SessionActionError.sessionNotFound) {
            try await tracker.markIssueDone(sessionID: UUID())
        }
    }

    @Test func markIssueDoneReportsMissingTicket() async {
        let (_, tracker, session) = seed(ticketURL: nil)
        await #expect(throws: SessionActionError.noTicketURL("mark-issue-done")) {
            try await tracker.markIssueDone(sessionID: session.id)
        }
    }

    /// The case the handler-level guard could not see: a ticket URL is present
    /// but the session has no provider, so the old code returned silently.
    @Test func markIssueDoneReportsMissingProvider() async {
        let (_, tracker, session) = seed(
            ticketURL: "https://github.com/corveil/crow/issues/816", provider: nil)
        await #expect(throws: SessionActionError.noProvider("mark-issue-done")) {
            try await tracker.markIssueDone(sessionID: session.id)
        }
    }

    @Test func markIssueDoneRejectsManagerSession() async {
        let (_, tracker, session) = seed(
            kind: .manager, ticketURL: "https://github.com/corveil/crow/issues/816", provider: .github)
        await #expect(throws: SessionActionError.managerSession("mark-issue-done")) {
            try await tracker.markIssueDone(sessionID: session.id)
        }
    }

    // MARK: - add-merge-label

    @Test func addMergeLabelReportsUnknownSession() async {
        let (_, tracker, _) = seed()
        await #expect(throws: SessionActionError.sessionNotFound) {
            try await tracker.addMergeLabel(sessionID: UUID())
        }
    }

    @Test func addMergeLabelReportsMissingPRLink() async {
        // A ticket link is not a PR link.
        let (_, tracker, session) = seed(links: [])
        await #expect(throws: SessionActionError.noPRLink("add-merge-label")) {
            try await tracker.addMergeLabel(sessionID: session.id)
        }
    }

    @Test func addMergeLabelReportsTicketOnlyLinks() async {
        let sessionID = UUID()
        let appState = AppState()
        var session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        session.provider = .github
        appState.sessions = [session]
        appState.links[session.id] = [SessionLink(
            sessionID: sessionID, label: "Issue",
            url: "https://github.com/corveil/crow/issues/816", linkType: .ticket)]

        await #expect(throws: SessionActionError.noPRLink("add-merge-label")) {
            try await tracker(appState).addMergeLabel(sessionID: session.id)
        }
    }

    @Test func addMergeLabelRejectsManagerSession() async {
        let (_, tracker, session) = seed(
            kind: .manager, provider: .github,
            links: [SessionLink(
                sessionID: UUID(), label: "PR",
                url: "https://github.com/corveil/crow/pull/868", linkType: .pr)])
        await #expect(throws: SessionActionError.managerSession("add-merge-label")) {
            try await tracker.addMergeLabel(sessionID: session.id)
        }
    }

    /// A PR URL with no parseable owner/repo slug can't be labeled — the old
    /// code logged and returned, reporting success to the caller.
    @Test func addMergeLabelReportsUnparseableRepo() async {
        let (_, tracker, session) = seed(
            provider: .github,
            links: [SessionLink(
                sessionID: UUID(), label: "PR", url: "not-a-url", linkType: .pr)])
        // Either the slug is unparseable or the provider lacks the capability;
        // both are reported failures now, which is the point.
        await #expect(throws: SessionActionError.self) {
            try await tracker.addMergeLabel(sessionID: session.id)
        }
    }

    // MARK: - messages

    /// A CLI user reading the error should learn how to fix it.
    @Test func errorMessagesNameTheFix() {
        #expect(SessionActionError.noTicketURL("mark-issue-done")
            .errorDescription?.contains("crow set-ticket") == true)
        #expect(SessionActionError.noPRLink("add-merge-label")
            .errorDescription?.contains("crow add-link --type pr") == true)
        #expect(SessionActionError.managerSession("add-merge-label")
            .errorDescription?.contains("Manager") == true)
        #expect(SessionActionError.providerFailed("boom")
            .errorDescription?.contains("boom") == true)
    }
}
