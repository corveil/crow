import SwiftUI
import CrowCore

// MARK: - Shared Delete Session Alert

/// View modifier that attaches a delete-session confirmation alert.
/// Used by both SessionListView (sidebar context menu) and SessionDetailView (header button).
struct DeleteSessionAlert: ViewModifier {
    @Binding var sessionToDelete: Session?
    let appState: AppState

    func body(content: Content) -> some View {
        content.alert("Delete Session?", isPresented: Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
            Button(buttonLabel, role: .destructive) {
                if let session = sessionToDelete {
                    Task {
                        do {
                            try await appState.onDeleteSession?(session.id)
                        } catch {
                            NSLog("Failed to delete session \(session.name): \(error)")
                        }
                    }
                    sessionToDelete = nil
                }
            }
        } message: {
            Text(messageText)
        }
    }

    private var buttonLabel: String {
        guard let session = sessionToDelete else { return "Delete" }
        let wts = appState.worktrees(for: session.id)
        let hasRealWorktrees = wts.contains { !$0.isMainRepoCheckout }
        return DeleteSessionMessageBuilder.buttonLabel(hasRealWorktrees: hasRealWorktrees)
    }

    private var messageText: String {
        guard let session = sessionToDelete else { return "" }
        let wts = appState.worktrees(for: session.id)
        let realWorktrees = wts.filter { !$0.isMainRepoCheckout }
        let mainCheckouts = wts.filter { $0.isMainRepoCheckout }
        return DeleteSessionMessageBuilder.buildMessage(
            sessionName: session.name,
            realWorktrees: realWorktrees,
            mainCheckouts: mainCheckouts
        )
    }
}

extension View {
    func deleteSessionAlert(session: Binding<Session?>, appState: AppState) -> some View {
        modifier(DeleteSessionAlert(sessionToDelete: session, appState: appState))
    }
}

// MARK: - Delete Session Message Builder

/// Testable logic for generating delete-session confirmation messages.
enum DeleteSessionMessageBuilder {
    static func buttonLabel(hasRealWorktrees: Bool) -> String {
        hasRealWorktrees ? "Delete Everything" : "Remove Session"
    }

    static func buildMessage(
        sessionName: String,
        realWorktrees: [SessionWorktree],
        mainCheckouts: [SessionWorktree]
    ) -> String {
        let hasWorktrees = !realWorktrees.isEmpty || !mainCheckouts.isEmpty

        if !hasWorktrees {
            return "This will remove the session \"\(sessionName)\"."
        } else if realWorktrees.isEmpty {
            return "This will remove the session \"\(sessionName)\".\n\nThe repository folder and branch (\(mainCheckouts.map(\.branch).joined(separator: ", "))) will not be affected."
        } else if mainCheckouts.isEmpty {
            return "This will delete:\n\n" +
                realWorktrees.map { "  \u{2022} Worktree: \($0.worktreePath)\n  \u{2022} Branch: \($0.branch)" }
                    .joined(separator: "\n\n") +
                "\n\nThe worktree folders and git branches will be removed from disk."
        } else {
            return "This will delete:\n\n" +
                realWorktrees.map { "  \u{2022} Worktree: \($0.worktreePath)\n  \u{2022} Branch: \($0.branch)" }
                    .joined(separator: "\n\n") +
                "\n\nThe worktree folders and branches above will be removed.\n\nThe main repo (\(mainCheckouts.map(\.branch).joined(separator: ", "))) will not be affected."
        }
    }

    /// Build a confirmation message summarising a bulk delete of several sessions.
    /// `worktreesBySession` maps each session ID to its full worktree list.
    static func buildBulkMessage(
        sessions: [Session],
        worktreesBySession: [UUID: [SessionWorktree]]
    ) -> String {
        let count = sessions.count
        let sessionNoun = count == 1 ? "session" : "sessions"

        var realCount = 0
        var mainCount = 0
        for session in sessions {
            let wts = worktreesBySession[session.id] ?? []
            for wt in wts {
                if wt.isMainRepoCheckout {
                    mainCount += 1
                } else {
                    realCount += 1
                }
            }
        }

        if realCount == 0 && mainCount == 0 {
            return "This will remove \(count) \(sessionNoun)."
        }

        var parts: [String] = []
        parts.append("This will delete \(count) \(sessionNoun).")

        if realCount > 0 {
            let worktreeNoun = realCount == 1 ? "worktree" : "worktrees"
            parts.append("\(realCount) \(worktreeNoun) and matching git branches will be removed from disk.")
        }
        if mainCount > 0 {
            let checkoutNoun = mainCount == 1 ? "main repo checkout" : "main repo checkouts"
            parts.append("\(mainCount) \(checkoutNoun) will not be affected.")
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Bulk Delete Sessions Alert

/// View modifier that attaches a bulk delete-sessions confirmation alert.
/// Fans out `selectedIDs` concurrently through `appState.onDeleteSession` so
/// the UI doesn't wait N×single-delete to repaint.
struct BulkDeleteSessionsAlert: ViewModifier {
    @Binding var isPresented: Bool
    let selectedIDs: Set<UUID>
    let appState: AppState
    let onCompletion: () -> Void

    func body(content: Content) -> some View {
        content.alert("Delete Sessions?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(buttonLabel, role: .destructive) {
                let snapshot = sortedSnapshot
                Task {
                    // Fan each delete out as its own Task so they run concurrently.
                    // SessionService.deleteSession yields the main actor while its
                    // disk/git cleanup runs on a detached task, so all selected
                    // sessions clean up in parallel rather than serially.
                    var tasks: [Task<Void, Never>] = []
                    for id in snapshot {
                        tasks.append(Task {
                            do {
                                try await appState.onDeleteSession?(id)
                            } catch {
                                NSLog("Failed to delete session \(id): \(error)")
                            }
                        })
                    }
                    for t in tasks { await t.value }
                    onCompletion()
                }
            }
        } message: {
            Text(messageText)
        }
    }

    private var sortedSnapshot: [UUID] {
        // Stable order: sessions first in the order they currently appear in AppState.
        let order = Dictionary(uniqueKeysWithValues: appState.sessions.enumerated().map { ($1.id, $0) })
        return selectedIDs.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
    }

    private var selectedSessions: [Session] {
        appState.sessions.filter { selectedIDs.contains($0.id) }
    }

    private var hasRealWorktrees: Bool {
        selectedSessions.contains { session in
            appState.worktrees(for: session.id).contains { !$0.isMainRepoCheckout }
        }
    }

    private var buttonLabel: String {
        let base = DeleteSessionMessageBuilder.buttonLabel(hasRealWorktrees: hasRealWorktrees)
        return "\(base) (\(selectedIDs.count))"
    }

    private var messageText: String {
        let sessions = selectedSessions
        var map: [UUID: [SessionWorktree]] = [:]
        for session in sessions {
            map[session.id] = appState.worktrees(for: session.id)
        }
        return DeleteSessionMessageBuilder.buildBulkMessage(
            sessions: sessions,
            worktreesBySession: map
        )
    }
}

extension View {
    func bulkDeleteSessionsAlert(
        isPresented: Binding<Bool>,
        selectedIDs: Set<UUID>,
        appState: AppState,
        onCompletion: @escaping () -> Void
    ) -> some View {
        modifier(BulkDeleteSessionsAlert(
            isPresented: isPresented,
            selectedIDs: selectedIDs,
            appState: appState,
            onCompletion: onCompletion
        ))
    }
}

