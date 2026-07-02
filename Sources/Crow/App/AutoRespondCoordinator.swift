import Foundation
import CrowCore
import CrowProvider
import CrowTerminal

/// Handles auto-respond to PR status transitions: when CrowConfig opts in
/// for a transition kind, find the session's managed terminal and inject a
/// short prompt asking Claude Code to investigate and address the issue.
///
/// Crow does not fetch review bodies or CI logs itself — the prompt asks
/// Claude to do that via `gh`/`glab`. This keeps Crow simple and avoids new
/// API scopes / rate-limit pressure.
///
/// If a transition's toggle is off, or the session has no managed terminal
/// surface, the coordinator silently skips. The caller still fires the
/// macOS notification regardless, so the user can act manually.
@MainActor
final class AutoRespondCoordinator {
    private let appState: AppState
    private let providerManager: ProviderManager
    /// Closure that returns the current `AutoRespondSettings`. Closure rather
    /// than a stored value so updates from Settings UI take effect on the
    /// next transition without explicit wiring.
    private let settingsProvider: () -> AutoRespondSettings

    init(appState: AppState, providerManager: ProviderManager, settingsProvider: @escaping () -> AutoRespondSettings) {
        self.appState = appState
        self.providerManager = providerManager
        self.settingsProvider = settingsProvider
    }

    func handle(_ transitions: [PRStatusTransition]) {
        let cfg = settingsProvider()
        for t in transitions {
            if shouldSkipReviewSession(t) {
                NSLog("[AutoRespond] Skipping %@ for session %@: review session",
                      t.kind.rawValue, t.sessionID.uuidString)
                continue
            }
            switch t.kind {
            case .changesRequested where cfg.respondToChangesRequested:
                dispatch(t)
            case .checksFailing where cfg.respondToFailedChecks:
                dispatch(t)
            default:
                continue
            }
        }
    }

    /// Review sessions exist to review someone else's PR. Auto-respond would
    /// have Crow committing on behalf of the reviewer to the branch under
    /// review — never correct. This gate is policy, independent of the
    /// `AutoRespondSettings` toggles, and applies even when both toggles are on.
    func shouldSkipReviewSession(_ transition: PRStatusTransition) -> Bool {
        appState.sessions.first(where: { $0.id == transition.sessionID })?.kind == .review
    }

    private func dispatch(_ transition: PRStatusTransition) {
        let terminals = appState.terminals(for: transition.sessionID)
        guard let terminal = terminals.first(where: { $0.isManaged }) else {
            NSLog("[AutoRespond] Skipping %@ for session %@: no managed terminal",
                  transition.kind.rawValue, transition.sessionID.uuidString)
            return
        }
        guard TerminalRouter.canSend(terminal) else {
            NSLog("[AutoRespond] Skipping %@ for session %@: terminal surface not initialized",
                  transition.kind.rawValue, transition.sessionID.uuidString)
            return
        }

        let prompt = AutoRespondPrompts.build(for: transition, codeBackend: resolveCodeBackend(forSessionID: transition.sessionID))
        NSLog("[AutoRespond] Sending %@ prompt to terminal %@ (%d chars)",
              transition.kind.rawValue, terminal.id.uuidString, prompt.count)
        TerminalRouter.send(terminal, text: prompt)
    }

    /// Manually dispatch a quick action triggered by a session-card button click.
    /// Mirrors `dispatch(_:)` but bypasses the `AutoRespondSettings` toggle —
    /// the click is the user's explicit consent. Resolves the PR URL/number
    /// from the session's `.pr` link.
    func dispatchManual(action: QuickAction, sessionID: UUID) {
        let terminals = appState.terminals(for: sessionID)
        guard let terminal = terminals.first(where: { $0.isManaged }) else {
            NSLog("[QuickAction] Skipping %@ for session %@: no managed terminal",
                  action.rawValue, sessionID.uuidString)
            return
        }
        guard TerminalRouter.canSend(terminal) else {
            NSLog("[QuickAction] Skipping %@ for session %@: terminal surface not initialized",
                  action.rawValue, sessionID.uuidString)
            return
        }
        guard let prLink = appState.links(for: sessionID).first(where: { $0.linkType == .pr }) else {
            NSLog("[QuickAction] Skipping %@ for session %@: no PR link",
                  action.rawValue, sessionID.uuidString)
            return
        }

        let prNumber = QuickActionPrompts.parsePRNumber(from: prLink.url)
        let prompt = QuickActionPrompts.build(
            action: action,
            codeBackend: resolveCodeBackend(forSessionID: sessionID),
            prURL: prLink.url,
            prNumber: prNumber
        )
        NSLog("[QuickAction] Sending %@ prompt to terminal %@ (%d chars)",
              action.rawValue, terminal.id.uuidString, prompt.count)
        TerminalRouter.send(terminal, text: prompt)
    }

