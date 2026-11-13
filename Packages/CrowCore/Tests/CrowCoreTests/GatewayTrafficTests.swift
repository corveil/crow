import Foundation
import Testing
@testable import CrowCore

/// Spike follow-up: proving gateway traffic from Corveil's request log.
@Suite struct GatewayTrafficTests {
    static let now = Date(timeIntervalSince1970: 2_000_000)
    static let corveil = "org-corveil", rm = "org-rm"
    static let names = [corveil: "Corveil, Inc.", rm: "Client A"]

    static func entry(_ id: String, conv: String?, org: String = corveil, key: String = "key-c",
                      name: String = "Crow gateway", ago: TimeInterval = 60) -> GatewayTraffic.Entry {
        .init(id: id, createdAt: now.addingTimeInterval(-ago), conversationID: conv,
              apiKeyID: key, apiKeyName: name, organizationID: org, statusCode: 200)
    }

    static func evidence(
        _ convs: [GatewayTraffic.Conversation], _ index: GatewayTraffic.Index,
        expected: GatewayTraffic.Expected?, through: Bool = true
    ) -> GatewayTraffic.Evidence {
        GatewayTraffic.evidence(conversations: convs, index: index, expected: expected,
                                throughGateway: through, orgNames: names, now: now)
    }

    static let expectCorveil = GatewayTraffic.Expected(organizationID: corveil, organizationName: "Corveil, Inc.", apiKeyID: "key-c")
    static let expectRM = GatewayTraffic.Expected(organizationID: rm, organizationName: "Client A", apiKeyID: "key-rm")

    // MARK: decode

    @Test func decodesAPageAndItsCursor() throws {
        let json = """
        {"count":2,"limit":500,"next_cursor":"abc","logs":[
          {"id":"1","created_at":"2026-11-10T01:24:30.433494Z","status_code":200,"api_key_id":"k","api_key_name":"Crow gateway",
           "organization_id":"o","metadata":{"request_body_claude_code_session":"conv-1"}},
          {"id":"2","created_at":"2026-11-10T01:24:29Z","metadata":{}},
          {"created_at":"2026-11-10T01:24:29Z"}
        ]}
        """
        let page = try #require(GatewayTraffic.decodePage(Data(json.utf8)))
        #expect(page.nextCursor == "abc")
        #expect(page.entries.count == 2)  // the id-less entry is dropped
        #expect(page.entries[0].conversationID == "conv-1")
        #expect(page.entries[0].apiKeyName == "Crow gateway")
        #expect(page.entries[1].conversationID == nil)
    }

    @Test func rejectsANonLogBody() {
        #expect(GatewayTraffic.decodePage(Data(#"{"error":"forbidden"}"#.utf8)) == nil)
        #expect(GatewayTraffic.decodePage(Data("<html>".utf8)) == nil)
    }

    // MARK: paging

    @Test func pagingStopsAtBudgetCursorOrWindow() {
        let oldestWanted = Self.now.addingTimeInterval(-3600)
        let recent = GatewayTraffic.Page(entries: [Self.entry("a", conv: nil, ago: 60)], nextCursor: "c")
        #expect(GatewayTraffic.shouldFetchNext(after: recent, pagesRead: 1, maxPages: 6, oldestWanted: oldestWanted))
        #expect(!GatewayTraffic.shouldFetchNext(after: recent, pagesRead: 6, maxPages: 6, oldestWanted: oldestWanted))
        let last = GatewayTraffic.Page(entries: recent.entries, nextCursor: nil)
        #expect(!GatewayTraffic.shouldFetchNext(after: last, pagesRead: 1, maxPages: 6, oldestWanted: oldestWanted))
        let old = GatewayTraffic.Page(entries: [Self.entry("b", conv: nil, ago: 7200)], nextCursor: "c")
        #expect(!GatewayTraffic.shouldFetchNext(after: old, pagesRead: 1, maxPages: 6, oldestWanted: oldestWanted))
        #expect(GatewayTraffic.pageSize == 500)
    }

    // MARK: index

