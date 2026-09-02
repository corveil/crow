import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("CodexSignalSource")
struct CodexSignalSourceTests {
    private let source = CodexSignalSource()

    private func event(
        _ name: String,
        toolName: String? = nil,
        source: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: UUID(),
            eventName: name,
            toolName: toolName,
            source: source,
            summary: name
        )
    }

    // MARK: - The 7 events Codex emits

    @Test func sessionStartFreshIdle() {
        let t = source.transition(
            for: event("SessionStart", source: "startup"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .idle)
        if case .clear = t.lastTopLevelStopAt {} else {
            Issue.record("SessionStart should clear lastTopLevelStopAt")
        }
    }

    @Test func sessionStartResumeMarksDone() {
        let t = source.transition(
            for: event("SessionStart", source: "resume"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
    }

    @Test func preToolUseSetsWorking() {
        let t = source.transition(
            for: event("PreToolUse", toolName: "Bash"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .working)
        if case .set(let activity) = t.toolActivity {
            #expect(activity.toolName == "Bash")
            #expect(activity.isActive == true)
        } else {
            Issue.record("expected tool activity set active")
        }
    }

    @Test func postToolUseMarksInactive() {
        let t = source.transition(
            for: event("PostToolUse", toolName: "Bash"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
        if case .set(let activity) = t.toolActivity {
            #expect(activity.isActive == false)
        } else {
            Issue.record("expected inactive tool activity")
        }
    }

    @Test func userPromptSubmitClearsLastStopAt() {
        let t = source.transition(
            for: event("UserPromptSubmit"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .working)
        if case .clear = t.lastTopLevelStopAt {} else {
            Issue.record("UserPromptSubmit should clear lastTopLevelStopAt")
        }
    }

    @Test func stopSetsLastStopAt() {
        let t = source.transition(
            for: event("Stop"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
        if case .clear = t.toolActivity {} else {
            Issue.record("Stop should clear tool activity")
        }
        if case .set = t.lastTopLevelStopAt {} else {
            Issue.record("Stop should set lastTopLevelStopAt")
        }
    }

    @Test func interruptFromWorkingMarksWaitingWithoutCompleting() {
        let t = source.transition(
            for: event("Interrupt"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting, "Interrupt must not satisfy job/review completion (.done)")
        if case .clear = t.toolActivity {} else {
            Issue.record("Interrupt should clear tool activity")
        }
        if case .leave = t.lastTopLevelStopAt {} else {
            Issue.record("Interrupt must not stamp lastTopLevelStopAt (owned by Stop)")
        }
    }

    @Test func interruptDoesNotUncompleteADoneTurn() {
        // Defensive: upstream Stop and Interrupt are exclusive paths, but if a
        // Stop already landed, Interrupt must not pull the card off `.done`.
        let t = source.transition(
            for: event("Interrupt"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == nil, "Interrupt after Stop must leave .done")
        if case .leave = t.lastTopLevelStopAt {} else {
            Issue.record("Interrupt must not touch lastTopLevelStopAt")
        }
    }

    @Test func interruptThenUserPromptSubmitResumesWorking() {
        // `crow send` (tmux paste + Enter) while a turn is running aborts it
        // (Interrupt) then submits the follow-up (UserPromptSubmit). The card
        // must not complete in the gap — `.waiting` then `.working`.
        var activityState: AgentActivityState = .working
        var lastTopLevelStopAt: Date? = nil

        func apply(_ name: String) {
            let t = source.transition(
                for: event(name),
                currentActivityState: activityState,
                currentNotificationType: nil,
                currentLastTopLevelStopAt: lastTopLevelStopAt)
            if let s = t.newActivityState { activityState = s }
            switch t.lastTopLevelStopAt {
            case .leave: break
            case .clear: lastTopLevelStopAt = nil
            case .set(let d): lastTopLevelStopAt = d
            }
        }

        apply("Interrupt")
        #expect(activityState == .waiting)
        #expect(lastTopLevelStopAt == nil, "Interrupt must not look like a Stop")
        apply("UserPromptSubmit")
        #expect(activityState == .working)
    }

    @Test func permissionRequestWaits() {
        let t = source.transition(
            for: event("PermissionRequest"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .set(let n) = t.notification {
            #expect(n.notificationType == "permission_prompt")
        } else {
            Issue.record("expected permission_prompt notification")
        }
        if case .clear = t.toolActivity {} else {
            Issue.record("expected toolActivity cleared")
        }
    }

    @Test func permissionRequestPreservesQuestionNotification() {
        let t = source.transition(
            for: event("PermissionRequest"),
            currentActivityState: .waiting,
            currentNotificationType: "question",
            currentLastTopLevelStopAt: nil
        )
        if case .leave = t.notification {} else {
            Issue.record("question notification should not be overridden")
        }
    }

    // MARK: - Blanket clear

    @Test func nonPermissionRequestClearsPendingNotification() {
        let t = source.transition(
            for: event("PreToolUse", toolName: "Bash"),
            currentActivityState: .waiting,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        if case .clear = t.notification {} else {
            Issue.record("non-PermissionRequest events should clear pending notification")
        }
    }

    @Test func unknownEventAppliesBlanketClearOnly() {
        let t = source.transition(
            for: event("FuturisticUnknownEvent"),
            currentActivityState: .working,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
        if case .clear = t.notification {} else {
            Issue.record("unknown events should still clear pending notification")
        }
    }

    // MARK: - Async delivery ordering robustness (CROW-1065)
    //
    // Codex fires `PostToolUse` **async** (`CodexHookConfigWriter.asyncEvents`)
    // once the installed `codex` is >= 0.148.0, so its fire-and-forget
    // `crow hook-event` can reach the daemon *after* a following **sync** `Stop`
    // — the #903 inversion window, widened by async delivery. These pin the
    // invariant that makes that window harmless: `PostToolUse` never touches a
    // completion-driving field (`newActivityState` / `lastTopLevelStopAt` —
    // both owned by the sync `Stop`), so no ordering of a straggler `PostToolUse`
    // against `Stop` can un-complete a turn. Its only mutation is
    // `lastToolActivity`, which `SessionHookState.persistedSnapshot` excludes
    // (no on-disk card-color write) and which no display code reads today. If a
    // future change gives `PostToolUse` a completion-field mutation, or the card
    // starts reading `lastToolActivity`, these break — a signal to re-audit the
    // async emission before it can show a stale state on `.job`/`.work` cards.
    //
    // CROW-1177: `Interrupt` mutates `activityState` (`.waiting`) but is
    // registered **sync**, so it is not part of this async-ordering proof.
    // `PostToolUse` remains the only async Codex event.

    @Test func postToolUseLeavesCompletionFieldsUntouched() {
        // Drive it against a *done* turn with a stop already stamped — the state
        // a late straggler would land on — and assert it changes neither field.
        let t = source.transition(
            for: event("PostToolUse", toolName: "Bash"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == nil, "PostToolUse must not move activityState")
        if case .leave = t.lastTopLevelStopAt {} else {
            Issue.record("PostToolUse must not touch lastTopLevelStopAt (owned by Stop)")
        }
        // The one field it may set — persistence-excluded and reader-less.
        if case .set(let a) = t.toolActivity {
            #expect(a.isActive == false)
        } else {
            Issue.record("PostToolUse should record inactive tool activity")
        }
    }

    @Test func lateAsyncPostToolUseAfterStopStaysDone() {
        // Replay the worst-case inversion the way the daemon applies transitions
        // (EngineRouter field-by-field, last-write-wins): the turn's PreToolUse,
        // its Stop, then a *straggler* PostToolUse whose async `hook-event`
        // landed after Stop. The card must still read done.
        var activityState: AgentActivityState = .idle
        var lastTopLevelStopAt: Date? = nil
        var lastToolActivity: ToolActivity? = nil

        func apply(_ name: String, toolName: String? = nil) {
            let t = source.transition(
                for: event(name, toolName: toolName),
                currentActivityState: activityState,
                currentNotificationType: nil,
                currentLastTopLevelStopAt: lastTopLevelStopAt)
            if let s = t.newActivityState { activityState = s }
            switch t.toolActivity {
            case .leave: break
            case .clear: lastToolActivity = nil
            case .set(let a): lastToolActivity = a
            }
            switch t.lastTopLevelStopAt {
            case .leave: break
            case .clear: lastTopLevelStopAt = nil
            case .set(let d): lastTopLevelStopAt = d
            }
        }

        apply("PreToolUse", toolName: "Bash")   // working; tool active
        apply("Stop")                            // done; stop stamped; tool cleared
        apply("PostToolUse", toolName: "Bash")   // straggler arrives late

        #expect(activityState == .done, "a late async PostToolUse must not un-complete the turn")
        #expect(lastTopLevelStopAt != nil, "Stop's completion stamp must survive the straggler")
        // The straggler re-populates the reader-less, persistence-excluded field
        // — the *only* residue of the inversion, asserted to document it.
        #expect(lastToolActivity?.isActive == false)
    }
}
