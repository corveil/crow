import Foundation
import Testing
import CrowCore
@testable import CrowEngine

@Suite struct VersionUpdateClientTests {
    private func compareFixture(
        status: String = "ahead",
        behindBy: Int = 0,
        aheadBy: Int = 2
    ) -> Data {
        let payload: [String: Any] = [
            "status": status,
            "behind_by": behindBy,
            "ahead_by": aheadBy,
            "commits": [],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func headFixture(sha: String, date: String) -> Data {
        let payload: [String: Any] = [
            "sha": sha,
            "commit": ["committer": ["date": date]],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private let build = BuildInfo(
        version: "0.1.0", gitSha: "abc1234", gitShaFull: "abc1234567890", buildDate: "2026-08-05")

    private func transport(
        compare: Data,
        head: Data = Data()
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let url = request.url?.absoluteString ?? ""
            let body = url.contains("/commits/main") ? head : compare
            return (body, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func devShaIsIndeterminate() async {
        let devBuild = BuildInfo(version: "0.1.0", gitSha: "dev", buildDate: "2026-08-05")
        let result = await VersionUpdateClient.check(build: devBuild)
        #expect(result.state == .unknown)
        #expect(result.reason?.contains("not a known git commit") == true)
    }

    @Test func staleBuildReportsBehind() async {
        // Captured from `gh api repos/corveil/crow/compare/5075fba...main`.
        let compare = try! JSONSerialization.data(withJSONObject: [
            "status": "ahead",
            "ahead_by": 2,
            "behind_by": 0,
            "commits": [],
        ])
        let head = headFixture(
            sha: "f56939ddeadbeefdeadbeefdeadbeefdeadbeef", date: "2026-08-05T12:00:00Z")
        let result = await VersionUpdateClient.check(
            build: build,
            updateCommand: "git -C /tmp/crow pull && make install",
            transport: transport(compare: compare, head: head)
        )
        #expect(result.state == .behind)
        #expect(result.behindBy == 2)
        #expect(result.remoteSha == "f56939d")
        #expect(result.updateCommand == "git -C /tmp/crow pull && make install")
    }

    @Test func behindByReportsUpdateCommand() async {
        let head = headFixture(
            sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", date: "2026-08-05T12:00:00Z")
        let result = await VersionUpdateClient.check(
            build: build,
            updateCommand: "git -C /tmp/crow pull && make install",
            transport: transport(compare: compareFixture(), head: head)
        )
        #expect(result.state == .behind)
        #expect(result.behindBy == 2)
        #expect(result.remoteSha == "deadbee")
        #expect(result.remoteDate == "2026-08-05")
        #expect(result.updateCommand == "git -C /tmp/crow pull && make install")
    }

    @Test func branchHeadComesFromCommitsEndpointNotComparePayload() async {
        let staleCommit: [String: Any] = [
            "sha": "0000000000000000000000000000000000000001",
            "commit": ["committer": ["date": "2020-01-01T00:00:00Z"]],
        ]
        let compare = try! JSONSerialization.data(withJSONObject: [
            "status": "ahead",
            "ahead_by": 300,
            "behind_by": 0,
            "commits": [staleCommit],
        ])
        let head = headFixture(
            sha: "cafebabecafebabecafebabecafebabecafebabe", date: "2026-08-05T15:00:00Z")
        let result = await VersionUpdateClient.check(
            build: build,
            transport: transport(compare: compare, head: head)
        )
        #expect(result.state == .behind)
        #expect(result.behindBy == 300)
        #expect(result.remoteSha == "cafebab")
        #expect(result.remoteDate == "2026-08-05")
    }

    @Test func identicalIsUpToDateAndSkipsBranchHeadFetch() async {
        let compare = compareFixture(status: "identical", behindBy: 0, aheadBy: 0)
        let result = await VersionUpdateClient.check(
            build: build,
            transport: { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("/commits/main") {
                    throw URLError(.cannotConnectToHost)
                }
                return (compare, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        #expect(result.state == .upToDate)
        #expect(result.behindBy == 0)
        #expect(result.remoteSha == build.gitSha)
        #expect(result.remoteDate == nil)
    }

    @Test func localAheadOfMainIsUnknown() async {
        let result = await VersionUpdateClient.check(
            build: build,
            transport: transport(compare: compareFixture(status: "behind", behindBy: 3, aheadBy: 0))
        )
        #expect(result.state == .unknown)
        #expect(result.reason?.contains("not on upstream") == true)
    }

    @Test func rateLimitIsUnknown() async {
        let result = await VersionUpdateClient.check(
            build: build,
            transport: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.github.com")!,
                    statusCode: 403, httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "0"])!
                return (Data(), response)
            }
        )
        #expect(result.state == .unknown)
        #expect(result.reason?.contains("rate limit") == true)
    }

    @Test func shortDateTrimsTime() {
        #expect(VersionUpdateClient.shortDate("2026-08-05T12:34:56Z") == "2026-08-05")
    }
}

@Suite struct VersionUpdateRPCTests {
    @Test func configJSONUsesSnakeCase() {
        let json = VersionUpdateRPC.configJSON(VersionUpdateConfig(enabled: false, intervalHours: 12))
        #expect(json == .object(["enabled": .bool(false), "interval_hours": .int(12)]))
    }

    @Test func patchIntervalRejectsBelowMinimum() {
        #expect(throws: RPCError.self) {
            _ = try VersionUpdateRPC.patchIntervalHours(["interval_hours": .int(1)])
        }
    }
}