    /// Resolve the `CodeBackend` to use for a session's prompt rendering.
    /// Uses `session.codeProvider ?? session.provider` per the convention in
    /// `Session.swift` (ADR 0005, #420). Falls back to GitHub when no session
    /// is found or when the resolved provider has no code surface (Corveil);
    /// `.github` always yields a non-nil backend.
    private func resolveCodeBackend(forSessionID sessionID: UUID) -> CodeBackend {
        let session = appState.sessions.first(where: { $0.id == sessionID })
        let codeProvider = session?.codeProvider ?? session?.provider ?? .github
        if let backend = providerManager.codeBackend(for: codeProvider) {
            return backend
        }
        // Corveil (or unknown) has no code surface — fall back to gh tooling.
        return providerManager.codeBackend(for: .github)!
    }
}

/// Builds the deterministic prompt text injected into a session's managed
/// terminal when an auto-respond transition fires. Each prompt:
///   1. States what just happened (and links to the PR).
///   2. Tells Claude how to fetch the relevant context via `gh`/`glab`.
///   3. Asks Claude to make local changes and push to update the PR.
///
/// Every prompt is a **single line** ending with `\n`. `TmuxBackend.sendText`
/// splits on `\n` and emits a synthetic Return key event at each boundary, so
/// a single-line payload produces exactly one text-write + one Return —
/// matching the proven pattern used by `crow send "/crow-workspace ...\n"`
/// (AppDelegate.swift:203).
enum AutoRespondPrompts {
    static func build(for transition: PRStatusTransition, codeBackend: CodeBackend) -> String {
        let prRef = transition.prNumber.map { "PR #\($0)" } ?? "the PR"
        let cli = codeBackend.cliName

        switch transition.kind {
        case .changesRequested:
            let fetchHint: String
            let reRequestHint: String
            if codeBackend.provider == .gitlab {
                fetchHint = "Run `\(cli) mr view \(transition.prURL) --comments` to read the review feedback."
                reRequestHint = "After pushing, re-request review from each reviewer who requested changes by running `\(cli) mr update \(transition.prURL) --reviewer <login>` for each one (the reviewer logins are in the review data you already fetched)."
            } else {
                let prNumStr = transition.prNumber.map(String.init) ?? "<number>"
                fetchHint = "Run `\(cli) pr view \(transition.prURL) --json reviews,comments` (and `\(cli) api repos/{owner}/{repo}/pulls/\(prNumStr)/comments` for inline comments) to read the full review feedback."
                reRequestHint = "After pushing, re-request review from each reviewer who requested changes by running `\(cli) pr edit \(transition.prURL) --add-reviewer <login>` for each one (the reviewer logins are in the review data you already fetched)."
            }
            return "Crow detected a 'changes requested' review on \(prRef) (\(transition.prURL)). \(fetchHint) Address every reviewer comment in code, commit the fix, and push so the PR updates. If a comment is unclear or you disagree, leave a reply explaining your reasoning instead of changing the code. \(reRequestHint)\n"

        case .checksFailing:
            let failedSummary: String
            if transition.failedCheckNames.isEmpty {
                failedSummary = ""
            } else {
                let names = transition.failedCheckNames.prefix(5).joined(separator: ", ")
                let extra = transition.failedCheckNames.count > 5 ? " (+\(transition.failedCheckNames.count - 5) more)" : ""
                failedSummary = " Failing checks: \(names)\(extra)."
            }
            let logHint: String
            if codeBackend.provider == .gitlab {
                logHint = "Run `\(cli) ci view` / `\(cli) ci trace` on the failing pipeline to read the logs."
            } else {
                logHint = "Run `\(cli) pr checks \(transition.prURL)` to list the failing checks, then `\(cli) run view --log-failed <run-id>` to read the failure output."
            }
            return "Crow detected failing CI checks on \(prRef) (\(transition.prURL)).\(failedSummary) \(logHint) Identify the root cause, fix it locally, run the relevant tests, then commit and push so CI re-runs.\n"
        }
    }
}

