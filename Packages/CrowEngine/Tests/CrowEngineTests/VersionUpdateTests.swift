import Foundation
import Testing
import CrowCore
@testable import CrowEngine

@Suite struct VersionUpdateClientTests {
    private func fixture(
        status: String = "behind",
        behindBy: Int = 2,
        aheadBy: Int = 0,
        commits: [[String: Any]] = []
    ) -> Data {
        let payload: [String: Any] = [
            "status": status,
            "behind_by": behindBy,
            "ahead_by": aheadBy,
            "commits": commits,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private let build = BuildInfo(
        version: "0.1.0", gitSha: "abc1234", gitShaFull: "abc1234567890", buildDate: "2026-08-05")

    @Test func devShaIsIndeterminate() async {
        let devBuild = BuildInfo(version: "0.1.0", gitSha: "dev", buildDate: "2026-08-05")
        let result = await VersionUpdateClient.check(build: devBuild)
        #expect(result.state == .unknown)
        #expect(result.reason?.contains("not a known git commit") == true)
    }

    @Test func behindByReportsUpdateCommand() async {
        let commit: [String: Any] = [
            "sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            "commit": ["committer": ["date": "2026-08-05T12:00:00Z"]],
        ]
        let data = fixture(commits: [commit])
        let result = await VersionUpdateClient.check(
            build: build,
            updateCommand: "git -C /tmp/crow pull && make install",
            transport: { _ in (data, HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        )
        #expect(result.state == .behind)
        #expect(result.behindBy == 2)
        #expect(result.remoteSha == "deadbee")
        #expect(result.remoteDate == "2026-08-05")
        #expect(result.updateCommand == "git -C /tmp/crow pull && make install")
    }

    @Test func identicalIsUpToDate() async {
        let data = fixture(status: "identical", behindBy: 0, aheadBy: 0)
        let result = await VersionUpdateClient.check(
            build: build,
            transport: { _ in (data, HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        )
        #expect(result.state == .upToDate)
        #expect(result.behindBy == 0)
    }

    @Test func aheadOnlyIsUnknown() async {
        let data = fixture(status: "ahead", behindBy: 0, aheadBy: 3)
        let result = await VersionUpdateClient.check(
            build: build,
            transport: { _ in (data, HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!) }
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