    @Test func indexDedupesAcrossReadsAndSplitsByKey() {
        let a = Self.entry("1", conv: "c1")
        let index = GatewayTraffic.index(entries: [
            a, a,  // the same org read through two keys
            Self.entry("2", conv: "c1", ago: 30),
            Self.entry("3", conv: "c1", org: Self.rm, key: "key-rm", name: "rm gw"),
            Self.entry("4", conv: nil),
        ], readOrgs: [Self.corveil, Self.rm])
        let hits = index.byConversation["c1"] ?? []
        #expect(hits.count == 2)
        #expect(hits.reduce(0) { $0 + $1.count } == 3)
        #expect(index.windows[Self.corveil]?.count == 3)
        #expect(index.windows[Self.rm]?.count == 1)
    }

    @Test func aReadOrgWithNoTrafficStillHasAWindow() {
        let index = GatewayTraffic.index(entries: [], readOrgs: [Self.rm])
        #expect(index.windows[Self.rm]?.count == 0)
    }

    // MARK: verdict

    @Test func verifiedUnderTheExpectedOrgAndKey() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "c1"), Self.entry("2", conv: "c1")],
                                         readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now)], index, expected: Self.expectCorveil)
        #expect(ev.state == .verified)
        #expect(ev.count == 2)
        #expect(ev.seenOrganizationName == "Corveil, Inc.")
        #expect(ev.detail.contains("Crow gateway"))
    }

    /// The "bad" Manager: tagged with the Client A workspace, but its
    /// requests land under the Corveil, Inc. key.
    @Test func mismatchWhenRequestsLandInAnotherOrg() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "c1")], readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now)], index, expected: Self.expectRM)
        #expect(ev.state == .mismatch)
        #expect(ev.seenOrganizationName == "Corveil, Inc.")
        #expect(ev.expectedOrganizationName == "Client A")
        #expect(ev.detail.contains("belongs to Client A"))
    }

    @Test func mismatchOnKeyIDWithinTheSameOrg() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "c1", key: "some-other-key")],
                                         readOrgs: [Self.corveil])
        #expect(Self.evidence([.init(id: "c1", lastWrite: nil)], index, expected: Self.expectCorveil).state == .mismatch)
    }

    @Test func adoptedKeyWithoutIDChecksOrgOnly() {
        let adopted = GatewayTraffic.Expected(organizationID: Self.corveil, organizationName: "Corveil, Inc.", apiKeyID: "")
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "c1", key: "whatever")], readOrgs: [Self.corveil])
        #expect(Self.evidence([.init(id: "c1", lastWrite: nil)], index, expected: adopted).state == .verified)
    }

    @Test func multiOrgWindowFindsTheConversationInEitherOrg() {
        let index = GatewayTraffic.index(entries: [
            Self.entry("1", conv: "other"),
            Self.entry("2", conv: "c1", org: Self.rm, key: "key-rm", name: "rm gw"),
        ], readOrgs: [Self.corveil, Self.rm])
        #expect(Self.evidence([.init(id: "c1", lastWrite: Self.now)], index, expected: Self.expectRM).state == .verified)
    }

    @Test func silentWhenActiveInsideTheWindowWithNoRequests() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "someone-else", ago: 3600)],
                                         readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now.addingTimeInterval(-60))], index, expected: Self.expectCorveil)
        #expect(ev.state == .silent)
    }

    @Test func notSilentWhenTheActivityPredatesTheWindow() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "x", ago: 60)], readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now.addingTimeInterval(-86_400))], index, expected: Self.expectCorveil)
        #expect(ev.state == GatewayTraffic.State.none)
    }

    @Test func unavailableWhenTheExpectedOrgWasntRead() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "x")], readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now)], index, expected: Self.expectRM)
        #expect(ev.state == .unavailable)
        #expect(ev.detail.contains("Client A"))
    }

    @Test func noClaimWithoutAGatewayOrConversations() {
        let index = GatewayTraffic.index(entries: [], readOrgs: [Self.corveil])
        #expect(Self.evidence([], index, expected: Self.expectCorveil).state == GatewayTraffic.State.none)
        #expect(Self.evidence([.init(id: "c", lastWrite: Self.now)], index, expected: Self.expectCorveil, through: false).state
            == GatewayTraffic.State.none)
    }

    // MARK: body capture skipped (CROW-1450)

    static func skipped(_ id: String, ago: TimeInterval, reason: String = "org_daily_budget") -> GatewayTraffic.Entry {
        var e = entry(id, conv: nil, ago: ago)
        e.bodyCaptureSkipped = reason
        return e
    }

    @Test func decodesTheBodyCaptureSkipReason() throws {
        let json = """
        {"logs":[
          {"id":"1","created_at":"2026-11-12T21:07:20Z","organization_id":"o",
           "metadata":{"body_capture_skipped":"org_daily_budget","upstream_auth_source":"passthrough_oauth"}},
          {"id":"2","created_at":"2026-11-12T21:07:19Z","metadata":{"body_capture_skipped":""}}
        ]}
        """
        let page = try #require(GatewayTraffic.decodePage(Data(json.utf8)))
        #expect(page.entries[0].bodyCaptureSkipped == "org_daily_budget")
        #expect(page.entries[0].conversationID == nil)
        #expect(page.entries[1].bodyCaptureSkipped == nil)
    }

    @Test func windowCountsUncapturedEntriesAndTheirSpans() throws {
        let index = GatewayTraffic.index(entries: [
            Self.skipped("s1", ago: 5000), Self.skipped("s2", ago: 4000, reason: "upload_failed"),
            Self.entry("c1", conv: "x", ago: 3000),          // captured: ends the first run
            Self.entry("n1", conv: nil, ago: 2500),          // captured non-Claude-Code row: ends nothing new
            Self.skipped("s3", ago: 2000), Self.skipped("s4", ago: 1000),
        ], readOrgs: [Self.corveil])
        let w = try #require(index.windows[Self.corveil])
        #expect(w.count == 6)
        #expect(w.uncaptured == 4)
        #expect(w.uncapturedSpans.count == 2)
        #expect(w.uncapturedSpans[0].start == Self.now.addingTimeInterval(-5000))
        #expect(w.uncapturedSpans[0].end == Self.now.addingTimeInterval(-4000))
        #expect(w.uncapturedSpans[0].reasons == ["org_daily_budget": 1, "upload_failed": 1])
        #expect(w.uncapturedSpans[1].count == 2)
        #expect(w.uncapturedSpans[1].end == Self.now.addingTimeInterval(-1000))
    }

    /// The reported case: every row around the agent's last burst was stored
    /// without a body, so none could carry its conversation id.
    @Test func unavailableWhenTheRowsAroundTheActivityHaveNoBodies() {
        let index = GatewayTraffic.index(entries: [
            Self.entry("old", conv: "someone-else", ago: 20_000),
            Self.skipped("s1", ago: 9000), Self.skipped("s2", ago: 7300), Self.skipped("s3", ago: 120),
        ], readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now.addingTimeInterval(-7200))], index,
                               expected: Self.expectCorveil)
        #expect(ev.state == .unavailable)
        #expect(ev.detail.contains("Corveil, Inc. stored 3 requests without bodies since "))
        #expect(ev.detail.contains("(org daily body budget)"))
        #expect(ev.detail.contains("carry no conversation id"))
    }

    @Test func silentWhenTheRowsAroundTheActivityWereCapturedAndUnmatched() {
        let index = GatewayTraffic.index(entries: [
            Self.entry("c1", conv: "someone-else", ago: 7400), Self.entry("c2", conv: "someone-else", ago: 7100),
            Self.entry("n1", conv: nil, ago: 7000),
        ], readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: Self.now.addingTimeInterval(-7200))], index,
                               expected: Self.expectCorveil)
        #expect(ev.state == .silent)
    }

    /// Bodies were dropped earlier in the window and again later, but the
    /// rows around the agent's last activity were captured: still silent.
    /// Move the activity into either skipped span and it can't be verified.
    @Test func aMixedWindowKeysOnTheSpanAroundTheLastActivity() {
        let index = GatewayTraffic.index(entries: [
            Self.skipped("s1", ago: 30_000), Self.skipped("s2", ago: 25_000),
            Self.entry("c1", conv: "someone-else", ago: 20_000),
            Self.entry("c2", conv: "someone-else", ago: 10_000),
            Self.skipped("s3", ago: 5000, reason: "upload_backlog"), Self.skipped("s4", ago: 4000, reason: "upload_backlog"),
            Self.entry("c3", conv: "someone-else", ago: 60),
        ], readOrgs: [Self.corveil])
        func state(activityAgo: TimeInterval) -> GatewayTraffic.Evidence {
            Self.evidence([.init(id: "c1", lastWrite: Self.now.addingTimeInterval(-activityAgo))], index,
                          expected: Self.expectCorveil)
        }
        #expect(state(activityAgo: 15_000).state == .silent)
        #expect(state(activityAgo: 2000).state == .silent)
        let early = state(activityAgo: 27_000)
        #expect(early.state == .unavailable)
        #expect(early.detail.contains("stored 2 requests without bodies from "))
        let late = state(activityAgo: 4500)
        #expect(late.state == .unavailable)
        #expect(late.detail.contains("(body upload backlog)"))
        // The request is logged before the transcript write that follows it.
        #expect(state(activityAgo: 4000 - GatewayTraffic.activityLookback + 30).state == .unavailable)
        #expect(state(activityAgo: 4000 - GatewayTraffic.activityLookback - 30).state == .silent)
    }

    @Test func spanTextNamesUTCTimesAndCrossesDays() {
        let iso = { (s: String) in GatewayTraffic.parseDate(s)! }
        let window = GatewayTraffic.Window(organizationID: "o", oldest: iso("2026-11-12T10:00:00Z"),
                                           newest: iso("2026-11-13T14:00:00Z"), count: 9)
        let sameDay = GatewayTraffic.UncapturedSpan(start: iso("2026-11-12T20:31:10Z"), end: iso("2026-11-12T23:59:58Z"),
                                                     count: 3, reasons: [:])
        #expect(GatewayTraffic.spanText(sameDay, in: window) == "from 20:31 to 23:59")
        let crossing = GatewayTraffic.UncapturedSpan(start: iso("2026-11-12T20:31:00Z"), end: iso("2026-11-13T01:00:00Z"),
                                                      count: 3, reasons: [:])
        #expect(GatewayTraffic.spanText(crossing, in: window) == "from Nov 12 20:31 to Nov 13 01:00")
        let ongoing = GatewayTraffic.UncapturedSpan(start: iso("2026-11-13T12:00:00Z"), end: iso("2026-11-13T14:00:00Z"),
                                                     count: 3, reasons: [:])
        #expect(GatewayTraffic.spanText(ongoing, in: window) == "since 12:00")
        #expect(GatewayTraffic.reasonText(["upload_failed": 1, "org_daily_budget": 5, "new_reason": 1])
            == "org daily body budget, new reason, body upload failed")
    }

    // MARK: glyph state

    @Test func evidenceUpgradesTheGatewayGlyph() {
        let launched = LaunchedGateway(baseURL: "https://corveil.io", via: .settingsEnv, agentKind: .claudeCode)
        func glyph(_ state: GatewayTraffic.State) -> RecordingStatus.GatewayState {
            let ev = GatewayTraffic.Evidence(state: state, count: 1, lastAt: Self.now, detail: "d")
            return RecordingStatus.gateway(launched: launched, configuredBaseURL: "https://corveil.io",
                                           harnessRoutable: true, agentName: "Claude Code", traffic: ev).state
        }
        #expect(glyph(.verified) == .verified)
        #expect(glyph(.mismatch) == .mismatch)
        #expect(glyph(.silent) == .silent)
        #expect(glyph(.unavailable) == .routed)
        #expect(glyph(.none) == .routed)
    }

    @Test func evidenceNeverCarriesAKeyValue() {
        let index = GatewayTraffic.index(entries: [Self.entry("1", conv: "c1")], readOrgs: [Self.corveil])
        let ev = Self.evidence([.init(id: "c1", lastWrite: nil)], index, expected: Self.expectRM)
        #expect(!ev.detail.contains("sk-citadel"))
    }
}
