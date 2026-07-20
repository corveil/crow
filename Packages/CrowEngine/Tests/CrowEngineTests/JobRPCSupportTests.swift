import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding and response encoding for the `job-*` RPC handlers (CROW-604).
@Suite("Job RPC support")
struct JobRPCSupportTests {

    // MARK: - decodeSchedule

    @Test func decodeScheduleRoundTripsInterval() throws {
        let schedule = try JobRPC.decodeSchedule(
            .object(["type": .string("interval"), "seconds": .int(3600)])
        )
        #expect(schedule == .interval(seconds: 3600))
    }

    @Test func decodeScheduleRoundTripsDailyAt() throws {
        let schedule = try JobRPC.decodeSchedule(.object([
            "type": .string("dailyAt"),
            "hour": .int(9),
            "minute": .int(30),
            "weekdays": .array([.int(2), .int(6)]),
        ]))
        #expect(schedule == .dailyAt(hour: 9, minute: 30, weekdays: [2, 6]))
    }

    @Test func decodeScheduleRejectsMalformedShapes() {
        let bad: [JSONValue] = [
            .string("interval"),
            .object([:]),
            .object(["type": .string("weekly")]),
            .object(["type": .string("interval")]),  // missing seconds
        ]
        for value in bad {
            #expect(throws: RPCError.self) { _ = try JobRPC.decodeSchedule(value) }
        }
    }

    @Test func decodeScheduleRejectsOutOfRangeValues() {
        let bad: [JSONValue] = [
            .object(["type": .string("interval"), "seconds": .int(0)]),
            .object(["type": .string("dailyAt"), "hour": .int(24), "minute": .int(0), "weekdays": .array([])]),
            .object(["type": .string("dailyAt"), "hour": .int(9), "minute": .int(60), "weekdays": .array([])]),
            .object(["type": .string("dailyAt"), "hour": .int(9), "minute": .int(0), "weekdays": .array([.int(0)])]),
            .object(["type": .string("dailyAt"), "hour": .int(9), "minute": .int(0), "weekdays": .array([.int(8)])]),
        ]
        for value in bad {
            #expect(throws: RPCError.self) { _ = try JobRPC.decodeSchedule(value) }
        }
    }

    // MARK: - decodeName

    @Test func decodeNameTrimsWhitespace() throws {
        #expect(try JobRPC.decodeName(.string("  triage \n")) == "triage")
    }

    @Test func decodeNameRejectsMissingAndBlank() {
        #expect(throws: RPCError.self) { _ = try JobRPC.decodeName(nil) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodeName(.string("")) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodeName(.string("   ")) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodeName(.int(7)) }
    }

    // MARK: - validateRepoSlug

    @Test func validateRepoSlugAcceptsSlugsAndNestedGroups() throws {
        #expect(try JobRPC.validateRepoSlug("corveil/crow") == "corveil/crow")
        #expect(try JobRPC.validateRepoSlug("group/sub/project") == "group/sub/project")
        #expect(try JobRPC.validateRepoSlug("  owner/repo  ") == "owner/repo")
    }

    @Test func validateRepoSlugRejectsBareNamesAndPathLikeComponents() {
        // The slug's last component becomes an on-disk folder, so anything
        // path-like must be rejected before persist.
        for bad in ["", "   ", "api", "foo/..", "../foo", "foo/.", "./foo", "/repo", "owner/", "a//b"] {
            #expect(throws: RPCError.self, "expected '\(bad)' to be rejected") {
                _ = try JobRPC.validateRepoSlug(bad)
            }
        }
    }

    // MARK: - decodePrompts

    @Test func decodePromptsAcceptsStringArray() throws {
        let prompts = try JobRPC.decodePrompts(.array([.string("first"), .string("second")]))
        #expect(prompts == ["first", "second"])
    }

    @Test func decodePromptsRejectsMissingEmptyAndBlank() {
        #expect(throws: RPCError.self) { _ = try JobRPC.decodePrompts(nil) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodePrompts(.array([])) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodePrompts(.array([.string("  \n ")])) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodePrompts(.array([.int(1)])) }
        #expect(throws: RPCError.self) { _ = try JobRPC.decodePrompts(.string("not an array")) }
    }

    // MARK: - jobJSON

    @Test func jobJSONUsesSnakeCaseKeysAndISO8601Dates() throws {
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let job = JobConfig(
            name: "triage",
            workspace: "Corveil",
            repo: "corveil/api",
            prompts: ["go"],
            schedule: .interval(seconds: 3600),
            enabled: true,
            lastRunAt: nil,
            createdAt: created
        )
        let object = try #require(JobRPC.jobJSON(job).objectValue)
        #expect(object["id"] == .string(job.id.uuidString))
        #expect(object["name"] == .string("triage"))
        #expect(object["workspace"] == .string("Corveil"))
        #expect(object["repo"] == .string("corveil/api"))
        #expect(object["prompts"] == .array([.string("go")]))
        #expect(object["enabled"] == .bool(true))
        #expect(object["schedule"] == .object(["type": .string("interval"), "seconds": .int(3600)]))
        // Never run → no last_run_at key at all.
        #expect(object["last_run_at"] == nil)
        #expect(object["created_at"] == .string(ISO8601DateFormatter().string(from: created)))
        // Interval of 1h after createdAt.
        #expect(object["next_run_at"] == .string(
            ISO8601DateFormatter().string(from: created.addingTimeInterval(3600))
        ))
    }

    @Test func jobJSONIncludesLastRunAtWhenPresent() throws {
        let lastRun = Date(timeIntervalSince1970: 1_760_000_000)
        let job = JobConfig(
            name: "n", workspace: "w", repo: "o/r", prompts: ["p"],
            schedule: .interval(seconds: 60), lastRunAt: lastRun
        )
        let object = try #require(JobRPC.jobJSON(job).objectValue)
        #expect(object["last_run_at"] == .string(ISO8601DateFormatter().string(from: lastRun)))
        // next run is computed from lastRunAt, not createdAt.
        #expect(object["next_run_at"] == .string(
            ISO8601DateFormatter().string(from: lastRun.addingTimeInterval(60))
        ))
    }
}
