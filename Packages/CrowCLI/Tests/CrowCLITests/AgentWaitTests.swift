import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - crow wait / send --wait-ready / --wait-ack (CROW-1475)

private let sessionUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
private let terminalUUID = "b1b2c3d4-e5f6-7890-abcd-ef1234567890"

/// A fake clock: `sleep` advances `now` instead of blocking.
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 0)
    var sleeps = 0
    func sleep(_ seconds: TimeInterval) { now.addTimeInterval(seconds); sleeps += 1 }
}

/// Serves snapshots in order, then repeats the last one.
private final class Script {
    var snaps: [AgentWait.Snapshot]
    var calls = 0
    init(_ states: [String?]) { snaps = states.map { AgentWait.Snapshot(agentState: $0) } }
    init(snaps: [AgentWait.Snapshot]) { self.snaps = snaps }
    func next() -> AgentWait.Snapshot {
        defer { calls += 1 }
        return snaps[min(calls, snaps.count - 1)]
    }
}

private func poll(
    _ script: Script, timeout: TimeInterval = 5, until target: String
) throws -> AgentWait.Outcome {
    let clock = FakeClock()
    return try AgentWait.poll(
        timeout: timeout, interval: 0.25,
        now: { clock.now }, sleep: clock.sleep,
        fetch: script.next, done: { $0.agentState == target })
}

@Test func waitReturnsOnceTheStateIsReached() throws {
    let script = Script(["starting", "starting", "idle"])
    #expect(try poll(script, until: "idle") == .reached(.init(agentState: "idle")))
    #expect(script.calls == 3)
}

@Test func waitTimesOutWithTheLastSnapshot() throws {
    let script = Script(["starting"])
    #expect(try poll(script, timeout: 1, until: "idle") == .timedOut(.init(agentState: "starting")))
    // 1s at 0.25s intervals: bounded, not a spin.
    #expect(script.calls <= 6)
}

@Test func waitStopsWhenTheAgentExits() throws {
    #expect(try poll(Script(["working", "exited"]), until: "idle") == .exited(.init(agentState: "exited")))
}

@Test func waitCanWaitForExit() throws {
    #expect(try poll(Script(["working", "exited"]), until: "exited") == .reached(.init(agentState: "exited")))
}

@Test func waitFailsFastWithNoAgentTerminal() throws {
    let script = Script([nil])
    #expect(try poll(script, until: "idle") == .noAgent)
    #expect(script.calls == 1)
}

@Test func snapshotReadsTheGetSessionFields() {
    let snap = AgentWait.Snapshot([
        "agent_state": .string("idle"),
        "last_prompt_at": .string("2026-11-20T10:00:00.123Z"),
        "agent_terminal_id": .string(terminalUUID),
    ])
    #expect(snap == AgentWait.Snapshot(
        agentState: "idle", lastPromptAt: "2026-11-20T10:00:00.123Z", agentTerminalID: terminalUUID))
    #expect(AgentWait.Snapshot(["agent_state": .null]).agentState == nil)
}

// MARK: - Ack

@Test func ackWhenAnIdleAgentStartsWorking() {
    let before = AgentWait.Snapshot(agentState: "idle")
    #expect(AgentWait.isAccepted(.init(agentState: "working"), before: before))
    #expect(AgentWait.isAccepted(.init(agentState: "waiting_permission"), before: before))
    #expect(!AgentWait.isAccepted(.init(agentState: "idle"), before: before))
}

@Test func ackWhenAQuickTurnFinishedBetweenPolls() {
    let before = AgentWait.Snapshot(agentState: "idle", lastPromptAt: "2026-11-20T10:00:00.000Z")
    let after = AgentWait.Snapshot(agentState: "idle", lastPromptAt: "2026-11-20T10:00:05.000Z")
    #expect(AgentWait.isAccepted(after, before: before))
}

@Test func busyBeforeTheSendNeedsANewPrompt() {
    // Text sent to a busy agent may only be queued in its composer.
    let before = AgentWait.Snapshot(agentState: "working", lastPromptAt: "2026-11-20T10:00:00.000Z")
    #expect(!AgentWait.isAccepted(.init(agentState: "working", lastPromptAt: "2026-11-20T10:00:00.000Z"), before: before))
    #expect(AgentWait.isAccepted(.init(agentState: "working", lastPromptAt: "2026-11-20T10:01:00.000Z"), before: before))
}

// MARK: - Parsing

@Test func waitParsesAndValidates() throws {
    let cmd = try Wait.parse(["--session", sessionUUID, "--until", "idle", "--timeout", "30"])
    #expect(cmd.until == "idle")
    #expect(cmd.timeout == 30)
    #expect(try Wait.parse(["--session", sessionUUID, "--until", "waiting_permission"]).timeout
        == AgentWait.defaultTimeout)
}

@Test func waitRejectsUnknownStatesAndBadTimeouts() {
    #expect(throws: (any Error).self) { _ = try Wait.parse(["--session", sessionUUID, "--until", "ready"]) }
    #expect(throws: (any Error).self) { _ = try Wait.parse(["--session", sessionUUID, "--until", "idle", "--timeout", "0"]) }
    #expect(throws: (any Error).self) { _ = try Wait.parse(["--session", sessionUUID, "--until", "idle", "--timeout", "4000"]) }
    #expect(throws: (any Error).self) { _ = try Wait.parse(["--session", "nope", "--until", "idle"]) }
}

@Test func sendParsesWaitFlags() throws {
    let plain = try Send.parse(["--session", sessionUUID, "--terminal", terminalUUID, "hi\n"])
    #expect(!plain.waitReady && !plain.waitAck)

    let waiting = try Send.parse([
        "--session", sessionUUID, "--terminal", terminalUUID,
        "--wait-ready", "--wait-ack", "--timeout", "90", "hi\n",
    ])
    #expect(waiting.waitReady && waiting.waitAck)
    #expect(waiting.timeout == 90)
    #expect(waiting.text == "hi\n")
}

@Test func failureMessagesNameTheState() {
    let timedOut = AgentWait.failure(.timedOut(.init(agentState: "starting")), waitingFor: "idle", timeout: 2.5)
    #expect(timedOut.message.contains("2.5s"))
    #expect(timedOut.message.contains("agent_state=starting"))
    #expect(timedOut.message.contains("no hook since launch"))
    #expect(AgentWait.failure(.exited(.init(agentState: "exited")), waitingFor: "idle", timeout: 1)
        .message.contains("exited"))
    #expect(AgentWait.failure(.noAgent, waitingFor: "idle", timeout: 1).message.contains("no agent terminal"))
}
