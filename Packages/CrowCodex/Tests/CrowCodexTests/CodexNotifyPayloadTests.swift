import Foundation
import Testing
@testable import CrowCodex

@Suite("CodexNotifyPayload")
struct CodexNotifyPayloadTests {
    @Test func agentTurnCompleteMapsToStop() {
        let json = """
        {"type":"agent-turn-complete","cwd":"/Users/x/Dev/repo","turn-id":"abc","last-assistant-message":"done"}
        """
        let result = CodexNotifyPayload.translate(json)
        #expect(result.eventName == "Stop")
        #expect(result.payload["cwd"] == "/Users/x/Dev/repo")
        // kebab-case keys are normalized to snake_case so the rest of the
        // pipeline doesn't need a per-agent switch.
        #expect(result.payload["turn_id"] == "abc")
        #expect(result.payload["last_assistant_message"] == "done")
    }

    @Test func unknownTypeMapsToNotification() {
        let json = """
        {"type":"some-future-event","detail":"hello"}
        """
        let result = CodexNotifyPayload.translate(json)
        #expect(result.eventName == "Notification")
        #expect(result.payload["type"] == "some-future-event")
    }

    @Test func unparseableJSONFallsBackToNotification() {
        let result = CodexNotifyPayload.translate("not even close to json")
        #expect(result.eventName == "Notification")
        #expect(result.payload["message"] == "not even close to json")
    }

    @Test func missingTypeMapsToNotification() {
        let result = CodexNotifyPayload.translate("{\"cwd\":\"/x\"}")
        #expect(result.eventName == "Notification")
        #expect(result.payload["cwd"] == "/x")
    }
}
