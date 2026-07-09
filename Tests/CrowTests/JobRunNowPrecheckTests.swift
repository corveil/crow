import Foundation
import Testing
import CrowCore
@testable import Crow

/// The pure precheck behind `JobScheduler.runNowReporting` (CROW-604): why a
/// manual `job run` would be rejected before anything launches.
@Suite("Job run-now precheck")
struct JobRunNowPrecheckTests {

    private func job(enabled: Bool = true) -> JobConfig {
        JobConfig(
            name: "triage", workspace: "ws", repo: "o/r",
            prompts: ["go"], schedule: .interval(seconds: 3600), enabled: enabled
        )
    }

    @Test func rejectsWhenNoDevRoot() {
        let j = job()
        let error = JobScheduler.runNowPrecheck(jobID: j.id, jobs: [j], devRoot: nil, inFlight: [])
        #expect(error == .noDevRoot)
    }

    @Test func rejectsUnknownJob() {
        let error = JobScheduler.runNowPrecheck(jobID: UUID(), jobs: [job()], devRoot: "/dev", inFlight: [])
        #expect(error == .jobNotFound)
    }

    @Test func rejectsJobAlreadyInFlight() {
        let j = job()
        let error = JobScheduler.runNowPrecheck(jobID: j.id, jobs: [j], devRoot: "/dev", inFlight: [j.id])
        #expect(error == .alreadyRunning)
    }

    @Test func allowsValidJob() {
        let j = job()
        #expect(JobScheduler.runNowPrecheck(jobID: j.id, jobs: [j], devRoot: "/dev", inFlight: []) == nil)
    }

    @Test func allowsDisabledJob() {
        // Manual runs ignore the enabled flag (and the schedule).
        let j = job(enabled: false)
        #expect(JobScheduler.runNowPrecheck(jobID: j.id, jobs: [j], devRoot: "/dev", inFlight: []) == nil)
    }
}
