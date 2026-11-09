import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Scratch **Ticket** runs `/crow-diagnose` on the item instead of filing one
/// issue itself (CROW-1416): the brief, the outcomes that aren't tickets, and
/// an epic's several ticket links moving the item to `ticketed` once.
@Suite("Scratch Ticket runs /crow-diagnose (CROW-1416)")
struct TodoTicketDiagnoseTests {
    private let devRoot = "/Users/jane/Dev"
    private let corveil = WorkspaceInfo(name: "Corveil", alwaysInclude: ["corveil/crow"])

    private func issue(_ n: Int, repo: String = "corveil/crow") -> TodoLink {
        TodoLink(type: .ticket, url: "https://github.com/\(repo)/issues/\(n)", label: "\(repo)#\(n)")
    }

    // MARK: - Brief

    @Test func briefRunsTheSkillOnTheItemWithTheOperatorsGo() {
        let item = TodoItem(text: "cursor jumps")
        let brief = TodoRPC.ticketBrief(for: item, workspace: corveil, devRoot: devRoot)
        #expect(brief.contains("/crow-diagnose \(item.id.uuidString) --yes --workspace \"Corveil\"\n"))
        #expect(brief.contains("Work from the development root, `\(devRoot)`."))
        #expect(brief.contains("docs/ticket-standard.md"))
        #expect(brief.hasSuffix("\n"))
    }

    /// The old brief filed one issue itself. None of that survives.
    @Test func briefNoLongerFilesOneIssueItself() {
        let brief = TodoRPC.ticketBrief(for: TodoItem(text: "x"), workspace: corveil, devRoot: devRoot)
        #expect(!brief.contains("gh issue create"))
        #expect(!brief.contains("file one provider issue"))
        #expect(!brief.contains("Choose that repo yourself"))
    }

    /// Cursor, Codex and OpenCode get the same text as their prompt and may not
    /// load `.claude/skills/`, so the brief names the installed SKILL.md by its
    /// absolute path (ADR 0015).
    @Test func briefPointsOtherHarnessesAtTheInstalledSkill() {
        let brief = TodoRPC.ticketBrief(for: TodoItem(text: "x"), workspace: corveil, devRoot: devRoot)
        #expect(brief.contains("read `\(devRoot)/.claude/skills/crow-diagnose/SKILL.md`"))
        #expect(brief.contains("does not run `.claude/skills/` skills as slash commands"))
    }

    @Test func briefWithoutAWorkspaceOrRootStillRunsTheSkill() {
        let item = TodoItem(text: "x")
        let brief = TodoRPC.ticketBrief(for: item)
        #expect(brief.contains("/crow-diagnose \(item.id.uuidString) --yes\n"))
        #expect(!brief.contains("--workspace"))
        #expect(!brief.contains("Work from the development root"))
        #expect(brief.contains("read `.claude/skills/crow-diagnose/SKILL.md`"))
    }

    @Test func briefMapsEveryOutcomeToAnItemCommand() {
        let item = TodoItem(text: "x")
        let id = item.id.uuidString
        let brief = TodoRPC.ticketBrief(for: item, workspace: corveil, devRoot: devRoot)
        for outcome in ["**ticket**", "**duplicate**", "**commitment**", "**needs info**", "**won't do**"] {
            #expect(brief.contains(outcome), "missing \(outcome)")
        }
        #expect(brief.contains("crow todo link --id \(id) --type ticket --url <issue-url>"))
        #expect(brief.contains("crow todo edit --id \(id) --append-note"))
        #expect(brief.contains("crow todo park --id \(id)"))
        #expect(brief.contains("crow todo drop --id \(id)"))
        // An epic: every filed issue, once, the epic last so `todo work` starts it.
        #expect(brief.contains("link every issue the skill filed"))
        #expect(brief.contains("sub-tickets first and the epic last"))
        #expect(brief.contains("Never paste the item's text"))
    }

    @Test func briefKeepsTheDispatchAndWorkSessionRails() {
        let brief = TodoRPC.ticketBrief(for: TodoItem(text: "x"), workspace: corveil, devRoot: devRoot)
        #expect(brief.contains("Do not run `crow todo ticket`"))
        #expect(brief.contains("Do not create a worktree or start a work session."))
    }

    @Test func briefCarriesTheItemAndOmitsEmptyFields() {
        let item = TodoItem(text: "cursor jumps", note: "only on iPad", tags: ["web"], priority: "p2")
        let brief = TodoRPC.ticketBrief(for: item, workspace: corveil, devRoot: devRoot)
        #expect(brief.contains("## Scratch item\ncursor jumps"))
        #expect(brief.contains("## Notes\nonly on iPad"))
        #expect(brief.contains("Tags: web"))
        #expect(brief.contains("Priority: p2"))
        let bare = TodoRPC.ticketBrief(for: TodoItem(text: "try this"), workspace: corveil, devRoot: devRoot)
        #expect(!bare.contains("## Notes"))
        #expect(!bare.contains("Tags:"))
        #expect(!bare.contains("Priority:"))
    }

