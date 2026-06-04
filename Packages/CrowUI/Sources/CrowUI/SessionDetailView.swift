import SwiftUI
import CrowCore
import CrowTerminal

/// Detail view for a selected session.
public struct SessionDetailView: View {
    let session: Session
    @Bindable var appState: AppState
    @State private var sessionToDelete: Session?

    public init(session: Session, appState: AppState) {
        self.session = session
        self.appState = appState
    }

    private var primaryWorktree: SessionWorktree? {
        appState.primaryWorktree(for: session.id)
    }

    private var sessionLinks: [SessionLink] {
        appState.links(for: session.id)
    }

    private var sessionLabels: [LabelInfo] {
        appState.labels(forSession: session)
    }

    public var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            if session.isManager {
                SectionHelpBanner(
                    description: "Orchestration hub for Crow workspaces. Use /crow-workspace to set up new sessions with worktrees, ticket tracking, and auto-launched Claude Code.",
                    storageKey: "helpDismissed_manager"
                )
            }
            Divider().overlay(CorveilTheme.borderSubtle)
            terminalArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .deleteSessionAlert(session: $sessionToDelete, appState: appState)
    }

    // MARK: - Three-Row Header

    private var sessionHeader: some View {
        VStack(spacing: 0) {
            // Row 1: Name + Status
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(CorveilTheme.gold)
                        if AgentRegistry.shared.agent(for: session.agentKind)?.supportsRemoteControl == true,
                           appState.isRemoteControlActive(sessionID: session.id) {
                            RemoteControlBadge()
                        }
                    }

                    if let title = session.ticketTitle {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(CorveilTheme.textSecondary)
                            .lineLimit(2)
                    }

                    if !sessionLabels.isEmpty {
                        LabelPillsView(labels: sessionLabels, maxVisible: 5)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                StatusBadge(status: session.status)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Row 2: Repo / Branch / Path (if worktree exists)
            if let wt = primaryWorktree {
                Divider().overlay(CorveilTheme.borderSubtle).padding(.horizontal, 16)

                HStack(spacing: 16) {
                    DetailLabel(icon: "folder", text: wt.repoName)
                    DetailLabel(icon: "arrow.triangle.branch", text: shortenBranch(wt.branch))
                    Spacer()
                    Text(shortenPath(wt.worktreePath))
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Row 2.5: Agent — read-only label for non-Manager sessions so
            // users can see which agent was chosen at creation time. The
            // Manager tab is pinned to Claude Code and hides this row per spec.
            if session.id != AppState.managerSessionID,
               let agent = AgentRegistry.shared.agent(for: session.agentKind) {
                Divider().overlay(CorveilTheme.borderSubtle).padding(.horizontal, 16)

                HStack(spacing: 16) {
                    DetailLabel(icon: agent.iconSystemName, text: "Agent: \(agent.displayName)")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Row 3: Links + Actions (only if there's content to show)
            if session.ticketURL != nil || !sessionLinks.isEmpty || !session.isManager {
                Divider().overlay(CorveilTheme.borderSubtle).padding(.horizontal, 16)

                HStack(spacing: 8) {
                // Issue link
                if let url = session.ticketURL {
                    LinkChip(
                        label: session.ticketNumber.map { "Issue #\(String($0))" } ?? "Issue",
                        url: url,
                        icon: "link"
                    )
                }

                // PR link with status (from session links)
                ForEach(sessionLinks.filter { $0.linkType == .pr }) { link in
                    LinkChip(label: link.label, url: link.url, icon: "arrow.triangle.pull")
                }

                // PR status indicators (pipeline, review, merge)
                if let status = appState.prStatus[session.id] {
                    PRStatusDetail(status: status)
                }

                // Repo link
                ForEach(sessionLinks.filter { $0.linkType == .repo }) { link in
                    LinkChip(label: link.label, url: link.url, icon: "folder")
                }

                Spacer()

                // Action buttons (not for Manager)
                if !session.isManager {
                    quickActionButtons

                    if appState.vsCodeAvailable, primaryWorktree != nil {
                        Button {
                            appState.onOpenInVSCode?(session.id)
                        } label: {
                            Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(CorveilTheme.gold)
                    }

                    if primaryWorktree != nil {
                        Button {
                            appState.onOpenTerminal?(session.id)
                        } label: {
                            Label("Open Terminal", systemImage: "terminal")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(CorveilTheme.gold)
                    }

                    if session.status == .active,
                       session.ticketURL != nil,
                       appState.canSetProjectStatus(for: session) {
                        if appState.isMarkingInReview[session.id] == true {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 8)
                        } else {
                            Button {
                                appState.onMarkInReview?(session.id)
                            } label: {
                                Label("In Review", systemImage: "eye.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(CorveilTheme.gold)
                        }
                    }

                    if session.status == .active || session.status == .inReview {
                        Button {
                            appState.onCompleteSession?(session.id)
                        } label: {
                            Label("Mark as Completed", systemImage: "checkmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(CorveilTheme.gold)
                    }

                    if session.status == .completed {
                        Button {
                            appState.onSetSessionActive?(session.id)
                        } label: {
                            Label("Move to Active", systemImage: "arrow.uturn.backward.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(CorveilTheme.gold)
                    }

                    Button(role: .destructive) {
                        sessionToDelete = session
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isDeletingSession[session.id] == true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            }

            // Row 4: Session Analytics (if telemetry data exists)
            if let analytics = appState.hookState(for: session.id).analytics {
                Divider().overlay(CorveilTheme.borderSubtle).padding(.horizontal, 16)
                SessionAnalyticsStrip(analytics: analytics)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .background(CorveilTheme.bgSurface)
    }

    @ViewBuilder
    private var managerBrandmark: some View {
        BrandmarkImage()
    }

    // MARK: - Quick Action Buttons

    /// PR-status-aware buttons that inject the appropriate next-step prompt
    /// into the session's managed Claude Code terminal. Each button maps
    /// 1:1 to a status badge so the affordance is obvious. Hidden when the
    /// PR is merged or no status is known; disabled when the session has
    /// no managed terminal.
    @ViewBuilder
    private var quickActionButtons: some View {
        if let status = appState.prStatus[session.id], !status.isMerged {
            let canDispatch = appState.canDispatchQuickAction(sessionID: session.id)
            let disabledHelp = "No managed Claude Code terminal in this session"

            if status.mergeable == .conflicting {
                Button {
                    appState.onQuickAction?(session.id, .fixConflicts)
                } label: {
                    Label("Rebase & Fix Conflicts", systemImage: "arrow.triangle.merge")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(!canDispatch)
                .help(canDispatch ? "Send a rebase + resolve-conflicts prompt to the session terminal" : disabledHelp)
            }

            if status.reviewStatus == .changesRequested {
                Button {
                    appState.onQuickAction?(session.id, .addressChanges)
                } label: {
                    Label("Address Review", systemImage: "pencil.and.list.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(!canDispatch)
                .help(canDispatch ? "Send a 'read review feedback and fix' prompt to the session terminal" : disabledHelp)
            }

            if status.checksPass == .failing {
                Button {
                    appState.onQuickAction?(session.id, .fixChecks)
                } label: {
                    Label("Fix Checks", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(!canDispatch)
                .help(canDispatch ? "Send a 'fix failing CI checks' prompt to the session terminal" : disabledHelp)
            }

            if status.isReadyToMerge {
                Button {
                    appState.onQuickAction?(session.id, .mergePR)
                } label: {
                    Label("Merge PR", systemImage: "arrow.triangle.pull")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
                .disabled(!canDispatch)
                .help(canDispatch ? "Send a 'merge this PR' prompt to the session terminal" : disabledHelp)
            }
        }
    }

    // MARK: - Terminal Area

    @ViewBuilder
    private var terminalArea: some View {
        let sessionTerminals = appState.terminals(for: session.id)
        let isManager = session.isManager
        if sessionTerminals.isEmpty {
            TerminalSurfaceView(
                terminalID: session.id,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            .id(session.id)
        } else if isManager, let terminal = sessionTerminals.first {
            // Manager session: single terminal, no tab bar
            ZStack {
                TerminalSurfaceView(
                    terminalID: terminal.id,
                    workingDirectory: terminal.cwd,
                    command: terminal.command
                )
                .id(terminal.id)

                if appState.managerProcessExited {
                    // The Manager's claude process exited (crash, kill, OOM).
                    // Offer an in-place restart that keeps the session identity.
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("Manager process exited")
                            .font(.headline)
                        Text("The Manager's Claude Code process is no longer running. Restart it to continue orchestrating workspaces.")
                            .font(.caption)
                            .foregroundStyle(CorveilTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Restart Manager") {
                            appState.onRestartManager?()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CorveilTheme.bgDeep.opacity(0.95))
                }
            }
        } else {
            VStack(spacing: 0) {
                // Icon is resolved live from `session.agentKind` on every
                // render, while the tab label is snapshotted into
                // `terminal.name` at creation (so a user-typed rename
                // sticks). The asymmetry is intentional — don't "fix" it by
                // moving either side without considering rename UX and
                // legacy persisted names (CROW-427).
                TerminalTabBar(
                    terminals: sessionTerminals,
                    managedAgentIcon: session.agentKind.iconSystemName,
                    activeID: appState.activeTerminalID[session.id] ?? sessionTerminals[0].id,
                    onSelect: { id in appState.activeTerminalID[session.id] = id },
                    onClose: { id in appState.onCloseTerminal?(session.id, id) },
                    onRename: { id, name in appState.onRenameTerminal?(session.id, id, name) },
                    onAdd: { appState.onAddTerminal?(session.id) }
                )
                Divider().overlay(CorveilTheme.borderSubtle)
                let activeID = appState.activeTerminalID[session.id] ?? sessionTerminals[0].id
                if let terminal = sessionTerminals.first(where: { $0.id == activeID }) {
                    if terminal.isManaged {
                        ReadinessAwareTerminal(terminal: terminal, appState: appState)
                    } else {
                        TerminalSurfaceView(
                            terminalID: terminal.id,
                            workingDirectory: terminal.cwd,
                            command: terminal.command
                        )
                        .id(terminal.id)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Supporting Views

/// Icon + text label used in the session detail header for repo/branch metadata.
struct DetailLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(CorveilTheme.textMuted)
            Text(text)
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

public struct TerminalTabBar: View {
    let terminals: [SessionTerminal]
    /// SF Symbol shown on managed tabs (e.g. `"sparkles"` for Claude Code,
    /// `"cursorarrow.rays"` for Cursor). Set by the parent from
    /// `session.agentKind.iconSystemName` so the glyph tracks the agent
    /// actually launched (CROW-427).
    let managedAgentIcon: String
    let activeID: UUID
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onAdd: () -> Void

    public init(
        terminals: [SessionTerminal],
        managedAgentIcon: String = "sparkles",
        activeID: UUID,
        onSelect: @escaping (UUID) -> Void,
        onClose: @escaping (UUID) -> Void,
        onRename: @escaping (UUID, String) -> Void,
        onAdd: @escaping () -> Void
    ) {
        self.terminals = terminals
        self.managedAgentIcon = managedAgentIcon
        self.activeID = activeID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        self.onAdd = onAdd
    }

    @State private var editingTerminalID: UUID?
    @State private var editingName: String = ""
    @FocusState private var isEditing: Bool

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(terminals) { terminal in
                Button { onSelect(terminal.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: terminal.isManaged ? managedAgentIcon : "terminal")
                            .font(.system(size: 9))
                        if editingTerminalID == terminal.id {
                            TextField("Name", text: $editingName)
                                .textFieldStyle(.plain)
                                .font(.caption)
                                .frame(minWidth: 40, maxWidth: 120)
                                .focused($isEditing)
                                .onSubmit {
                                    commitRename(terminal.id)
                                }
                                .onExitCommand {
                                    editingTerminalID = nil
                                }
                                .onChange(of: isEditing) { _, nowEditing in
                                    if !nowEditing, editingTerminalID == terminal.id {
                                        commitRename(terminal.id)
                                    }
                                }
                        } else {
                            Text(terminal.name)
                                .font(.caption)
                                .onTapGesture(count: 2) {
                                    beginEditing(terminal)
                                }
                        }
                        if !terminal.isManaged {
                            Button {
                                onClose(terminal.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(CorveilTheme.textMuted)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 2)
                            .accessibilityLabel("Close terminal")
                        }
                    }
                    .foregroundStyle(terminal.id == activeID ? CorveilTheme.gold : CorveilTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(terminal.id == activeID ? CorveilTheme.gold.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        beginEditing(terminal)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if !terminal.isManaged {
                        Button(role: .destructive) {
                            onClose(terminal.id)
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }

            Button { onAdd() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CorveilTheme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add terminal")

            Spacer()
        }
        .background(CorveilTheme.bgSurface)
    }

    private func beginEditing(_ terminal: SessionTerminal) {
        editingTerminalID = terminal.id
        editingName = terminal.name
        isEditing = true
    }

    private func commitRename(_ terminalID: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            onRename(terminalID, trimmed)
        }
        editingTerminalID = nil
    }
}

/// Badge displaying a session's current status with appropriate color.
struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(status.displayName)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
            .accessibilityLabel("Status: \(status.displayName)")
    }

    private var statusColor: Color {
        switch status {
        case .active: .green
        case .paused: .yellow
        case .inReview: CorveilTheme.gold
        case .completed: CorveilTheme.gold
        case .archived: CorveilTheme.textMuted
        }
    }
}

// MARK: - Readiness-Aware Terminal Wrapper

/// Wraps a TerminalSurfaceView with readiness tracking.
/// Auto-launches the coding agent when the shell becomes ready on first focus.
struct ReadinessAwareTerminal: View {
    let terminal: SessionTerminal
    @Bindable var appState: AppState

    @State private var diagnosticsCopied = false

    private var readiness: TerminalReadiness {
        appState.terminalReadiness[terminal.id] ?? .agentLaunched  // Default for non-tracked terminals
    }

    var body: some View {
        ZStack {
            TerminalSurfaceView(
                terminalID: terminal.id,
                workingDirectory: terminal.cwd,
                command: terminal.command
            )
            .id(terminal.id)

            if readiness == .timedOut {
                // Readiness watch expired before the shell signaled it was
                // interactive. Common on cold tmux start + App Nap on a
                // backgrounded app + heavy zshrc. The user can retry now, or
                // the app will retry automatically next time it returns to
                // the foreground.
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.yellow)
                    Text("Terminal didn't become ready in time")
                        .font(.headline)
                    Text("The shell took longer than expected to start. This usually means the app was backgrounded while a tmux session was warming up.")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Retry") {
                            appState.onRetryReadiness?(terminal.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        // Bundles wrapper-stage log + pane capture + ps tree +
                        // sentinel state onto the clipboard so reporters can
                        // paste a one-shot diagnostic into a comment instead
                        // of describing the symptom (issue #256).
                        Button(diagnosticsCopied ? "Copied!" : "Copy diagnostics") {
                            appState.onCopyDiagnostics?(terminal.id)
                            diagnosticsCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                diagnosticsCopied = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CorveilTheme.bgDeep.opacity(0.95))
            } else if readiness < .shellReady {
                // Loading overlay while terminal is not yet ready
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(readiness == .uninitialized ? "Waiting for terminal..." : "Shell starting...")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CorveilTheme.bgDeep.opacity(0.85))
            }
        }
        .onChange(of: readiness) { oldValue, newValue in
            if newValue == .shellReady {
                // Shell just became ready — auto-launch the agent
                appState.onLaunchAgent?(terminal.id)
            }
        }
    }
}
