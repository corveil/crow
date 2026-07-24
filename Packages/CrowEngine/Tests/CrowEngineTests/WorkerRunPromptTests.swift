import Foundation
import Testing
import CrowProvider
@testable import CrowEngine

/// The wrapped launch prompt Crow writes for a claimed Corveil worker run
/// (corveil/crow#801). It must carry the snapshotted `prompt_body`, tell the
/// agent which write-back tools are permitted (and how to call them under the
/// right run id + worker id), and require the machine-readable result file Crow
/// reads on finish.
@Suite("WorkerRunPrompt")
struct WorkerRunPromptTests {
    private func run(
        id: String = "run-42",
        body: String? = "Do the important thing",
        policy: [String: WritebackBinding]? = nil
    ) -> WorkerRun {
        WorkerRun(id: id, kind: "tend", promptBody: body, writebackPolicy: policy)
    }

    @Test func includesPromptBodyAndRunID() {
        let prompt = WorkerRunPrompt.build(run: run(), workerID: "crow-host-1")
        #expect(prompt.contains("Do the important thing"))
        #expect(prompt.contains("run-42"))
    }

    @Test func instructsWritingTheResultFile() {
        let prompt = WorkerRunPrompt.build(run: run(), workerID: "crow-host-1")
        #expect(prompt.contains(WorkerRunPrompt.resultFileName))
        #expect(WorkerRunPrompt.resultFileName == ".crow-run-result.json")
    }

    @Test func tellsAgentNotToClaimOrComplete() {
        // Crow owns claim/heartbeat/complete — the agent must not.
        let prompt = WorkerRunPrompt.build(run: run(), workerID: "crow-host-1")
        #expect(prompt.lowercased().contains("do not"))
        #expect(prompt.contains("complete"))
    }

    @Test func listsAllowedWritebackToolsWithWorkerID() {
        let policy = ["ontology": WritebackBinding(allowed: ["ontology_update_entity"], dryRun: false)]
        let prompt = WorkerRunPrompt.build(run: run(policy: policy), workerID: "crow-host-9")
        #expect(prompt.contains("worker-run mcp-call"))
        #expect(prompt.contains("crow-host-9"))
        #expect(prompt.contains("ontology"))
        #expect(prompt.contains("ontology_update_entity"))
    }

    @Test func flagsDryRunBindings() {
        let policy = ["ontology": WritebackBinding(allowed: ["ontology_update_entity"], dryRun: true)]
        let prompt = WorkerRunPrompt.build(run: run(policy: policy), workerID: "w")
        #expect(prompt.lowercased().contains("dry-run"))
    }

    @Test func statesNoWritebacksWhenPolicyEmpty() {
        let prompt = WorkerRunPrompt.build(run: run(policy: nil), workerID: "w")
        #expect(prompt.contains("no** write-back") || prompt.lowercased().contains("no write-back"))
    }

    @Test func handlesEmptyPromptBodyGracefully() {
        let prompt = WorkerRunPrompt.build(run: run(body: nil), workerID: "w")
        #expect(prompt.contains("no prompt body"))
    }
}
