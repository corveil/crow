import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// CROW-1306: `crow:merge` and `ci:full` are different actions. Adding the
/// merge label — including on a PR the last poll already saw a `CI Gate`
/// check on — must not create or apply `ci:full`. The approver's
/// `crow-review-pr` skill does that, and only after `--approve`.
@Suite("add-merge-label does not add ci:full (CROW-1306)")
@MainActor
struct IssueTrackerAddMergeLabelCIFullTests {
    private final class RecordingShell: ShellRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []

        func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
            lock.withLock { recorded.append(args) }
            return ""
        }

        func calls() -> [[String]] { lock.withLock { recorded } }
    }

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1306-merge-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    @Test func addMergeLabelOnACIGatePRDoesNotAddCIFull() async throws {
        let shell = RecordingShell()
        let state = AppState()
        let session = Session(name: "feature/ci-full", kind: .work, provider: .github)
        let prURL = "https://github.com/corveil/corveil/pull/3785"
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #3785", url: prURL, linkType: .pr)
        ]
        // The condition #1300 used to attach `ci:full` to this call.
        state.prStatus[session.id] = PRStatus(checksPass: .failing, usesCIGate: true)
        let tracker = IssueTracker(
            appState: state,
            providerManager: ProviderManager(shellRunner: shell),
            store: Self.tempStore())

        _ = try await tracker.addMergeLabel(sessionID: session.id)

        let calls = shell.calls()
        #expect(calls.contains { args in
            args.contains("--add-label") && args.contains("crow:merge")
        })
        #expect(!calls.contains { args in
            args.contains { $0.localizedCaseInsensitiveContains("ci:full") }
        })
        #expect(state.prStatus[session.id]?.hasMergeLabel == true)
        #expect(state.prStatus[session.id]?.usesCIGate == true)
    }
}
