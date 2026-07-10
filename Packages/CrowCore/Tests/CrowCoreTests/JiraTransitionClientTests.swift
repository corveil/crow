import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLResponse live here on Linux
#endif
@testable import CrowCore

@Suite struct JiraTransitionClientTests {

    // Sample `GET /transitions` payload: transition names differ from their
    // target status names (the realistic Jira shape we must match on `to.name`).
    private static let transitionsPayload = """
    {"transitions":[
      {"id":"11","name":"Start Progress","to":{"name":"In Development"}},
      {"id":"21","name":"Code Review","to":{"name":"In Review"}},
      {"id":"31","name":"Resolve","to":{"name":"Done"}}
    ]}
    """.data(using: .utf8)!

    // MARK: - URL building

    @Test func buildsTransitionsURLFromBareHost() {
        let url = JiraTransitionClient.transitionsURL(site: "acme.atlassian.net", issueKey: "MAXX-12")
        #expect(url?.absoluteString == "https://acme.atlassian.net/rest/api/3/issue/MAXX-12/transitions")
    }

    @Test func transitionsURLForcesHTTPSOnCleartextOrigin() {
        let url = JiraTransitionClient.transitionsURL(site: "http://acme.atlassian.net", issueKey: "MAXX-12")
        #expect(url?.absoluteString == "https://acme.atlassian.net/rest/api/3/issue/MAXX-12/transitions")
    }

    @Test func transitionsURLNilForBlankInputs() {
        #expect(JiraTransitionClient.transitionsURL(site: "", issueKey: "MAXX-1") == nil)
        #expect(JiraTransitionClient.transitionsURL(site: "acme.atlassian.net", issueKey: " ") == nil)
    }

    // MARK: - Matching

    @Test func matchesOnTargetStatusNameCaseInsensitively() {
        let transitions = try! #require(JiraTransitionClient.parseTransitions(Self.transitionsPayload))
        #expect(JiraTransitionClient.matchTransitionID(in: transitions, targetName: "In Development") == "11")
        #expect(JiraTransitionClient.matchTransitionID(in: transitions, targetName: "in review") == "21")
        #expect(JiraTransitionClient.matchTransitionID(in: transitions, targetName: "DONE") == "31")
    }

    @Test func matchesOnTransitionNameWhenStatusNameDoesNotMatch() {
        let transitions = try! #require(JiraTransitionClient.parseTransitions(Self.transitionsPayload))
        // No `to.name` is "Start Progress", but the transition's own name is.
        #expect(JiraTransitionClient.matchTransitionID(in: transitions, targetName: "Start Progress") == "11")
    }

    @Test func noMatchForUnknownStatus() {
        let transitions = try! #require(JiraTransitionClient.parseTransitions(Self.transitionsPayload))
        #expect(JiraTransitionClient.matchTransitionID(in: transitions, targetName: "Backlog") == nil)
    }

    // MARK: - Full transition flow

    @Test func transitionsWhenStatusReachableAndPOSTsMatchingID() async {
        var posted: [String: Any]?
        var sawGET = false
        let result = await JiraTransitionClient.transition(
            site: "acme.atlassian.net",
            issueKey: "MAXX-12",
            targetStatusName: "In Development",
            authorization: "Basic creds",
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.httpMethod == "GET" {
                    sawGET = true
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic creds")
                    return (Self.transitionsPayload, response)
                } else {
                    posted = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
                }
            }
        )
        #expect(sawGET)
        #expect(result == .success(.transitioned(id: "11")))
        let transition = posted?["transition"] as? [String: Any]
        #expect(transition?["id"] as? String == "11")
    }

    @Test func gracefulNoOpWhenTargetStatusNotReachable() async {
        var didPOST = false
        let result = await JiraTransitionClient.transition(
            site: "acme.atlassian.net",
            issueKey: "MAXX-12",
            targetStatusName: "Backlog", // not a reachable transition
            authorization: "Basic creds",
            transport: { request in
                if request.httpMethod == "POST" { didPOST = true }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Self.transitionsPayload, response)
            }
        )
        // No POST fired — degrade gracefully rather than erroring.
        #expect(!didPOST)
        #expect(result == .success(.noMatchingTransition(available: ["In Development", "In Review", "Done"])))
    }

    @Test func surfacesHTTPErrorOnTransitionsFetch() async {
        let result = await JiraTransitionClient.transition(
            site: "acme.atlassian.net",
            issueKey: "MAXX-12",
            targetStatusName: "Done",
            authorization: "Basic x",
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        #expect(result == .failure(.http(401)))
    }

    @Test func badSiteFailsBeforeAnyRequest() async {
        var calledTransport = false
        let result = await JiraTransitionClient.transition(
            site: "",
            issueKey: "MAXX-12",
            targetStatusName: "Done",
            authorization: "Basic x",
            transport: { request in
                calledTransport = true
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        #expect(!calledTransport)
        #expect(result == .failure(.badSite))
    }
}
