import Testing
import Foundation
@testable import CrowCore

@Suite struct JiraStatusFetcherTests {

    @Test func buildsStatusesURLFromBareHost() {
        let url = JiraStatusFetcher.statusesURL(site: "acme.atlassian.net", projectKey: "PROPS")
        #expect(url?.absoluteString == "https://acme.atlassian.net/rest/api/3/project/PROPS/statuses")
    }

    @Test func buildsStatusesURLFromFullOrigin() {
        let url = JiraStatusFetcher.statusesURL(site: "https://acme.atlassian.net", projectKey: "MAXX")
        #expect(url?.absoluteString == "https://acme.atlassian.net/rest/api/3/project/MAXX/statuses")
    }

    @Test func statusesURLForcesHTTPSOnCleartextOrigin() {
        // A site typed as http:// must be upgraded so the Basic credential is
        // never sent in cleartext.
        let url = JiraStatusFetcher.statusesURL(site: "http://acme.atlassian.net", projectKey: "PROPS")
        #expect(url?.absoluteString == "https://acme.atlassian.net/rest/api/3/project/PROPS/statuses")
    }

    @Test func statusesURLNilForBlankInputs() {
        #expect(JiraStatusFetcher.statusesURL(site: "", projectKey: "PROPS") == nil)
        #expect(JiraStatusFetcher.statusesURL(site: "acme.atlassian.net", projectKey: "  ") == nil)
    }

    @Test func parsesAndDedupesStatusNamesAcrossIssueTypes() throws {
        let json = """
        [
          {"name":"Task","statuses":[{"name":"To Do"},{"name":"In Progress"},{"name":"Done"}]},
          {"name":"Bug","statuses":[{"name":"To Do"},{"name":"In Review"},{"name":"Done"}]}
        ]
        """.data(using: .utf8)!
        let names = try #require(JiraStatusFetcher.parseStatusNames(json))
        // Order-preserving, de-duplicated across issue types.
        #expect(names == ["To Do", "In Progress", "Done", "In Review"])
    }

    @Test func parseReturnsEmptyForNoStatuses() throws {
        let names = try #require(JiraStatusFetcher.parseStatusNames("[]".data(using: .utf8)!))
        #expect(names.isEmpty)
    }

    @Test func parseReturnsNilForMalformedJSON() {
        #expect(JiraStatusFetcher.parseStatusNames("not json".data(using: .utf8)!) == nil)
    }

    @Test func fetchSetsBasicAuthHeaderAndParsesNames() async {
        let payload = """
        [{"name":"Story","statuses":[{"name":"Backlog"},{"name":"Selected"}]}]
        """.data(using: .utf8)!
        var capturedAuth: String?
        let result = await JiraStatusFetcher.fetchStatusNames(
            site: "acme.atlassian.net",
            projectKey: "PROPS",
            authorization: "Basic ZW1haWw6dG9rZW4=",
            transport: { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (payload, response)
            }
        )
        #expect(capturedAuth == "Basic ZW1haWw6dG9rZW4=")
        #expect(result == .success(["Backlog", "Selected"]))
    }

    @Test func fetchSurfacesHTTPErrorStatus() async {
        let result = await JiraStatusFetcher.fetchStatusNames(
            site: "acme.atlassian.net",
            projectKey: "PROPS",
            authorization: "Basic x",
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        #expect(result == .failure(.http(401)))
    }
}
