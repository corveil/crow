import Foundation
import Testing
import CrowCore
@testable import CrowClaude

/// Locks in the resume-vs-initial-prompt decision in
/// `ClaudeCodeAgent.autoLaunchCommand` (#588): work/manager sessions always
/// resume with `--continue`; review/job sessions read their pre-written
/// prompt file exactly once (`reviewPromptDispatched == false`) and resume
/// with `--continue` on every relaunch after that — including the rebuild
/// after a tmux server crash.
@Suite("ClaudeCodeAgent.autoLaunchCommand resume semantics")
struct ClaudeCodeAgentLaunchTests {

    private let agent = ClaudeCodeAgent()

    private func command(kind: SessionKind, dispatched: Bool) -> String? {
        agent.autoLaunchCommand(
            session: Session(name: "s", kind: kind, reviewPromptDispatched: dispatched),
            worktreePath: "/tmp/wt",
            remoteControlEnabled: false,
            autoPermissionMode: false,
            telemetryPort: nil
        )
    }

    @Test func workAndManagerAlwaysResume() throws {
        for kind in [SessionKind.work, .manager] {
            for dispatched in [false, true] {
                let cmd = try #require(command(kind: kind, dispatched: dispatched))
                #expect(cmd.hasSuffix(" --continue\n"))
                #expect(!cmd.contains("$(cat"))
            }
        }
    }

    @Test func reviewAndJobReadPromptFileOnFirstLaunchOnly() throws {
        let review = try #require(command(kind: .review, dispatched: false))
        #expect(review.contains("\"$(cat /tmp/wt/.crow-review-prompt.md)\""))
        #expect(!review.contains("--continue"))

        let job = try #require(command(kind: .job, dispatched: false))
        #expect(job.contains("\"$(cat /tmp/wt/.crow-job-prompt.md)\""))
        #expect(!job.contains("--continue"))
    }

    @Test func reviewAndJobResumeAfterPromptDispatched() throws {
        for kind in [SessionKind.review, .job] {
            let cmd = try #require(command(kind: kind, dispatched: true))
            #expect(cmd.hasSuffix(" --continue\n"))
            #expect(!cmd.contains("$(cat"))
        }
    }
}
