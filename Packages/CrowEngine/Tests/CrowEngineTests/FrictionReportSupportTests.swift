import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

@Suite("Friction kind and report (CROW-1477)")
struct FrictionReportSupportTests {
    private func item(
        _ text: String, kind: TodoKind = .friction, state: TodoState = .captured, minutesAgo: Int = 0
    ) -> TodoItem {
        let at = Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo * 60))
        return TodoItem(text: text, state: state, kind: kind, createdAt: at, updatedAt: at)
    }

    // MARK: - kind on todo-add / todo-edit / todo-list

    @Test func captureKindPrefersParamThenPrefix() throws {
        #expect(try TodoRPC.captureKind(params: [:], text: "[friction] x") == .friction)
        #expect(try TodoRPC.captureKind(params: [:], text: "an idea") == .idea)
        #expect(try TodoRPC.captureKind(params: ["kind": .string("friction")], text: "plain") == .friction)
        #expect(try TodoRPC.captureKind(params: ["kind": .string("Idea")], text: "[friction] x") == .idea)
        #expect(try TodoRPC.captureKind(params: ["kind": .string("")], text: "[friction] x") == .friction)
        #expect(throws: RPCError.self) { _ = try TodoRPC.captureKind(params: ["kind": .string("bug")], text: "x") }
        #expect(throws: RPCError.self) { _ = try TodoRPC.captureKind(params: ["kind": .int(1)], text: "x") }
    }

    @Test func editChangesKindAndBlankKeepsIt() throws {
        let original = item("[friction] x")
        let edited = try TodoRPC.applyingEdit(original, params: ["kind": .string("idea")])
        #expect(edited.kind == .idea)
        let kept = try TodoRPC.applyingEdit(original, params: ["kind": .string(" ")])
        #expect(kept.kind == .friction)
        #expect(throws: RPCError.self) { _ = try TodoRPC.applyingEdit(original, params: ["kind": .string("nope")]) }
    }

    @Test func listFiltersByKindAndCountsBeforeTheKindFilter() throws {
        let items = [
            item("idea one", kind: .idea),
            item("idea two", kind: .idea, state: .parked),
            item("[friction] a", minutesAgo: 1),
            item("[friction] b", state: .parked, minutesAgo: 2),
        ]
        let friction = try TodoRPC.listResult(items, params: ["kind": .string("friction")])
        #expect(friction["todos"]?.arrayValue?.count == 2)
        #expect(friction["kind_counts"] == .object(["idea": .int(2), "friction": .int(2)]))
        #expect(friction["todos"]?.arrayValue?.first?.objectValue?["kind"] == .string("friction"))

        let parked = try TodoRPC.listResult(items, params: ["state": .string("parked")])
        #expect(parked["todos"]?.arrayValue?.count == 2)
        #expect(parked["kind_counts"] == .object(["idea": .int(1), "friction": .int(1)]))

        let none = try TodoRPC.listResult([], params: [:])
        #expect(none["kind_counts"] == .object(["idea": .int(0), "friction": .int(0)]))
    }

    @Test func frictionBriefsSayWhatKindTheItemIs() {
        let friction = item("[friction] crow send has no --wait")
        #expect(TodoRPC.exploreBrief(for: friction).contains(TodoRPC.frictionBriefNote))
        #expect(TodoRPC.ticketBrief(for: friction).contains(TodoRPC.frictionBriefNote))
        let idea = item("an idea", kind: .idea)
        #expect(!TodoRPC.exploreBrief(for: idea).contains(TodoRPC.frictionBriefNote))
        #expect(!TodoRPC.ticketBrief(for: idea).contains(TodoRPC.frictionBriefNote))
    }

    // MARK: - summary grouping

    @Test func summaryStripsPrefixAndWorkaround() {
        #expect(FrictionRPC.summary(of: "[friction] crow send has no --wait-ready — polled list-terminals")
            == "crow send has no --wait-ready")
        #expect(FrictionRPC.summary(of: "[FRICTION]  crow   send has no --wait-ready -- slept 5s.")
            == "crow send has no --wait-ready")
        #expect(FrictionRPC.summary(of: "plain text without prefix") == "plain text without prefix")
        #expect(FrictionRPC.summaryKey(of: "[friction] Crow Send — x") == "crow send")
    }

    // MARK: - report

    @Test func localSectionGroupsRepeatsAndRanksByCount() throws {
        let todos = [
            item("[friction] crow send has no --wait-ready — polled", minutesAgo: 30),
            item("[friction] Crow send has no --wait-ready — slept", minutesAgo: 5),
            item("[friction] create-manager has no --prompt-file — six steps", minutesAgo: 1),
            item("[friction] stale reference for crow todo — read --help", state: .done, minutesAgo: 2),
            item("an idea", kind: .idea),
        ]
        let local = try #require(
            FrictionRPC.localSection(todos, limit: 10, includeClosed: false).objectValue)
        #expect(local["open"] == .int(3))
        #expect(local["total"] == .int(4))
        #expect(local["by_state"] == .object(["captured": .int(3), "done": .int(1)]))
        #expect(local["group_count"] == .int(2))
        let groupValues = try #require(local["groups"]?.arrayValue)
        let groups = groupValues.compactMap { $0.objectValue }
        #expect(groups.count == 2)
        #expect(groups[0]["count"] == .int(2))
        // The latest wording names the group.
        #expect(groups[0]["summary"] == .string("Crow send has no --wait-ready"))
        #expect(groups[0]["todo_ids"]?.arrayValue?.count == 2)
        #expect(groups[1]["summary"] == .string("create-manager has no --prompt-file"))

        let all = try #require(
            FrictionRPC.localSection(todos, limit: 1, includeClosed: true).objectValue)
        #expect(all["group_count"] == .int(3))
        #expect(all["groups"]?.arrayValue?.count == 1)
    }

    @Test func reportValidatesParams() throws {
        #expect(try FrictionRPC.decodeLimit([:]) == FrictionRPC.defaultLimit)
        #expect(try FrictionRPC.decodeLimit(["limit": .int(3)]) == 3)
        #expect(throws: RPCError.self) { _ = try FrictionRPC.decodeLimit(["limit": .int(0)]) }
        #expect(throws: RPCError.self) { _ = try FrictionRPC.decodeLimit(["limit": .int(101)]) }
        #expect(throws: RPCError.self) { _ = try FrictionRPC.decodeLimit(["limit": .string("5")]) }
        #expect(try FrictionRPC.decodeIncludeClosed([:]) == false)
        #expect(throws: RPCError.self) { _ = try FrictionRPC.decodeIncludeClosed(["include_closed": .string("yes")]) }
    }

    @Test func pendingSourceReportsTheGapWithoutInventingAShape() async throws {
        let corveil = await PendingCorveilFrictionReportSource().fetch()
        let section = try #require(FrictionRPC.corveilSection(corveil).objectValue)
        #expect(section["available"] == .bool(false))
        #expect(section["tracking"] == .string("https://github.com/corveil/corveil/issues/5601"))
        #expect(section["reason"]?.stringValue?.contains("corveil/corveil#5601") == true)
        #expect(section["report"] == nil)
    }

    @Test func aRealSourceIsPassedThroughVerbatim() throws {
        let body: JSONValue = .object(["anything": .array([.int(1)])])
        let section = try #require(FrictionRPC.corveilSection(.report(body)).objectValue)
        #expect(section["available"] == .bool(true))
        #expect(section["report"] == body)
    }
}
