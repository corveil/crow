# 0012 — Tests must never touch live application data

- **Status:** Accepted
- **Date:** 2026-07-19
- **Deciders:** @dgershman

## Context

Crow persists sessions, worktrees, terminals, and links to a single JSON file at
`~/Library/Application Support/crow/store.json`, owned by `JSONStore`. `JSONStore`
defaults its directory to that live App Support path when constructed with no
`directory:` argument (`JSONStore(directory: URL? = nil)`), and `mutate` is a
read-modify-write of the *entire* `StoreData` snapshot.

Those two facts combined are a footgun for tests. `SessionAnalyticsStripLiveTests`
constructed a bare `JSONStore()` and did `data.sessions = [session]` inside
`mutate` — reading the developer's N real sessions and replacing them with one
throwaway fixture named `"s"`. Running `swift test --package-path Packages/CrowDaemon`
(and therefore `make test`) on a machine with a real Crow install silently wiped
the session list; the suite still passed green (#764). This is the same
full-snapshot-overwrite class as the intra-process clobber (#728) and the
cross-process lock gap (#759), but a third variant: **a test opening the live
store path**.

Convention ("tests should pass a temp `directory:`") had already been followed by
most suites, but one slip destroyed live data with no signal. The offending
fixture's single-letter name (`"s"`) read like corrupted data rather than test
output, so it wasn't even obvious a *test* had done it — costing investigation
time.

## Decision

Tests never read or write the live data store. This is enforced structurally, not
by convention:

1. **`JSONStore.init` traps under a test process** when constructed with the
   default (nil) directory. Detection covers the runners Crow's suites use: the
   swift-testing SwiftPM host (`swift test` / `make test`) runs as
   `swiftpm-testing-helper`, and XCTest/Xcode hosts link `XCTestCase`, set
   `XCTestConfigurationFilePath`, and run from an `.xctest` bundle. None of those
   signals appear in the shipping `crowd`/app binaries. Only the default path is
   gated — explicit `directory:` constructions and production are unaffected.
2. **No production API defaults its store to the live path.** `IssueTracker`'s
   `store: JSONStore = JSONStore()` default is removed; callers inject explicitly
   (production already does; tests pass a temp store). Compile-time enforcement is
   preferred over relying on the runtime trap.
3. **Tests inject an isolated temp store**, via the `JSONStore.temporary()` helper
   (a unique `NSTemporaryDirectory()/crow-test-<uuid>` directory).
4. **Persisted test fixtures use self-identifying sentinel names** (e.g.
   `__TEST__SessionAnalyticsStrip`), so any record that ever reaches a real store
   despite the guardrail names itself as test data and points at its suite, rather
   than masquerading as corruption.

## Consequences

- A bare `JSONStore()` in a test now fails loudly and immediately with an
  actionable message, instead of silently mutating live data. Reintroducing the
  bug is impossible to miss.
- New test authors get a compile error (missing `store:` on `IssueTracker`) or a
  fatal error (bare `JSONStore()`) that both point at the right fix.
- The guardrail is a heuristic on "am I under a test runner," not a hard
  capability boundary. It relies on production binaries never running as
  `swiftpm-testing-helper`/`xctest` nor linking XCTest — true today for `crowd`
  and the app. A future target that runs tests through a different host would need
  to extend the detector.
- One extra indirection in tests (`JSONStore.temporary()` instead of
  `JSONStore()`), which also makes the isolation intent explicit at the call site.

## Alternatives considered

- **Convention only ("remember to pass a temp dir").** This is what we had; one
  slip wiped live data with a green suite. Rejected — the failure mode is silent
  and destructive.
- **A separate test-only `JSONStore` subclass/type.** More surface area and a
  parallel type to keep in sync; the nil-directory trap achieves the same
  guarantee against the real type callers actually use.
- **Redirect App Support to a temp dir for the whole test process (env/`HOME`
  override).** Fragile across runners and hides the real defect (a test reaching
  for the live path at all); the trap makes that reach an error rather than
  quietly relocating it.

## References

- PR: https://github.com/corveil/crow/pull/765
- Ticket: https://github.com/corveil/crow/issues/764
- Related: #728 (intra-process throwaway clobber), #759 (cross-process store lock)
- Code:
  - `Packages/CrowPersistence/Sources/CrowPersistence/JSONStore.swift` (init guardrail)
  - `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` (dropped live-store default)
  - `Packages/CrowDaemon/Tests/CrowDaemonTests/JSONStore+Temporary.swift` (`temporary()` helper)