    // MARK: - Linking an epic moves the item to `ticketed` once

    @Test func epicLinksMoveTheItemToTicketedOnce() {
        var item = TodoItem(text: "x", state: .exploring)
        var states: [TodoState] = [item.state]
        // Sub-tickets first, the epic last, as the brief asks.
        for link in [issue(11), issue(12, repo: "corveil/web"), issue(10)] {
            item = TodoRPC.linking(link, to: item)
            states.append(item.state)
        }
        #expect(states == [.exploring, .ticketed, .ticketed, .ticketed])
        let transitions = zip(states, states.dropFirst()).filter { $0 != $1 }
        #expect(transitions.count == 1)
        #expect(item.links.filter { $0.type == .ticket }.count == 3)
        #expect(item.linkedTicketURL == "https://github.com/corveil/crow/issues/10")
    }

    @Test func oneTicketEndsWithOneLinkEvenWhenLinkedTwice() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var item = TodoItem(text: "x", state: .exploring)
        item = TodoRPC.linking(issue(7), to: item, now: at)
        let again = TodoRPC.linking(
            TodoLink(type: .ticket, url: issue(7).url, label: "Issue #7"), to: item,
            now: at.addingTimeInterval(60))
        #expect(again == item)
        #expect(again.state == .ticketed)
        #expect(again.links.count == 1)
        #expect(again.updatedAt == at)
    }

    @Test func linkingDoesNotWalkWorkingOrDoneBack() {
        for state in [TodoState.working, .done] {
            let item = TodoRPC.linking(issue(1), to: TodoItem(text: "x", state: state))
            #expect(item.state == state)
            #expect(item.links.count == 1)
        }
    }

    /// A duplicate outcome links the existing issue, which ends a parked or
    /// captured item as `ticketed` like any other ticket link.
    @Test func duplicateLinkMovesAPreTicketItemToTicketed() {
        let item = TodoRPC.linking(issue(1413), to: TodoItem(text: "x", state: .captured))
        #expect(item.state == .ticketed)
    }

    @Test func sessionAndOtherLinkTypesAreNotDeduplicatedAcrossTypes() {
        let url = "https://github.com/corveil/crow/pull/5"
        var item = TodoItem(text: "x")
        item = TodoRPC.linking(TodoLink(type: .pr, url: url, label: "PR #5"), to: item)
        item = TodoRPC.linking(TodoLink(type: .custom, url: url, label: "same URL"), to: item)
        #expect(item.links.count == 2)
        #expect(item.state == .captured)
        let session = UUID()
        item = TodoRPC.linking(TodoLink(type: .session, sessionID: session, label: "a"), to: item)
        item = TodoRPC.linking(TodoLink(type: .session, sessionID: session, label: "b"), to: item)
        #expect(item.links.filter { $0.type == .session }.count == 2)
    }

    // MARK: - Outcomes that aren't tickets

    @Test func appendingNoteKeepsTheCapturedNote() {
        #expect(TodoRPC.appendingNote("Diagnosed: won't do.", to: "") == "Diagnosed: won't do.")
        #expect(TodoRPC.appendingNote("Diagnosed: won't do.", to: "pasted thread\n")
            == "pasted thread\n\nDiagnosed: won't do.")
        #expect(TodoRPC.appendingNote("  ", to: "keep") == "keep")
    }

    @Test func applyingEditAppendsNoteAfterAReplacement() throws {
        let item = TodoItem(text: "x", note: "original")
        let appended = try TodoRPC.applyingEdit(
            item, params: ["append_note": .string("Diagnosed: needs info. Which browser?")])
        #expect(appended.note == "original\n\nDiagnosed: needs info. Which browser?")
        let replacedThenAppended = try TodoRPC.applyingEdit(
            item, params: ["note": .string("new"), "append_note": .string("why")])
        #expect(replacedThenAppended.note == "new\n\nwhy")
    }

    @Test func parkingOrDroppingEndsAPendingTicketDispatch() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = TodoItem(text: "x", state: .exploring, ticketRequestedAt: at)
        #expect(TodoRPC.isTicketDispatchPending(pending, now: at))
        for state in [TodoState.parked, .dropped] {
            let next = TodoRPC.applyingState(state, to: pending, now: at)
            #expect(next.state == state)
            #expect(next.ticketRequestedAt == nil)
            #expect(!TodoRPC.isTicketDispatchPending(next, now: at))
        }
        // Other transitions keep the stamp, so the 15-minute dedupe still holds.
        for state in [TodoState.captured, .done] {
            #expect(TodoRPC.applyingState(state, to: pending, now: at).ticketRequestedAt == at)
        }
    }
}
