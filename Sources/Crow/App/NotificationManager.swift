import AppKit
import UserNotifications
import CrowCore
import CrowIPC

/// Manages sound playback and macOS notification center alerts for hook events.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let appState: AppState
    private var settings: NotificationSettings
    private var soundCache: [String: NSSound] = [:]
    private var lastNotified: [UUID: (event: NotificationEvent, time: Date)] = [:]
    private var hasRequestedPermission = false

    /// Available built-in macOS system sounds.
    static let builtInSounds = NotificationSettings.builtInSounds

    init(appState: AppState, settings: NotificationSettings) {
        self.appState = appState
        self.settings = settings
        super.init()

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            requestNotificationPermission()
        }
    }

    func updateSettings(_ settings: NotificationSettings) {
        self.settings = settings
    }

    /// Remove deduplication state for a session (call on session deletion).
    func clearSession(_ id: UUID) {
        lastNotified.removeValue(forKey: id)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Allow notifications to display even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Event Handling

    /// Called from the hook-event handler after state machine updates.
    func handleEvent(
        sessionID: UUID,
        eventName: String,
        payload: [String: JSONValue],
        summary: String
    ) {
        let toolName = payload["tool_name"]?.stringValue
        let notificationType = payload["notification_type"]?.stringValue

        guard let event = NotificationEvent.from(
            eventName: eventName,
            toolName: toolName,
            notificationType: notificationType
        ) else { return }

        guard !settings.globalMute else { return }

        let config = settings.config(for: event)
        guard config.enabled else { return }

        // Deduplicate: skip if same (session, event) fired within 2 seconds
        if let last = lastNotified[sessionID],
           last.event == event,
           Date().timeIntervalSince(last.time) < 2.0 {
            return
        }
        lastNotified[sessionID] = (event, Date())

        // Play sound
        if settings.soundEnabled && config.soundEnabled {
            playSound(named: config.soundName)
        }

        // Post system notification (only when user isn't looking at this session)
        if settings.systemNotificationsEnabled && config.systemNotificationEnabled {
            let appFocused = NSApp.isActive
            let sessionVisible = appState.selectedSessionID == sessionID
            if !appFocused || !sessionVisible {
                let sessionName = appState.sessions.first(where: { $0.id == sessionID })?.name ?? "Session"
                postSystemNotification(
                    title: "\(event.displayName) — \(sessionName)",
                    body: summary,
                    sessionID: sessionID,
                    eventName: eventName
                )
            }
        }
    }

    // MARK: - Review Request Notifications

    /// Notify the user about a new PR review request.
    func notifyReviewRequest(_ request: ReviewRequest) {
        guard !settings.globalMute else { return }

        let config = settings.config(for: .reviewRequested)
        guard config.enabled else { return }

        // Play sound
        if settings.soundEnabled && config.soundEnabled {
            playSound(named: config.soundName)
        }

        // Post system notification
        if settings.systemNotificationsEnabled && config.systemNotificationEnabled {
            postSystemNotification(
                title: "Review Requested \u{2014} \(request.repo)",
                body: "PR #\(request.prNumber): \(request.title) (by @\(request.author))",
                sessionID: UUID(),
                eventName: "ReviewRequested"
            )
        }
    }

    // MARK: - Auto-Workspace Notifications

    /// Notify the user that a workspace is being auto-created for a newly
    /// assigned issue. Fires once per dispatch; the actual workspace setup
    /// runs in the Manager terminal via the `/crow-workspace` skill.
    func notifyAutoWorkspaceCreated(_ issue: AssignedIssue) {
        guard !settings.globalMute else { return }
        guard settings.systemNotificationsEnabled else { return }

        postSystemNotification(
            title: "Auto-creating workspace \u{2014} \(issue.repo)",
            body: "#\(issue.number): \(issue.title)",
            sessionID: UUID(),
            eventName: "AutoWorkspaceCreated"
        )
    }

    // MARK: - Auto-Merge Notifications

    /// Notify the user that Crow has enabled GitHub native auto-merge on a
    /// Crow-authored PR carrying the `crow:merge` label (CROW-299). One-shot
    /// per PR — the audit-log line in `IssueTracker` is the durable record;
    /// this is the human-facing banner.
    func notifyAutoMergeEnabled(prURL: String, number: Int, sessionID: UUID) {
        guard !settings.globalMute else { return }
        guard settings.systemNotificationsEnabled else { return }

        let sessionName = appState.sessions.first(where: { $0.id == sessionID })?.name ?? "session"
        postSystemNotification(
            title: "Auto-merge enabled \u{2014} \(sessionName)",
            body: "PR #\(number) will merge once required reviews and checks pass.",
            sessionID: sessionID,
            eventName: "AutoMergeEnabled"
        )
    }

    // MARK: - Auto-Rebase Notifications (CROW-318)

    /// Notify the user that Crow rebased a PR branch onto its base and
    /// force-pushed it (the branch had fallen behind base or developed
    /// conflicts Crow could resolve mechanically).
    func notifyAutoRebasePushed(number: Int, sessionID: UUID) {
        guard !settings.globalMute else { return }
        guard settings.systemNotificationsEnabled else { return }

        let sessionName = appState.sessions.first(where: { $0.id == sessionID })?.name ?? "session"
        postSystemNotification(
            title: "Branch rebased \u{2014} \(sessionName)",
            body: "PR #\(number) was rebased onto its base and force-pushed.",
            sessionID: sessionID,
            eventName: "AutoRebasePushed"
        )
    }

    /// Notify the user that an auto-rebase hit conflicts that couldn't be
    /// resolved mechanically. Crow asks the session's Claude terminal to
    /// resolve them; this banner ensures the user knows even if no live
    /// terminal picked it up.
    func notifyAutoRebaseConflicts(number: Int, sessionID: UUID) {
        guard !settings.globalMute else { return }
        guard settings.systemNotificationsEnabled else { return }

        let sessionName = appState.sessions.first(where: { $0.id == sessionID })?.name ?? "session"
        postSystemNotification(
            title: "Rebase conflicts \u{2014} \(sessionName)",
            body: "PR #\(number) has conflicts. Crow asked Claude to resolve them.",
            sessionID: sessionID,
            eventName: "AutoRebaseConflicts"
        )
    }

    // MARK: - PR Status Transition Notifications

    /// Notify the user about a detected PR status transition (changes
    /// requested or CI failing). Honors the same gating as `handleEvent`:
    /// `globalMute` → category toggles → per-event toggles. Always posts a
    /// system notification when allowed (no foreground/visible suppression
    /// — the user typically wants to know about these even when looking at
    /// the session).
    func notifyPRTransition(_ transition: PRStatusTransition, session: Session) {
        guard !settings.globalMute else { return }

        let event: NotificationEvent
        let title: String
        let body: String
        let prRef = transition.prNumber.map { "PR #\($0)" } ?? "PR"
        let suffix = session.ticketTitle.map { ": \($0)" } ?? ""

        switch transition.kind {
        case .changesRequested:
            event = .changesRequested
            title = "Changes Requested \u{2014} \(session.name)"
            body = "\(prRef)\(suffix) received a 'changes requested' review."
        case .checksFailing:
            event = .checksFailing
            title = "CI Failing \u{2014} \(session.name)"
            if transition.failedCheckNames.isEmpty {
                body = "\(prRef)\(suffix) has failing CI checks."
            } else {
                let names = transition.failedCheckNames.prefix(3).joined(separator: ", ")
                let extra = transition.failedCheckNames.count > 3 ? " (+\(transition.failedCheckNames.count - 3) more)" : ""
                body = "\(prRef)\(suffix) failing: \(names)\(extra)"
            }
        }

        let config = settings.config(for: event)
        guard config.enabled else { return }

        if settings.soundEnabled && config.soundEnabled {
            playSound(named: config.soundName)
        }

        if settings.systemNotificationsEnabled && config.systemNotificationEnabled {
            postSystemNotification(
                title: title,
                body: body,
                sessionID: transition.sessionID,
                eventName: "PRTransition.\(transition.kind.rawValue)"
            )
        }
    }

    // MARK: - Sound Playback

    private func playSound(named name: String) {
        if let cached = soundCache[name] {
            cached.stop()
            cached.play()
            return
        }

        // Try built-in macOS sound
        if let sound = NSSound(named: name) {
            soundCache[name] = sound
            sound.play()
            return
        }

        // Try as a file path (custom sound)
        let url = URL(fileURLWithPath: name)
        if FileManager.default.fileExists(atPath: name),
           let sound = NSSound(contentsOf: url, byReference: true) {
            soundCache[name] = sound
            sound.play()
        }
    }

    // MARK: - System Notifications

    private func requestNotificationPermission() {
        guard !hasRequestedPermission else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        hasRequestedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                NSLog("[NotificationManager] Permission error: \(error)")
            }
        }
    }

    private func postSystemNotification(
        title: String,
        body: String,
        sessionID: UUID,
        eventName: String
    ) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let identifier = "\(sessionID.uuidString)-\(eventName)-\(Int(Date().timeIntervalSince1970))"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[NotificationManager] Failed to post notification: \(error)")
            }
        }
    }
}
