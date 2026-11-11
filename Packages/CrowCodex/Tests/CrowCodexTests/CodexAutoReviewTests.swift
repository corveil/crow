import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

/// CROW-1406: an unattended Codex `.review` routes its approval requests to
/// Codex's Auto-review reviewer, but only with the review auto-permission knob
/// on and a Codex the boot probe says is new enough. Every other combination
/// keeps the human-gated launch byte for byte.
@Suite("Codex Auto-review on .review")
struct CodexAutoReviewTests {

    private static let gated = OpenAICodexAgent(autoReviewSupported: true)
    private static let ungated = OpenAICodexAgent()

    private static func review(dispatched: Bool) -> Session {
        var session = Session(name: "review", kind: .review, agentKind: .codex)
        session.reviewPromptDispatched = dispatched
        return session
    }

    private static func launch(
        _ agent: OpenAICodexAgent, _ session: Session, auto: Bool,
        gatewayRoute: CodexGatewayArgs.Route? = nil
    ) -> String {
        agent.autoLaunchCommand(
            session: session, worktreePath: "/tmp/wt", remoteControlEnabled: false,
            autoPermissionMode: auto, telemetryPort: nil, gatewayRoute: gatewayRoute) ?? ""
    }

    // MARK: - The override text

    @Test func overridesAreTheReviewerSwapAndNothingWider() {
        let o = OpenAICodexAgent.autoReviewConfigOverrides
        #expect(o.contains("-c approvals_reviewer=auto_review"))
        // Auto-review only applies when approvals are interactive.
        #expect(o.contains("-c approval_policy=on-request"))
        // The sandbox stays bounded.
        #expect(o.contains("-c sandbox_mode=workspace-write"))
        #expect(!o.contains("danger-full-access"))
        #expect(!o.contains("dangerously"))
        #expect(!o.contains("never"))
        // Network stays off: an approved escalation runs one command outside
        // the sandbox, it does not widen the sandbox itself.
        #expect(!o.contains("network_access"))
        #expect(!o.contains("writable_roots"))
        // Not the legacy enum value, which a future Codex may drop.
        #expect(!o.contains("guardian_subagent"))
    }

    // MARK: - .review launches

    @Test func firstReviewLaunchCarriesReviewerWhenGatedAndAuto() {
        let cmd = Self.launch(Self.gated, Self.review(dispatched: false), auto: true)
        #expect(cmd.contains(
            "codex\(CodexStartupNotices.configOverrides)\(OpenAICodexAgent.autoReviewConfigOverrides) \(OpenAICodexAgent.inlineRenderingFlag) $(printf"))
        #expect(cmd.contains("/tmp/wt/.crow-review-prompt.md"))
        #expect(cmd.hasSuffix("\n"))
    }

    @Test func reviewResumeCarriesReviewerAheadOfTheSubcommand() {
        // Root-level `-c`, before `resume`, the same place the gateway route goes.
        let cmd = Self.launch(Self.gated, Self.review(dispatched: true), auto: true)
        #expect(cmd.hasSuffix(
            "codex\(CodexStartupNotices.configOverrides)\(OpenAICodexAgent.autoReviewConfigOverrides) resume --last \(OpenAICodexAgent.inlineRenderingFlag)\n"))
    }

    @Test func autoPermissionOffKeepsTheHumanGatedReview() {
        for dispatched in [false, true] {
            let session = Self.review(dispatched: dispatched)
            let off = Self.launch(Self.gated, session, auto: false)
            #expect(!off.contains("approvals_reviewer"))
            #expect(off == Self.launch(Self.ungated, session, auto: false))
        }
    }

    @Test func olderCodexFailsClosedEvenWithAutoPermissionOn() {
        for dispatched in [false, true] {
            let session = Self.review(dispatched: dispatched)
            let cmd = Self.launch(Self.ungated, session, auto: true)
            #expect(!cmd.contains("approvals_reviewer"))
            #expect(!cmd.contains("approval_policy"))
            // Byte-identical to the pre-CROW-1406 launch.
            #expect(cmd == Self.launch(Self.ungated, session, auto: false))
        }
    }

    @Test func reviewerComposesWithTheGatewayRoute() {
        let route = CodexGatewayArgs.Route(baseURL: "https://gw.example/v1", upstream: "openai_api")
        let cmd = Self.launch(Self.gated, Self.review(dispatched: true), auto: true, gatewayRoute: route)
        let gateway = CodexGatewayArgs.configOverrides(route)
        #expect(cmd.contains(gateway + OpenAICodexAgent.autoReviewConfigOverrides + " resume --last"))
    }

    // MARK: - Other kinds never take the reviewer

    @Test func jobWorkAndManagerNeverCarryTheReviewer() {
        for dispatched in [false, true] {
            var job = Session(name: "job", kind: .job, agentKind: .codex)
            job.reviewPromptDispatched = dispatched
            let jobCmd = Self.launch(Self.gated, job, auto: true)
            #expect(!jobCmd.contains("approvals_reviewer"))
            // `.job` keeps its approval-off bounded launch.
            #expect(jobCmd.contains("-a never -s workspace-write"))
        }
        let work = Session(name: "work", kind: .work, agentKind: .codex)
        #expect(!Self.launch(Self.gated, work, auto: true).contains("approvals_reviewer"))
        let manager = Self.gated.managerLaunchCommand(
            sessionName: "Manager", remoteControlEnabled: false,
            autoPermissionMode: true, telemetryPort: nil)
        #expect(!manager.contains("approvals_reviewer"))
    }

    // MARK: - The version gate

    @Test func minimumIsTheVerifiedBuild() {
        #expect(CodexVersionProbe.minimumAutoReviewVersion == AgentSemVer(0, 166, 0))
        #expect(CodexVersionProbe.autoReviewSupported(AgentSemVer(0, 166, 0)))
        #expect(CodexVersionProbe.autoReviewSupported(AgentSemVer(0, 167, 2)))
        #expect(CodexVersionProbe.autoReviewSupported(AgentSemVer(1, 0, 0)))
    }

    @Test func olderPreReleaseAndUnreadableFailClosed() {
        #expect(!CodexVersionProbe.autoReviewSupported(AgentSemVer(0, 165, 9)))
        #expect(!CodexVersionProbe.autoReviewSupported(nil))
        let alpha = AgentSemVer.firstToken(in: "codex-cli 0.166.0-alpha.4")
        #expect(alpha != nil)
        #expect(!CodexVersionProbe.autoReviewSupported(alpha))
    }

    @Test func gateReadsTheSameBannerAsTheAsyncHookProbe() {
        let verdict = CodexVersionProbe.decide(versionOutput: "codex-cli 0.166.0\n")
        #expect(CodexVersionProbe.autoReviewSupported(verdict.detected))
        #expect(!CodexVersionProbe.autoReviewSupported(
            CodexVersionProbe.decide(versionOutput: "").detected))
    }

    @Test func logLineNamesVersionAndPin() {
        #expect(CodexVersionProbe.autoReviewLogLine(AgentSemVer(0, 166, 0))
            == "review auto-review available (codex 0.166.0 >= 0.166.0)")
        #expect(CodexVersionProbe.autoReviewLogLine(AgentSemVer(0, 160, 1))
            == "review auto-review off (codex 0.160.1 < 0.166.0)")
        #expect(CodexVersionProbe.autoReviewLogLine(nil)
            == "review auto-review off (version unreadable; needs >= 0.166.0)")
    }
}
