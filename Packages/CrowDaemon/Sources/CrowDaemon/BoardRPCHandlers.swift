import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// Ticket / review board reads and actions.
///
/// Extracted from `makeCommandRouter`'s dictionary literal (CROW-1134).
func makeBoardHandlers(
    appState: AppState,
    tracker: IssueTracker?,
    sessionService: SessionService?,
    reviewSerializer: ReviewKickoffSerializer
) -> [String: CommandRouter.Handler] {
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134).
    let handlers: [String: CommandRouter.Handler] = [
        // Board reads. When the daemon owns the tracker (CROW-581 M-C) they
        // answer locally off `appState` — populated by the daemon's own
        // IssueTracker — so the boards work with the app down.
        // Without that service (tests, stripped builds) they fall back to
        // forwarding to the app / an empty board, like get-pr-status. NOTE: while
        // both the app and daemon run, each polls its providers → transient
        // double-polling until the app becomes a pure client (Milestone F).
        "list-tickets": { _ in
            if tracker != nil {
                return await MainActor.run {
                    let fmt = ISO8601DateFormatter()
                    let issues: [JSONValue] = appState.filteredAssignedIssues.map { issue in
                        let status = issue.projectStatus == .unknown ? TicketStatus.backlog : issue.projectStatus
                        let linked = appState.linkedSession(for: issue)
                        return .object([
                            "id": .string(issue.id),
                            "number": .int(issue.number),
                            "title": .string(issue.title),
                            "state": .string(issue.state),
                            "url": .string(issue.url),
                            "repo": .string(issue.repo),
                            "provider": .string(issue.provider.rawValue),
                            "pr_number": issue.prNumber.map { .int($0) } ?? .null,
                            "pr_url": issue.prURL.map { .string($0) } ?? .null,
                            "updated_at": issue.updatedAt.map { .string(fmt.string(from: $0)) } ?? .null,
                            "project_status": .string(status.rawValue),
                            "labels": .array(issue.labels.map { .object(["name": .string($0.name), "color": $0.color.map { .string($0) } ?? .null]) }),
                            // Richer board detail (#751) — all optional/back-compatible.
                            "body": issue.body.map { .string($0) } ?? .null,
                            "author": issue.author.map { .string($0) } ?? .null,
                            "created_at": issue.createdAt.map { .string(fmt.string(from: $0)) } ?? .null,
                            "comments_count": issue.commentsCount.map { .int($0) } ?? .null,
                            "pr_state": issue.prState.map { .string($0) } ?? .null,
                            "checks": issue.checksState.map { .object(["state": .string($0), "failed": .array((issue.failedCheckNames ?? []).map { .string($0) })]) } ?? .null,
                            "linked_session_id": linked.map { .string($0.id.uuidString) } ?? .null,
                            "linked_session_is_explore": linked.map { .bool($0.isExplore) } ?? .null,
                        ])
                    }
                    var counts: [String: JSONValue] = [:]
                    for status in TicketStatus.pipelineStatuses {
                        counts[status.rawValue] = .int(appState.issueCount(for: status))
                    }
                    counts["All"] = .int(appState.filteredAssignedIssues.count)
                    return [
                        "issues": .array(issues),
                        "counts": .object(counts),
                        "done_last_24h": .int(appState.doneIssuesLast24h),
                        "loading": .bool(appState.isLoadingIssues),
                    ]
                }
            }
            let empty: [String: JSONValue] = [
                "issues": .array([]), "counts": .object([:]),
                "done_last_24h": .int(0), "loading": .bool(false),
            ]
            return empty
        },
        "list-reviews": { _ in
            if tracker != nil {
                return await MainActor.run { ReviewsPayload.build(appState: appState) }
            }
            let empty: [String: JSONValue] = ["reviews": .array([]), "loading": .bool(false), "unseen": .int(0)]
            return empty
        },

        // Board actions — forward-only (need the app's coordinators to spawn
        // workspaces). Error when the app isn't running, like quick-action.
        // Work-on-issue types `/crow-workspace <url>` (or `--explore` for an
        // exploration session, CROW-1149) into the primary Manager terminal and
        // lets that agent do the worktree/session setup. Forwarded to the app
        // when it's running; with the app down the daemon drives its OWN Manager
        // window directly — it registered that window, so it holds the live tmux
        // binding (no stale-index adoption). (ADR 0007; M-E2)
        "work-on-issue": { params in
            guard sessionService != nil else {
                throw DaemonRPCError.applicationError(
                    "Working on an issue requires tmux on the daemon host")
            }
            guard let url = params["url"]?.stringValue, !url.isEmpty else {
                throw DaemonRPCError.invalidParams("url required")
            }
            guard isSafeIssueURL(url) else {
                throw DaemonRPCError.invalidParams("url must be a well-formed http(s) URL with no control characters")
            }
            let explore = params["explore"]?.boolValue == true
            return try await MainActor.run {
                guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
                    throw DaemonRPCError.applicationError("The Manager is still starting — try again in a moment")
                }
                TerminalRouter.send(
                    managerTerminal,
                    text: workspaceLaunchCommand(urls: [url], explore: explore))
                return ["ok": .bool(true)]
            }
        },
        // Batch counterpart of work-on-issue (#752): types ONE
        // `/crow-batch-workspace <url1> <url2> …` line, so the Manager runs the
        // parallel batch skill once instead of N sequential `/crow-workspace`
        // submissions. Single-line by construction — TerminalRouter turns
        // newlines into Enter presses, so an embedded newline would split the
        // prompt (cf. #161). Unsafe URLs are dropped and reported back in
        // `rejected` rather than failing the whole batch, so one bad ticket
        // can't block the rest.
        "batch-work-on-issues": { params in
            guard sessionService != nil else {
                throw DaemonRPCError.applicationError(
                    "Working on an issue requires tmux on the daemon host")
            }
            guard let arr = params["urls"]?.arrayValue, !arr.isEmpty else {
                throw DaemonRPCError.invalidParams("urls array required")
            }
            var valid: [String] = []
            var rejected: [String] = []
            for value in arr {
                let url = value.stringValue ?? ""
                if isSafeIssueURL(url) {
                    if !valid.contains(url) { valid.append(url) }
                } else {
                    rejected.append(url)
                }
            }
            guard !valid.isEmpty else {
                throw DaemonRPCError.invalidParams("urls must be well-formed http(s) URLs with no control characters")
            }
            let explore = params["explore"]?.boolValue == true
            return try await MainActor.run {
                guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
                    throw DaemonRPCError.applicationError("The Manager is still starting — try again in a moment")
                }
                TerminalRouter.send(
                    managerTerminal,
                    text: workspaceLaunchCommand(urls: valid, explore: explore))
                return [
                    "ok": .bool(true),
                    "sent": .int(valid.count),
                    "rejected": .array(rejected.map { .string($0) }),
                ]
            }
        },
        // Starting a review forwards to the app when it's running; with the app
        // down it runs on the daemon's own SessionService — cloning the PR,
        // scaffolding the review skill, and spawning a tmux window + agent
        // (ADR 0007; CROW-581, M-E2). Kickoffs are serialized so the internal
        // dedupe stays race-free. Without tmux it errors, as before.
        "start-review": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError(
                    "Starting a review requires tmux on the daemon host")
            }
            guard let url = params["url"]?.stringValue, !url.isEmpty else {
                throw DaemonRPCError.invalidParams("url required")
            }
            let task = await reviewSerializer.enqueue {
                await sessionService.createReviewSession(prURL: url, selectAfterCreate: false)
            }
            guard let id = await task.value else {
                throw DaemonRPCError.applicationError("Could not start a review for \(url)")
            }
            return ["session_id": .string(id.uuidString)]
        },
        // Batch counterpart of start-review (CROW-865), backing the Reviews
        // board's "Start Review (N)". Unlike batch-work-on-issues this types
        // nothing at the Manager — it enqueues N kickoffs on the same
        // serializer, so the dedupe stays race-free (the old desktop
        // `onBatchStartReview` fanned out in parallel and did race, #212/#266).
        //
        // The enqueued tasks are deliberately NOT awaited: each one clones a PR
        // and spawns a tmux window, far past the web client's 10s rpc timeout,
        // and they run one at a time. So this acks as soon as the work is
        // queued and the new sessions surface via the sidebar poll — the same
        // "let it show up" contract `spawnAction` already relies on.
        //
        // Unsafe urls are dropped and reported in `rejected` rather than
        // failing the whole batch, so one bad PR can't block the rest.
        "batch-start-review": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError(
                    "Starting a review requires tmux on the daemon host")
            }
            guard let arr = params["urls"]?.arrayValue, !arr.isEmpty else {
                throw DaemonRPCError.invalidParams("urls array required")
            }
            var valid: [String] = []
            var rejected: [String] = []
            for value in arr {
                let url = value.stringValue ?? ""
                if isSafeIssueURL(url) {
                    if !valid.contains(url) { valid.append(url) }
                } else {
                    rejected.append(url)
                }
            }
            guard !valid.isEmpty else {
                throw DaemonRPCError.invalidParams("urls must be well-formed http(s) URLs with no control characters")
            }
            for url in valid {
                _ = await reviewSerializer.enqueue {
                    await sessionService.createReviewSession(prURL: url, selectAfterCreate: false)
                }
            }
            return [
                "ok": .bool(true),
                "started": .int(valid.count),
                "rejected": .array(rejected.map { .string($0) }),
            ]
        },
        "refresh-tickets": { params in
            if let tracker {
                await tracker.refresh()
                return ["ok": .bool(true)]
            }
            throw DaemonRPCError.applicationError("Refreshing tickets requires a provider-configured daemon")
        },
    ]
    return handlers
}
