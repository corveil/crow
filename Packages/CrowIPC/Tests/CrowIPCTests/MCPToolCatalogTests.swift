import CrowCore
import Foundation
import Testing

@testable import CrowIPC

@Suite("MCP stuck-session detection")
struct MCPStuckSessionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reasons(
        row: [String: JSONValue],
        live: [String: JSONValue] = [:],
        idleMinutes: Int = 60
    ) -> [String] {
        MCPToolCatalog.stuckReasons(row: row, live: live, idleMinutes: idleMinutes, now: now)
            .compactMap { $0["reason"]?.stringValue }
    }

    private func iso(_ minutesAgo: Int) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
    }

    @Test("A working session is not stuck")
    func workingIsNotStuck() {
        #expect(reasons(row: ["activity": .string("working")]).isEmpty)
        #expect(reasons(row: ["activity": .string("idle")]).isEmpty)
        #expect(reasons(row: [:]).isEmpty)
    }

    @Test("A waiting agent is stuck on input")
    func waitingOnInput() {
        #expect(reasons(row: ["activity": .string("waiting")]) == ["waiting_on_input"])
    }

    @Test("A pending attention notification counts even without a waiting activity")
    func attentionAlone() {
        // `attention` is set by the hook signal sources and can outlive the
        // activity transition; either one means a human is being asked for something.
        #expect(reasons(row: ["attention": .string("permission_prompt")]) == ["waiting_on_input"])
    }

    @Test("An empty attention string does not count")
    func emptyAttentionIsIgnored() {
        #expect(reasons(row: ["attention": .string("")]).isEmpty)
    }

    @Test("Idle is reported on top of waiting once the threshold passes")
    func idleTooLong() {
        let row: [String: JSONValue] = [
            "activity": .string("waiting"),
            "attention_since": .string(iso(120)),
        ]
        #expect(reasons(row: row, idleMinutes: 60) == ["waiting_on_input", "idle_too_long"])
        #expect(reasons(row: row, idleMinutes: 180) == ["waiting_on_input"])
    }

    @Test("Without attention_since, idle is not claimed")
    func idleNeedsATimestamp() {
        // Claiming "idle" with nothing to measure would be a guess presented as a
        // fact, which is worse than omitting the reason.
        #expect(reasons(row: ["activity": .string("waiting")], idleMinutes: 0) == ["waiting_on_input"])
    }

    @Test("Failing checks are detected from either the summary or the failed list")
    func failingChecks() {
        let byState: [String: JSONValue] = [
            "pr": .object(["has_pr": .bool(true), "checks": .string("failing")]),
        ]
        #expect(reasons(row: [:], live: byState) == ["checks_failing"])

        let byList: [String: JSONValue] = [
            "pr": .object([
                "has_pr": .bool(true),
                "checks": .string("pending"),
                "failed_checks": .array([.string("build")]),
            ]),
        ]
        #expect(reasons(row: [:], live: byList) == ["checks_failing"])
    }

    @Test("A session with no PR is not check-stuck")
    func noPRNoCheckFailure() {
        #expect(reasons(row: [:], live: ["pr": .object(["has_pr": .bool(false)])]).isEmpty)
    }

    @Test("Passing checks are not stuck")
    func passingChecks() {
        let live: [String: JSONValue] = [
            "pr": .object([
                "has_pr": .bool(true), "checks": .string("passing"), "failed_checks": .array([]),
            ]),
        ]
        #expect(reasons(row: [:], live: live).isEmpty)
    }

    @Test("Blocked and stalled auto-merge count; enabled and merged do not")
    func autoMergePhases() {
        for phase in ["blocked", "stalled"] {
            let live: [String: JSONValue] = [
                "auto_merge_state": .object(["phase": .string(phase), "message": .string("why")]),
            ]
            #expect(reasons(row: [:], live: live) == ["auto_merge_stuck"])
        }
        for phase in ["enabled", "merged", "off"] {
            let live: [String: JSONValue] = ["auto_merge_state": .object(["phase": .string(phase)])]
            #expect(reasons(row: [:], live: live).isEmpty, "phase \(phase) should not be stuck")
        }
    }

    @Test("Auto-rebase stall is reported")
    func autoRebasePhases() {
        let live: [String: JSONValue] = [
            "auto_rebase_state": .object([
                "phase": .string("stalled"), "reason": .string("dirty-worktree"),
            ]),
        ]
        let detail = MCPToolCatalog.stuckReasons(row: [:], live: live, idleMinutes: 60, now: now)
        #expect(detail.first?["reason"]?.stringValue == "auto_rebase_stuck")
        // Falls back to `reason` when the watcher supplied no human message.
        #expect(detail.first?["detail"]?.stringValue == "dirty-worktree")
    }

    @Test("A session can be stuck for several reasons at once")
    func multipleReasons() {
        let row: [String: JSONValue] = ["activity": .string("waiting")]
        let live: [String: JSONValue] = [
            "pr": .object(["has_pr": .bool(true), "checks": .string("failing")]),
            "auto_rebase_state": .object(["phase": .string("blocked")]),
        ]
        #expect(reasons(row: row, live: live)
            == ["waiting_on_input", "checks_failing", "auto_rebase_stuck"])
    }

    @Test("The permanent flag rides along when the watcher set it")
    func permanentFlag() {
        let live: [String: JSONValue] = [
            "auto_merge_state": .object([
                "phase": .string("blocked"),
                "message": .string("repo disallows auto-merge"),
                "permanent": .bool(true),
            ]),
        ]
        let detail = MCPToolCatalog.stuckReasons(row: [:], live: live, idleMinutes: 60, now: now)
        #expect(detail.first?["permanent"]?.boolValue == true)
    }
}

