# 0005 — TaskBackend and CodeBackend protocols

- **Status:** Proposed
- **Date:** 2026-06-03
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
- **`CodeBackend`** — VCS side. Owns PR lifecycle: `linkedPR`, `prStates`, `ensureMergeLabel`, `fetchCrowAuthoredCommits`.

Each backend declares its **capabilities** as a `Set` (`TaskCapability` and `CodeCapability`). Callers branch on capabilities, not on provider identity. Capabilities gate UI affordances and call-site decisions; they do not by themselves guarantee a method's implementation is wired (a backend may declare a UI-facing capability while routing execution through a legacy path — see `.projectBoardStatus` on `GitHubTaskBackend`, where `IssueTracker.markInReview` performs the mutation until the `setTaskStatus` GraphQL migration lands). Examples:

```swift
// UI gating — the direct replacement for `if session.provider == .github { ... }`.
if taskBackend.capabilities.contains(.projectBoardStatus) {
    showInReviewButton()
}

// Calling a capability-gated method. Backends that declare the capability may
// still throw `.unimplemented` if their implementation is pending; callers
// that exercise the method directly must be prepared for that and either fall
// back to a legacy path or surface the error.
if taskBackend.capabilities.contains(.projectBoardStatus) {
    try await taskBackend.setTaskStatus(url: url, status: .inReview)
}
```

New backends declare what they support and the call site asks; no `switch` over a closed set of providers.

Backends take a `ShellRunner` (a thin `protocol` over `Process()` + `ShellEnvironment.shared`) at init, so unit tests inject a `FakeShellRunner` that records command vectors and returns canned JSON. The three near-duplicate `private func shell` implementations in `ProviderManager`, `IssueTracker`, and `SessionService` collapse into one `ProcessShellRunner`.

`ProviderManager` becomes a non-actor factory (`final class … : Sendable`) that hands out the right backend(s) for a session or URL. URL parsing utilities (`parseTicketURLComponents`, `detectProvider`, `classifySpec`) stay where they are. Isolation lives in the `ShellRunner` it injects, not on the factory itself.

Concrete implementations:

| Backend | Provider | Capabilities |
|---|---|---|
| `GitHubTaskBackend` | `.github` | `[projectBoardStatus, batchedQuery]` |
| `GitHubCodeBackend` | `.github` | `[autoMergeLabel, batchedPRStates]` |
| `GitLabTaskBackend` | `.gitlab` | `[]` (v1) |
| `GitLabCodeBackend` | `.gitlab` | `[]` (v1) |
| `StubCorveilTaskBackend` | `.corveil` | `[]` — every method throws `.unimplemented` |

There is no `StubCorveilCodeBackend` — Corveil has no git. A Corveil-tasked session uses a `.github` or `.gitlab` `CodeBackend`, which is the whole point of the split.

`Session.provider` remains a single optional field for v1 — code looks up both backends from the same value. A follow-up adds `Session.codeProvider: Provider?` once a real Corveil backend is implemented and cross-backend sessions are a working flow, not a theoretical one.

## Consequences

**Easier:**

- "Add a third provider" stops being a sprawling diff across `IssueTracker` and becomes a new file in `Backends/` plus a factory case.
- Behavior matrices become testable. Each backend is exercised against a `FakeShellRunner` — the regression net the codebase currently lacks.
- The parallel GitHub/GitLab halves of `listAssigned` and `prStates` stop sitting in the same file. They move to their respective backend files where their idioms (batched GraphQL vs per-MR REST) are local concerns, not global ones.
- Non-coding tasks are no longer an architectural awkwardness. A task without a `CodeBackend` is a normal session; PR-related code paths simply aren't invoked.

**Harder / accepted:**

- More indirection: a call to "remove a label" goes through `manager.taskBackend(for:) → setLabels(...)` instead of a direct `gh issue edit` shell-out. Reviewers comparing the diff to the old code path have to follow one extra hop.
- Capability flags are an enum the maintainer keeps in sync. A new capability is a two-edit change (add the case, declare it on the relevant backend) — easy to forget, hard to catch by build.
- The `Session.provider == provider` simplification limits cross-backend pairings until the `Session.codeProvider` follow-up lands. Real Corveil work blocks on that ticket.
- `setup.sh` and skill scripts continue to shell `gh`/`glab` directly — they don't run through Swift and stay out of this abstraction. A separate effort once a real Corveil backend exists.

## Alternatives considered

- **Single `TicketBackend` protocol** (the original ticket proposal). Rejected — re-encodes the task ≡ code assumption we need to break. Would make Corveil-task + GitHub-code sessions a special case rather than a natural one.
- **Throw `.unsupportedOperation`** instead of capability flags. Rejected — forces callers into try/catch when they really want to branch before calling. Capability flags also document the support matrix in one place; throwing scatters it across catch blocks.
- **Keep `ProviderManager` as an actor.** Rejected — backends are `Sendable` protocol existentials, the factory hands them out synchronously, and the only real isolation is around the shell runner (where it belongs). Making the factory itself an actor adds `await` to every call site for no concurrency benefit.
- **Closure-based shell runner.** Considered — lighter weight (just `let shell: @Sendable ([String], [String:String], String?) -> String`). Rejected in favor of a named protocol so future callers (and skills) can discover and conform to it the same way they conform to `Sendable`.

## References

- Ticket: [#410](https://github.com/radiusmethod/crow/issues/410)
- Code:
  - `Packages/CrowProvider/Sources/CrowProvider/TaskBackend.swift`
  - `Packages/CrowProvider/Sources/CrowProvider/CodeBackend.swift`
  - `Packages/CrowProvider/Sources/CrowProvider/Backends/`
  - `Packages/CrowProvider/Sources/CrowProvider/ProviderManager.swift`
  - `Packages/CrowCore/Sources/CrowCore/ShellRunner.swift`
- Follow-up tickets: AutoRespond CLI migration, UI capability checks, `Session.codeProvider` field.
