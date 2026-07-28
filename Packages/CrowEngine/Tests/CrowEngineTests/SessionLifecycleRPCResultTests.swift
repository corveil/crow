import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// #888 — `add-merge-label` applies the label even when Crow's watcher can't act
/// on it, so the receipt grew an additive `warning` alongside `ok:true`. These
/// pin the shape, because "omitted when there's nothing to say" is what lets a
/// caller use `jq -e .warning` and what keeps every existing consumer unchanged.
@Suite("SessionLifecycleRPC.okResult warning field (#888)")
struct SessionLifecycleRPCResultTests {
    private let id = UUID()

    @Test func omitsTheKeyEntirelyWhenThereIsNothingToWarnAbout() {
        let body = SessionLifecycleRPC.okResult(id: id)
        #expect(body["warning"] == nil, "an absent warning must be an absent key, never a null")
        #expect(body["ok"] == .bool(true))
        #expect(body["session_id"] == .string(id.uuidString))
    }

    @Test func omitsAnEmptyWarning() {
        // An empty string would serialize as a present-but-falsy key, which
        // reads as "there is a warning" to anything checking presence.
        #expect(SessionLifecycleRPC.okResult(id: id, warning: "")["warning"] == nil)
    }

    @Test func carriesTheWarningWithoutDisturbingOk() {
        // The action DID happen — the label really is on the PR — so `ok` stays
        // true. The warning answers a different question: whether it will do
        // anything.
        let body = SessionLifecycleRPC.okResult(id: id, warning: "The watcher is off.")
        #expect(body["ok"] == .bool(true))
        #expect(body["warning"] == .string("The watcher is off."))
    }
}
