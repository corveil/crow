# 0005 — TaskBackend and CodeBackend protocols

- **Status:** Accepted (foundation #411, migration #454)
- **Date:** 2026-06-03 (proposed), 2026-06-07 (accepted)
- **Deciders:** Crow maintainers

## Context

Crow integrates with two ticket/PR providers today (`gh` for GitHub, `glab` for GitLab) by shelling out from many call sites scattered across `IssueTracker.swift`, `SessionService.swift`, and `ProviderManager.swift`. An audit in [#410](https://github.com/radiusmethod/crow/issues/410) found three coexisting patterns:

1. **Switch-at-callsite**: `switch provider { gh / glab }` inline (e.g. `IssueTracker.swift:493`).
2. **Parallel implementations**: one fat GitHub function and one fat GitLab function sitting in the same file — conceptually one operation, two halves (e.g. assigned-issue fetch at `IssueTracker.swift:703` and `:2509`).
3. **GitHub-only paths**: code gated on `session.provider == .github` that silently no-ops for GitLab (project-board status at `:2542`, merge-label create at `:2038`).

Two future shifts make this untenable:

- **Corveil** is being added as a third provider, with no embedded git.
- The ticket framework will expand to **non-coding tasks** where no PR is involved at all.

A non-coding task in Corveil paired with a `.github` PR (or `.gitlab` MR) is a legitimate session shape. So "provider" is not a single dimension — it has two: where the work-unit lives (task tracker) and where the code lives (VCS host). Lumping them into a single `TicketBackend` protocol would re-encode the very assumption we need to dissolve.

## Decision

Crow exposes two independent protocols under `CrowProvider`:

- **`TaskBackend`** — tracker side. Owns issue/task lifecycle: `fetchTask`, `listAssigned`, `setLabels`, `setTaskStatus`, `assign`, `createTask`.
- **`CodeBackend`** — VCS side. Owns PR lifecycle: `linkedPR`, `listMonitoredPRs`, `prStates`, `ensureMergeLabel`, `fetchCrowAuthoredCommits`, `findRecentPRsForBranches`, `enableAutoMerge`, `updateBranch`, `fetchPRMetadata`.

The `CodeBackend` surface grew beyond the original spec (`linkedPR`, `prStates`, `ensureMergeLabel`, `fetchCrowAuthoredCommits`) during the #454 migration so that every direct `gh`/`glab` shell-out in `IssueTracker.swift` could route through the abstraction. `enableAutoMerge`, `updateBranch`, `findRecentPRsForBranches`, `listMonitoredPRs`, and `fetchPRMetadata` are operational primitives — not new abstractions — that the grep-empty acceptance test required. They're capability-gated where the operation isn't universal (GitLab declares no `.autoMerge` / `.updateBranch`); the methods throw `ProviderError.unimplemented` for backends without the capability.

Each backend declares its **capabilities** as a `Set` (`TaskCapability` and `CodeCapability`). Callers branch on capabilities, not on provider identity. Capabilities gate UI affordances **and** guarantee the relevant method is wired — after #454 there is no longer an "I declare it but don't implement it" caveat. Examples:

```swift
// UI gating — the direct replacement for `if session.provider == .github { ... }`.
if taskBackend.capabilities.contains(.projectBoardStatus) {
    showInReviewButton()
}

// Calling a capability-gated method. With the #454 migration in place, the
// capability flag is both the UI guard AND the implementation guarantee:
// GitHubTaskBackend.setTaskStatus now performs the GraphQL mutation
// directly (no more IssueTracker.markInReview escape-hatch).
if taskBackend.capabilities.contains(.projectBoardStatus) {
    try await taskBackend.setTaskStatus(url: url, status: .inReview)
}
```

New backends declare what they support and the call site asks; no `switch` over a closed set of providers.

Backends take a `ShellRunner` (a thin `protocol` over `Process()` + `ShellEnvironment.shared`) at init, so unit tests inject a `FakeShellRunner` that records command vectors and returns canned JSON. The three near-duplicate `private func shell` implementations in `ProviderManager`, `IssueTracker`, and `SessionService` collapse into one `ProcessShellRunner`.

`ProviderManager` is a non-actor factory (`final class … : Sendable`) that hands out the right backend(s) for a session or URL. URL parsing utilities (`parseTicketURLComponents`, `detectProvider`, `classifySpec`) stay where they are. Isolation lives in the `ShellRunner` it injects, not on the factory itself.

Concrete implementations:

| Backend | Provider | Capabilities |
|---|---|---|
| `GitHubTaskBackend` | `.github` | `[projectBoardStatus, batchedQuery]` |
| `GitHubCodeBackend` | `.github` | `[autoMergeLabel, batchedPRStates, autoMerge, updateBranch]` |
| `GitLabTaskBackend` | `.gitlab` | `[]` |
| `GitLabCodeBackend` | `.gitlab` | `[]` |
| `StubCorveilTaskBackend` | `.corveil` | `[]` — every method throws `.unimplemented` |

There is no `StubCorveilCodeBackend` — Corveil has no git. A Corveil-tasked session uses a `.github` or `.gitlab` `CodeBackend`, which is the whole point of the split.

`Session.provider` remains a single optional field — code looks up both backends from the same value. A follow-up adds `Session.codeProvider: Provider?` once a real Corveil backend is implemented and cross-backend sessions are a working flow, not a theoretical one.

## Migration status

Method-by-method state as of the #454 PR. "Site" is where the implementation lives (no parenthetical means it's in the backend file itself).

### TaskBackend

| Method | GitHub | GitLab | Corveil | Notes |
|---|---|---|---|---|
| `fetchTask` | ✅ | ✅ | throws | shipped #411 |
| `setLabels` | ✅ | ✅ | throws | shipped #411 |
| `setTaskStatus` | ✅ (#454) | throws (no cap) | throws | #454 closed the escape-hatch — `IssueTracker.markInReview` no longer runs a parallel GraphQL mutation |
| `listAssigned` | ✅ (#454) | ✅ (#454) | throws | GitHub batches open+closed in one GraphQL call; GitLab issues two REST calls |
| `assign` | ✅ (#454) | ✅ (#454) | throws | for `setup.sh` and skill flows |
| `createTask` | ✅ (#454) | ✅ (#454) | throws | for `/crow-create-ticket` |

### CodeBackend

| Method | GitHub | GitLab | Notes |
|---|---|---|---|
| `linkedPR` | ✅ | ✅ | shipped #411 |
| `ensureMergeLabel` | ✅ (cap-gated) | throws (no cap) | shipped #411; `.autoMergeLabel` gates |
| `listMonitoredPRs` | ✅ (#454) | partial | GitHub returns viewer PRs + review-requested in one GraphQL call; GitLab returns review-requested only (no `viewerPRs` analogue today) |
| `prStates` | ✅ (#454, batched) | ✅ (#454, per-MR) | `.batchedPRStates` declared only by GitHub |
| `fetchCrowAuthoredCommits` | ✅ (#454) | ✅ (#454) | callers filter by `Crow-Session:` trailer |
| `findRecentPRsForBranches` | ✅ (#454, batched) | ✅ (#454, per-candidate) | reconcile path |
| `enableAutoMerge` | ✅ (#454, cap-gated) | throws (no cap) | `.autoMerge` gates |
| `updateBranch` | ✅ (#454, cap-gated) | throws (no cap) | `.updateBranch` gates |
| `fetchPRMetadata` | ✅ (#454) | ✅ (#454) | used by `SessionService.prepareReviewClone` |

After #454, `rg '"gh"|"glab"|gh api|glab api' Sources/Crow/App/IssueTracker.swift` returns zero matches — the acceptance signal for "the abstraction is the actual runtime path, not just the API."

## Consequences

**Easier:**

- "Add a third provider" stops being a sprawling diff across `IssueTracker` and becomes a new file in `Backends/` plus a factory case.
- Behavior matrices become testable. Each backend is exercised against a `FakeShellRunner` — the regression net the codebase previously lacked.
- The parallel GitHub/GitLab halves of `listAssigned`, `prStates`, `findRecentPRsForBranches`, etc. stop sitting in the same file. They moved to their respective backend files where their idioms (batched GraphQL vs per-MR REST) are local concerns, not global ones.
- Non-coding tasks are no longer an architectural awkwardness. A task without a `CodeBackend` is a normal session; PR-related code paths simply aren't invoked.
- Capability flags now mean what they say. A backend that declares `.projectBoardStatus` actually implements `setTaskStatus` — no more "the UI guard is the capability but the implementation lives elsewhere."

**Harder / accepted:**

- More indirection: a call to "remove a label" goes through `manager.taskBackend(for:) → setLabels(...)` instead of a direct `gh issue edit` shell-out. Reviewers comparing the diff to the old code path have to follow one extra hop.
- Capability flags are an enum the maintainer keeps in sync. A new capability is a two-edit change (add the case, declare it on the relevant backend) — easy to forget, hard to catch by build.
- The `Session.provider == provider` simplification limits cross-backend pairings until the `Session.codeProvider` follow-up lands. Real Corveil work blocks on that ticket.
- `setup.sh` and skill scripts continue to shell `gh`/`glab` directly — they don't run through Swift and stay out of this abstraction. A separate effort once a real Corveil backend exists.
- The GitHub viewer's consolidated query is now split across two calls (`listAssigned` for issues, `listMonitoredPRs` for PRs + reviews). One extra GraphQL round-trip per polling cycle (negligible against the ~5000/hour rate limit budget). The trade buys clean task/code separation in the protocol surface.

## Alternatives considered

- **Single `TicketBackend` protocol** (the original ticket proposal). Rejected — re-encodes the task ≡ code assumption we need to break. Would make Corveil-task + GitHub-code sessions a special case rather than a natural one.
- **Throw `.unsupportedOperation`** instead of capability flags. Rejected — forces callers into try/catch when they really want to branch before calling. Capability flags also document the support matrix in one place; throwing scatters it across catch blocks.
- **Keep `ProviderManager` as an actor.** Rejected — backends are `Sendable` protocol existentials, the factory hands them out synchronously, and the only real isolation is around the shell runner (where it belongs). Making the factory itself an actor adds `await` to every call site for no concurrency benefit.
- **Closure-based shell runner.** Considered — lighter weight (just `let shell: @Sendable ([String], [String:String], String?) -> String`). Rejected in favor of a named protocol so future callers (and skills) can discover and conform to it the same way they conform to `Sendable`.
- **Keep the consolidated GraphQL query as a single `listAssigned` returning a mixed envelope** (issues + viewerPRs + reviewRequests). Rejected during #454 in favor of splitting `listAssigned` (TaskBackend) and `listMonitoredPRs` (CodeBackend). The protocol-purity win was worth one extra round-trip per minute.

## References

- Tickets: [#410](https://github.com/radiusmethod/crow/issues/410) (foundation, closed via #411), [#454](https://github.com/radiusmethod/crow/issues/454) (migration)
- PRs: #411 (foundation), the PR closing #454 (migration)
- Code:
  - `Packages/CrowProvider/Sources/CrowProvider/TaskBackend.swift`
  - `Packages/CrowProvider/Sources/CrowProvider/CodeBackend.swift`
  - `Packages/CrowProvider/Sources/CrowProvider/BackendTypes.swift`
  - `Packages/CrowProvider/Sources/CrowProvider/Backends/`
  - `Packages/CrowProvider/Sources/CrowProvider/ProviderManager.swift`
  - `Packages/CrowCore/Sources/CrowCore/ShellRunner.swift`
- Follow-up tickets: real Corveil `TaskBackend`, `Session.codeProvider` field for cross-backend pairings, `setup.sh` / skill migration off direct `gh`/`glab`.
