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
