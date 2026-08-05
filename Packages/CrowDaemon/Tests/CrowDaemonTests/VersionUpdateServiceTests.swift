import Foundation
import Testing
import CrowCore
@testable import CrowDaemon
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct VersionUpdateServiceTests {
    private struct StubShell: ShellRunner {
        func run(args: [String], env: [String: String], cwd: String?) async throws -> String { "" }
    }

    private final class CountingTransport: @unchecked Sendable {
        var requestCount = 0
        let delayNanoseconds: UInt64

        init(delayNanoseconds: UInt64 = 0) {
            self.delayNanoseconds = delayNanoseconds
        }

        func make() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                self.requestCount += 1
                if self.delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: self.delayNanoseconds)
                }
                let url = request.url?.absoluteString ?? ""
                let compare: [String: Any] = [
                    "status": "ahead", "ahead_by": 2, "behind_by": 0, "commits": [],
                ]
                let head: [String: Any] = [
                    "sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                    "commit": ["committer": ["date": "2026-08-05T12:00:00Z"]],
                ]
                let payload = url.contains("/commits/main") ? head : compare
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (data, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private let build = BuildInfo(
        version: "0.1.0",
        gitSha: "abc1234",
        gitShaFull: "abc1234567890abcdef1234567890abcdef1234",
        buildDate: "2026-08-05")

    @Test @MainActor func forcedChecksCoalesceOntoOneTransportRound() async {
        let counter = CountingTransport(delayNanoseconds: 50_000_000)
        let service = VersionUpdateService(
            buildInfo: build, shell: StubShell(), transport: counter.make())
        async let first = service.runCheck(force: true)
        async let second = service.runCheck(force: true)
        _ = await [first, second]
        // One compare + one branch-head fetch, not two of each.
        #expect(counter.requestCount == 2)
    }

    @Test @MainActor func forcedChecksThrottleWithinMinimumSpacing() async {
        let counter = CountingTransport()
        let service = VersionUpdateService(
            buildInfo: build, shell: StubShell(), transport: counter.make())
        _ = await service.runCheck(force: true)
        let afterFirst = counter.requestCount
        #expect(afterFirst == 2)
        _ = await service.runCheck(force: true)
        #expect(counter.requestCount == afterFirst)
    }
}