@Suite("MCP tool argument validation")
struct MCPToolArgumentTests {

    @Test("limit defaults, floors and caps")
    func limits() throws {
        #expect(try MCPToolCatalog.limit(from: [:], default: 50) == 50)
        #expect(try MCPToolCatalog.limit(from: ["limit": .int(10)], default: 50) == 10)
        // Capped rather than rejected: a model asking for "everything" should get a
        // large page, not an error it has to reason about.
        #expect(try MCPToolCatalog.limit(from: ["limit": .int(99_999)], default: 50)
            == MCPToolCatalog.maxLimit)
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.limit(from: ["limit": .int(0)], default: 50)
        }
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.limit(from: ["limit": .string("ten")], default: 50)
        }
    }

    @Test("An unknown enum value is an error, not an empty result")
    func enumValidation() throws {
        // "No sessions are inReviewww" is a much worse answer than "inReviewww is
        // not a status" — the first looks like a fact about the board.
        #expect(try MCPToolCatalog.optionalEnum([:], "status", allowed: ["active"]) == nil)
        #expect(try MCPToolCatalog.optionalEnum(
            ["status": .string("active")], "status", allowed: ["active"]) == "active")
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.optionalEnum(["status": .string("nope")], "status", allowed: ["active"])
        }
    }

    @Test("Non-negative integers reject negatives")
    func nonNegative() throws {
        #expect(try MCPToolCatalog.nonNegativeInt([:], "min_idle_minutes", default: 60) == 60)
        #expect(try MCPToolCatalog.nonNegativeInt(
            ["min_idle_minutes": .int(0)], "min_idle_minutes", default: 60) == 0)
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.nonNegativeInt(
                ["min_idle_minutes": .int(-1)], "min_idle_minutes", default: 60)
        }
    }

    @Test("pick keeps only present fields")
    func pickOmitsAbsentFields() {
        let picked = MCPToolCatalog.pick(["a": .int(1), "z": .int(9)], ["a", "b"])
        #expect(picked == ["a": .int(1)])
        // An absent optional stays absent rather than becoming an explicit null the
        // model has to interpret.
        #expect(picked["b"] == nil)
    }
}
