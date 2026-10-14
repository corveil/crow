import CrowCore
import Foundation

/// In-memory `(request id, head SHA)` dedupe for the auto-review watcher.
///
/// The fingerprint is inserted synchronously when a kickoff is accepted, so
/// a second poll during the clone cannot enqueue a duplicate. It is removed
/// if that kickoff returns nil — metadata failure, clone failure, or the
/// serializer's timeout — so the same head is retried on a later poll
/// (CROW-1323). A non-nil id (created, re-reviewed, or an already-live
/// session) keeps the fingerprint until the head changes or the daemon
/// restarts. `createReviewSession` still refuses to duplicate a live round,
/// so a restart's worst case is one redundant metadata fetch.
final class AutoReviewKickoffQueue: @unchecked Sendable {
    let serializer: ReviewKickoffSerializer
    private let lock = NSLock()
    private var fingerprints: Set<String> = []

    init(serializer: ReviewKickoffSerializer) {
        self.serializer = serializer
    }

    /// Filter `requests` to `patterns` and enqueue one kickoff per new head.
    /// Returns immediately; each kickoff runs on `serializer`.
    func schedule(
        requests: [ReviewRequest],
        patterns: [String],
        kickoff: @escaping @Sendable (String) async -> UUID?
    ) {
        for request in requests {
            guard repoMatchesPatterns(request.repo, patterns: patterns) else { continue }
            let fingerprint = Self.fingerprint(id: request.id, head: request.headRefOid)
            guard insert(fingerprint) else { continue }
            let url = request.url
            let serializer = self.serializer
            Task {
                let task = await serializer.enqueue(url: url) { await kickoff(url) }
                if await task.value == nil {
                    self.remove(fingerprint)
                }
            }
        }
    }

    func contains(requestID: String, head: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fingerprints.contains(Self.fingerprint(id: requestID, head: head))
    }

    private static func fingerprint(id: String, head: String?) -> String {
        "\(id)\n\(head ?? "")"
    }

    private func insert(_ fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fingerprints.insert(fingerprint).inserted
    }

    private func remove(_ fingerprint: String) {
        lock.lock()
        fingerprints.remove(fingerprint)
        lock.unlock()
    }
}
