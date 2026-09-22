import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

// MARK: - Auto-merge label memo (CROW-1286)
//
// The `crow:merge` label-ensure memo, split out of `AutoMergeController`. Two
// entry points with two error policies: `ensureMergeLabelOnce` throws exactly
// what the backend throws (so `addMergeLabel` reports a real failure — CROW-816)
// and memoizes only on success; `ensureMergeLabel` is the watcher's best-effort
// wrapper and swallows. `mergeLabelMemoKey` stays private — only these two
// callers use it — while `ensureMergeLabel` is internal so the enable path in
// `AutoMergeController+Attempts` reaches it.
extension AutoMergeController {
    /// Memo key for ``ensuredMergeLabelRepos`` / ``ensureMergeLabelTasks``.
    private static func mergeLabelMemoKey(provider: Provider, repo: String) -> String {
        "\(provider.rawValue)\n\(repo)"
    }

    /// Ensure the `crow:merge` label exists in `repo`, at most once per
    /// (provider, repo) per process (#931).
    ///
    /// **Throws exactly what the backend throws.** The memo is a latency
    /// optimization, not a policy change: `addMergeLabel` calls this directly
    /// and must keep reporting a real label-creation failure (CROW-816), so the
    /// throwing form is the primitive and the watcher's best-effort behaviour
    /// is a `do`/`catch` on top of it — not the other way round.
    func ensureMergeLabelOnce(repo: String, backend: CodeBackend) async throws {
        guard !repo.isEmpty else { return }
        guard backend.capabilities.contains(.autoMergeLabel) else { return }
        let key = Self.mergeLabelMemoKey(provider: backend.provider, repo: repo)
        if ensuredMergeLabelRepos.contains(key) { return }
        if let inFlight = ensureMergeLabelTasks[key] {
            // Join the existing call rather than issuing a duplicate. Awaiting
            // `.value` rethrows its error, so a joiner sees the same outcome an
            // originator would; the originator owns the map cleanup.
            try await inFlight.value
            return
        }
        let task = Task { @MainActor in try await backend.ensureMergeLabel(repo: repo) }
        ensureMergeLabelTasks[key] = task
        defer { ensureMergeLabelTasks[key] = nil }
        try await task.value
        // Reached only on success — see `ensuredMergeLabelRepos`.
        ensuredMergeLabelRepos.insert(key)
    }

    /// Best-effort: ensure the `crow:merge` label exists in the repo so
    /// repo owners don't need to pre-create it. The backend swallows the
    /// "already exists" failure; this swallows the rest, because the auto-merge
    /// watcher's next step (`enableAutoMerge`) reports its own failures and a
    /// missing label is not on its own a reason to abandon the attempt.
    func ensureMergeLabel(repo: String, backend: CodeBackend) async {
        do {
            try await ensureMergeLabelOnce(repo: repo, backend: backend)
        } catch {
            // Best-effort — swallow.
        }
    }
}
