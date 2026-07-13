import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLResponse live here on Linux
#endif
@testable import CrowCore

@Suite struct JiraSearchClientTests {

    // A realistic `search/jql` payload: one in-progress (renamed status) and one
    // done issue, mirroring the REST shape `{ "issues": [ { key, fields } ] }`.
    private static let searchPayload = """
    {"issues":[
      {"key":"MAXX-1","fields":{"summary":"Open one","status":{"name":"In Development","statusCategory":{"key":"indeterminate"}},"labels":["bug"]}},
      {"key":"MAXX-2","fields":{"summary":"Done two","status":{"name":"Done","statusCategory":{"key":"done"}},"labels":[]}}
    ]}
    """.data(using: .utf8)!

    // MARK: - URL building

    @Test func buildsSearchURLFromBareHost() {
        let url = JiraSearchClient.searchURL(
            site: "acme.atlassian.net",
            jql: "assignee = currentUser()",
            fields: ["key", "summary", "status", "labels"],
            maxResults: 100
        )
        let s = url?.absoluteString ?? ""
        #expect(s.hasPrefix("https://acme.atlassian.net/rest/api/3/search/jql?"))
        // JQL is percent-encoded in the query.
        #expect(s.contains("jql=assignee%20=%20currentUser()") || s.contains("jql=assignee%20%3D%20currentUser()"))
        #expect(s.contains("fields=key,summary,status,labels"))
        #expect(s.contains("maxResults=100"))
    }

    @Test func searchURLForcesHTTPSOnCleartextOrigin() {
        let url = JiraSearchClient.searchURL(site: "http://acme.atlassian.net", jql: "x", fields: ["key"], maxResults: 50)
        #expect(url?.scheme == "https")
        #expect(url?.host == "acme.atlassian.net")
    }

    @Test func searchURLNilForBlankInputs() {
        #expect(JiraSearchClient.searchURL(site: "", jql: "x", fields: ["key"], maxResults: 1) == nil)
        #expect(JiraSearchClient.searchURL(site: "acme.atlassian.net", jql: " ", fields: ["key"], maxResults: 1) == nil)
    }

    // MARK: - Parsing

    @Test func parsesIssuesArray() {
        let issues = JiraSearchClient.parseIssues(Self.searchPayload)
        #expect(issues?.count == 2)
        #expect(issues?.first?["key"] as? String == "MAXX-1")
    }

    @Test func parseIssuesNilOnUnexpectedShape() {
        #expect(JiraSearchClient.parseIssues(Data("[]".utf8)) == nil)
        #expect(JiraSearchClient.parseIssues(Data("not json".utf8)) == nil)
    }

    @Test func parseIssuesEmptyWhenNoMatches() {
        let issues = JiraSearchClient.parseIssues(Data(#"{"issues":[]}"#.utf8))
        #expect(issues?.isEmpty == true)
    }

    // MARK: - fetchAssigned

    @Test func fetchAssignedSendsAuthAndReturnsIssues() async {
        let result = await JiraSearchClient.fetchAssigned(
            site: "acme.atlassian.net",
            jql: "assignee = currentUser()",
            authorization: "Basic creds",
            transport: { request in
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic creds")
                #expect(request.url?.path == "/rest/api/3/search/jql")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Self.searchPayload, response)
            }
        )
        guard case .success(let issues) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(issues.count == 2)
    }

    @Test func fetchAssignedDefaultFieldsIncludePriorityAndParent() async {
        // #696: the default field set must request priority + parent so the
        // alignment capture rides the standard board read.
        let result = await JiraSearchClient.fetchAssigned(
            site: "acme.atlassian.net",
            jql: "assignee = currentUser()",
            authorization: "Basic creds",
            transport: { request in
                let query = request.url?.query ?? ""
                #expect(query.contains("fields=key,summary,status,labels,priority,parent"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Self.searchPayload, response)
            }
        )
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test func fetchAssignedFailsOnNon2xx() async {
        let result = await JiraSearchClient.fetchAssigned(
            site: "acme.atlassian.net",
            jql: "x",
            authorization: "Basic creds",
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        #expect(result.failureError == .http(401))
    }

    @Test func fetchAssignedFailsBadSite() async {
        let result = await JiraSearchClient.fetchAssigned(site: "", jql: "x", authorization: "Basic creds")
        #expect(result.failureError == .badSite)
    }

    // MARK: - Approximate count (#572)

    @Test func buildsApproximateCountURL() {
        let url = JiraSearchClient.approximateCountURL(site: "acme.atlassian.net")
        #expect(url?.absoluteString == "https://acme.atlassian.net/rest/api/3/search/approximate-count")
        // Forced https on a cleartext origin, nil on a blank site.
        #expect(JiraSearchClient.approximateCountURL(site: "http://acme.atlassian.net")?.scheme == "https")
        #expect(JiraSearchClient.approximateCountURL(site: " ") == nil)
    }

    @Test func parseApproximateCountReadsCount() {
        #expect(JiraSearchClient.parseApproximateCount(Data(#"{"count":96}"#.utf8)) == 96)
        #expect(JiraSearchClient.parseApproximateCount(Data("{}".utf8)) == nil)
        #expect(JiraSearchClient.parseApproximateCount(Data("not json".utf8)) == nil)
    }

    @Test func fetchApproximateCountPostsJQLWithAuth() async {
        let result = await JiraSearchClient.fetchApproximateCount(
            site: "acme.atlassian.net",
            jql: "statusCategory = Done",
            authorization: "Basic creds",
            transport: { request in
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic creds")
                #expect(request.url?.path == "/rest/api/3/search/approximate-count")
                let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
                #expect(body == ["jql": "statusCategory = Done"])
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"count":96}"#.utf8), response)
            }
        )
        guard case .success(let count) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(count == 96)
    }

    @Test func fetchApproximateCountFailsOnNon2xxAndDecode() async {
        let unauthorized = await JiraSearchClient.fetchApproximateCount(
            site: "acme.atlassian.net", jql: "x", authorization: "Basic creds",
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
        )
        #expect(unauthorized.failureError == .http(401))

        let garbage = await JiraSearchClient.fetchApproximateCount(
            site: "acme.atlassian.net", jql: "x", authorization: "Basic creds",
            transport: { request in
                (Data("not json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        #expect(garbage.failureError == .decode)

        let blank = await JiraSearchClient.fetchApproximateCount(site: "", jql: "x", authorization: "Basic creds")
        #expect(blank.failureError == .badSite)
    }
}

/// `Result<[[String:Any]], _>` isn't `Equatable` (the success payload holds
/// dictionaries), so assert on the error alone.
private extension Result {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