/// Builds prompts for **manually-triggered** quick actions on a session
/// card. Same single-line + `\n` contract as `AutoRespondPrompts`. The
/// `addressChanges` and `fixChecks` cases delegate to `AutoRespondPrompts`
/// so the auto and manual paths share a single source of truth.
enum QuickActionPrompts {
    static func build(action: QuickAction, codeBackend: CodeBackend, prURL: String, prNumber: Int?) -> String {
        let prRef = prNumber.map { "PR #\($0)" } ?? "the PR"
        let cli = codeBackend.cliName

        switch action {
        case .addressChanges:
            // Reuse the existing changes-requested prompt verbatim.
            let synthetic = PRStatusTransition(
                kind: .changesRequested,
                sessionID: UUID(), // unused by AutoRespondPrompts.build
                prURL: prURL,
                prNumber: prNumber
            )
            return AutoRespondPrompts.build(for: synthetic, codeBackend: codeBackend)

        case .fixChecks:
            // Reuse the existing checks-failing prompt verbatim. We don't
            // know the failing check names from a manual click; the prompt
            // tells Claude how to discover them.
            let synthetic = PRStatusTransition(
                kind: .checksFailing,
                sessionID: UUID(),
                prURL: prURL,
                prNumber: prNumber
            )
            return AutoRespondPrompts.build(for: synthetic, codeBackend: codeBackend)

        case .fixConflicts:
            let rebaseHint: String
            if codeBackend.provider == .gitlab {
                rebaseHint = "Rebase your branch onto the latest target branch (`git fetch origin && git rebase origin/<target>` or `\(cli) mr rebase`), resolve the conflicts in the affected files, run the relevant tests, then force-push with `--force-with-lease` to update the MR."
            } else {
                rebaseHint = "Rebase your branch onto the latest base branch (`git fetch origin && git rebase origin/<base>`), resolve the conflicts in the affected files, run the relevant tests, then force-push with `--force-with-lease` to update the PR."
            }
            return "Crow detected merge conflicts on \(prRef) (\(prURL)). \(rebaseHint)\n"

        case .mergePR:
            let mergeHint: String
            if codeBackend.provider == .gitlab {
                mergeHint = "Run `\(cli) mr view \(prURL)` to verify the MR is in the expected state, then `\(cli) mr merge \(prURL)` to merge. If the project uses a different merge strategy or extra steps, adjust accordingly."
            } else {
                mergeHint = "Run `\(cli) pr view \(prURL)` to verify the PR is in the expected state, then `cd \"$TMPDIR\" && \(cli) pr merge \(prURL) --squash --delete-branch` to merge. The `cd` keeps `gh`'s post-merge git cleanup (which runs in the CWD) from tripping when `main` is checked out in another worktree. If the repo uses a different merge strategy, adjust accordingly."
            }
            return "Merge \(prRef) (\(prURL)). \(mergeHint)\n"
        }
    }

    /// Extract the trailing numeric segment from a PR/MR URL (e.g.
    /// `https://github.com/org/repo/pull/123` → `123`,
    /// `https://gitlab.example.com/org/repo/-/merge_requests/45` → `45`).
    /// Returns nil if the last path component isn't an integer.
    static func parsePRNumber(from url: String) -> Int? {
        guard let last = url.split(separator: "/").last else { return nil }
        return Int(last)
    }
}
