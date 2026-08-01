import CrowCore
import CrowIPC
import Foundation
import Testing
@testable import CrowDaemon

/// Lane classification is a decision, not a default (#931). This is the gate:
/// it fails when a new write RPC ships without one, in the same spirit as
/// `RPCLedgerParityTests`.
@Suite struct RPCLanePolicyTests {

    private func request(_ method: String, _ params: [String: JSONValue]? = nil) -> JSONRPCRequest {
        JSONRPCRequest(id: 1, method: method, params: params)
    }

    /// The gate. `ParityLedger.rpcMethods` is already proven against the live
    /// router pair, so classifying against its write half classifies against the
    /// real surface — no second hand-maintained list of method names.
    @Test("every ledgered write declares a lane, and nothing else does")
    func everyWriteMethodIsClassified() {
        let writes = Set(ParityLedger.rpcMethods.filter(\.isWrite).map(\.method))
        let declared = Set(RPCLanePolicy.rules.keys)
        #expect(
            writes.subtracting(declared).isEmpty,
            "unclassified write RPCs: \(writes.subtracting(declared).sorted())")
        #expect(
            declared.subtracting(writes).isEmpty,
            "lane rules for methods that are not ledgered writes: \(declared.subtracting(writes).sorted())")
    }

    @Test func readsTakeNoLane() {
        for entry in ParityLedger.rpcMethods where !entry.isWrite {
            #expect(RPCLanePolicy.lane(for: request(entry.method)) == nil, "\(entry.method)")
        }
    }

    @Test func sessionWritesKeyOnTheirSessionID() {
        let sid = UUID().uuidString
        let lane = RPCLanePolicy.lane(for: request("set-status", ["session_id": .string(sid)]))
        #expect(lane == .param(name: "session_id", value: sid))
        // The pair from the issue shares it, so they cannot reorder.
        #expect(RPCLanePolicy.lane(for: request("complete-session", ["session_id": .string(sid)])) == lane)
        // A different session does not.
        #expect(
            RPCLanePolicy.lane(for: request("set-status", ["session_id": .string(UUID().uuidString)]))
                != lane)
    }

    @Test func aSessionWriteWithoutASessionIDTakesNoLane() {
        // The handler rejects it as invalidParams; bucketing every malformed
        // request into one lane would serialize them against each other.
        #expect(RPCLanePolicy.lane(for: request("set-status")) == nil)
        #expect(RPCLanePolicy.lane(for: request("set-status", ["session_id": .string("")])) == nil)
    }

    @Test func everyConfigMutationSharesOneLane() {
        // The lane that keeps `/rpc` from contending with itself for
        // `ConfigStore.withConfigLock` — an NSLock held across disk I/O.
        for method in [
            "set-config", "defaults-set", "job-add", "workspace-edit",
            "telemetry-set", "gateway-set", "run-setup",
        ] {
            #expect(RPCLanePolicy.lane(for: request(method)) == .config, "\(method)")
        }
    }

    @Test func reviewKickoffsShareOneLaneSoTheyCannotHoldEveryPermit() {
        #expect(RPCLanePolicy.lane(for: request("start-review")) == .reviewKickoff)
        #expect(RPCLanePolicy.lane(for: request("batch-start-review")) == .reviewKickoff)
    }

    @Test func managerWritesShareOneLane() {
        for method in [
            "create-manager", "restart-manager", "work-on-issue",
            "batch-work-on-issues", "restart-tmux-server", "reload-tmux-config",
        ] {
            #expect(RPCLanePolicy.lane(for: request(method)) == .manager, "\(method)")
        }
    }

    @Test func terminalAndJobWritesKeyOnTheirOwnIdentifiers() {
        let tid = UUID().uuidString
        #expect(
            RPCLanePolicy.lane(for: request("launch-agent", ["terminal_id": .string(tid)]))
                == .param(name: "terminal_id", value: tid))
        #expect(
            RPCLanePolicy.lane(for: request("retry-readiness", ["terminal_id": .string(tid)]))
                == .param(name: "terminal_id", value: tid))
        let jid = UUID().uuidString
        #expect(
            RPCLanePolicy.lane(for: request("job-run", ["job_id": .string(jid)]))
                == .param(name: "job_id", value: jid))
        #expect(
            RPCLanePolicy.lane(for: request("run-job", ["job_id": .string(jid)]))
                == .param(name: "job_id", value: jid))
    }

    @Test func selfGuardingMethodsAreDeliberatelyConcurrent() {
        // `IssueTracker.refresh()` early-returns on `isRefreshing` and
        // `ScorecardRebuilder` coalesces, so laning either would turn an
        // immediate return into a wait and make a client timeout *more* likely.
        #expect(RPCLanePolicy.lane(for: request("refresh-tickets")) == nil)
        #expect(RPCLanePolicy.lane(for: request("rebuild-scorecard")) == nil)
        // A brand-new id has nothing to order against.
        #expect(RPCLanePolicy.lane(for: request("new-session")) == nil)
    }

    @Test func anUnknownMethodTakesNoLane() {
        // methodNotFound returns instantly; there is nothing to order.
        #expect(RPCLanePolicy.lane(for: request("no-such-method")) == nil)
    }
}
