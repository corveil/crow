import SwiftUI
import CrowCore

/// Left sidebar showing grouped session list with pinned manager tab.
public struct SessionListView: View {
    @Bindable var appState: AppState
    @State private var searchText = ""
    @State private var sessionToDelete: Session?
    @State private var editingManagerID: UUID?
    @State private var isSelectionMode = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var showBulkDeleteConfirm = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            sessionList

            if isSelectionMode {
                bulkActionBar
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                selectToggleButton
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.soundMuted.toggle()
                    appState.onSoundMutedChanged?(appState.soundMuted)
                } label: {
                    Image(systemName: appState.soundMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(appState.soundMuted ? CorveilTheme.textMuted : CorveilTheme.gold)
                }
                .help(appState.soundMuted ? "Unmute notifications" : "Mute notifications")
                .accessibilityLabel(appState.soundMuted ? "Unmute notifications" : "Mute notifications")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.onShowSettings?()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(CorveilTheme.textSecondary)
                }
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
            }
        }
        .deleteSessionAlert(session: $sessionToDelete, appState: appState)
        .bulkDeleteSessionsAlert(
            isPresented: $showBulkDeleteConfirm,
            selectedIDs: selectedSessionIDs,
            appState: appState
        ) {
            selectedSessionIDs.removeAll()
            isSelectionMode = false
        }
    }

    private var sessionList: some View {
        List(selection: $appState.selectedSessionID) {
            // Brandmark header
            SidebarBrandmark()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            // Ticket board row
            TicketBoardSidebarRow(appState: appState)
                .tag(AppState.ticketBoardSessionID)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            // Manager + Reviews + Allowlist row
            ManagerReviewsAllowListRow(appState: appState)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            // Additional (non-primary) Manager sessions, each deletable.
            let extraManagers = appState.managerSessions.filter { $0.id != AppState.managerSessionID }
            ForEach(extraManagers) { session in
                ManagerSessionRow(session: session, appState: appState, editingSessionID: $editingManagerID)
                    .tag(session.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button {
                            editingManagerID = session.id
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            sessionToDelete = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(appState.isDeletingSession[session.id] == true)
                    }
            }

            // Job sessions
            if !appState.jobSessions.isEmpty {
                SectionDivider(
                    title: "Jobs",
                    isSelectionMode: isSelectionMode,
                    sectionIDs: Set(filteredSessions(appState.jobSessions).map(\.id)),
                    selectedSessionIDs: $selectedSessionIDs
                )
                ForEach(filteredSessions(appState.jobSessions)) { session in
                    SessionRow(
                        session: session,
                        appState: appState,
                        isSelectionMode: isSelectionMode,
                        selectedSessionIDs: $selectedSessionIDs
                    )
                    .tag(session.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        sessionContextMenu(session)
                    }
                }
            }

            // Active sessions
            if !appState.activeSessions.isEmpty {
                SectionDivider(
                    title: "Active",
                    isSelectionMode: isSelectionMode,
                    sectionIDs: Set(filteredSessions(appState.activeSessions).map(\.id)),
                    selectedSessionIDs: $selectedSessionIDs
                )
                ForEach(filteredSessions(appState.activeSessions)) { session in
                    SessionRow(
                        session: session,
                        appState: appState,
                        isSelectionMode: isSelectionMode,
                        selectedSessionIDs: $selectedSessionIDs
                    )
                    .tag(session.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        sessionContextMenu(session)
                    }
                }
            }

            // Review sessions
            if !appState.reviewSessions.isEmpty {
                SectionDivider(
                    title: "Reviews",
                    isSelectionMode: isSelectionMode,
                    sectionIDs: Set(filteredSessions(appState.reviewSessions).map(\.id)),
                    selectedSessionIDs: $selectedSessionIDs
                )
                ForEach(filteredSessions(appState.reviewSessions)) { session in
                    SessionRow(
                        session: session,
                        appState: appState,
                        isSelectionMode: isSelectionMode,
                        selectedSessionIDs: $selectedSessionIDs
                    )
                    .tag(session.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button(role: .destructive) {
                            sessionToDelete = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(appState.isDeletingSession[session.id] == true)
                    }
                }
            }

            // In Review sessions
            if !appState.inReviewSessions.isEmpty {
                SectionDivider(
                    title: "In Review",
                    isSelectionMode: isSelectionMode,
                    sectionIDs: Set(filteredSessions(appState.inReviewSessions).map(\.id)),
                    selectedSessionIDs: $selectedSessionIDs
                )
                ForEach(filteredSessions(appState.inReviewSessions)) { session in
                    SessionRow(
                        session: session,
                        appState: appState,
                        isSelectionMode: isSelectionMode,
                        selectedSessionIDs: $selectedSessionIDs
                    )
                    .tag(session.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        sessionContextMenu(session)
                    }
                }
            }

            // Completed sessions
            if !appState.completedSessions.isEmpty {
                SectionDivider(
                    title: "Completed",
                    isSelectionMode: isSelectionMode,
                    sectionIDs: Set(filteredSessions(appState.completedSessions).map(\.id)),
                    selectedSessionIDs: $selectedSessionIDs
                )
                ForEach(filteredSessions(appState.completedSessions)) { session in
                    SessionRow(
                        session: session,
                        appState: appState,
                        isSelectionMode: isSelectionMode,
                        selectedSessionIDs: $selectedSessionIDs
                    )
                    .tag(session.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        sessionContextMenu(session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(CorveilTheme.bgDeep)
        .searchable(text: $searchText, prompt: "Search sessions")
    }

    private var selectToggleButton: some View {
        Button {
            isSelectionMode.toggle()
            if !isSelectionMode {
                selectedSessionIDs.removeAll()
            }
        } label: {
            Image(systemName: isSelectionMode ? "xmark.circle" : "checkmark.circle")
                .foregroundStyle(isSelectionMode ? .red : CorveilTheme.gold)
        }
        .help(isSelectionMode ? "Cancel selection" : "Select sessions")
        .accessibilityLabel(isSelectionMode ? "Cancel selection" : "Select sessions")
    }

    private var bulkActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedSessionIDs.count) selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CorveilTheme.textSecondary)

            Spacer()

            Button {
                isSelectionMode = false
                selectedSessionIDs.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CorveilTheme.textSecondary)
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help("Cancel selection")
            .accessibilityLabel("Cancel selection")

            if !selectedSessionIDs.isEmpty {
                Button {
                    showBulkDeleteConfirm = true
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("(\(selectedSessionIDs.count))")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(selectedSessionIDs.count) selected sessions")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CorveilTheme.bgSurface)
        .overlay(alignment: .top) {
            Divider().overlay(CorveilTheme.borderSubtle)
        }
    }

    @ViewBuilder
    private func sessionContextMenu(_ session: Session) -> some View {
        let deleting = appState.isDeletingSession[session.id] == true

        if session.status == .active,
           session.ticketURL != nil,
           appState.canSetProjectStatus(for: session) {
            Button {
                appState.onMarkInReview?(session.id)
            } label: {
                Label("Mark as In Review", systemImage: "eye.circle")
            }
            .disabled(appState.isMarkingInReview[session.id] == true || deleting)
        }

        if session.status == .active || session.status == .inReview {
            Button {
                appState.onCompleteSession?(session.id)
            } label: {
                Label("Mark as Completed", systemImage: "checkmark.circle")
            }
            .disabled(deleting)
        }

        Button(role: .destructive) {
            sessionToDelete = session
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(deleting)
    }

    private func filteredSessions(_ sessions: [Session]) -> [Session] {
        if searchText.isEmpty { return sessions }
        return sessions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Sidebar Brandmark

/// Sidebar header showing the Corveil brandmark.
struct SidebarBrandmark: View {
    var body: some View {
        VStack(spacing: 0) {
            BrandmarkImage()
                .frame(width: 120)
                .opacity(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - Section Divider

/// Uppercase section label used to group sessions in the sidebar.
struct SectionDivider: View {
    let title: String
    var isSelectionMode: Bool = false
    var sectionIDs: Set<UUID> = []
    @Binding var selectedSessionIDs: Set<UUID>

    init(title: String, isSelectionMode: Bool = false, sectionIDs: Set<UUID> = [], selectedSessionIDs: Binding<Set<UUID>> = .constant([])) {
        self.title = title
        self.isSelectionMode = isSelectionMode
        self.sectionIDs = sectionIDs
        self._selectedSessionIDs = selectedSessionIDs
    }

    private var allSelected: Bool {
        !sectionIDs.isEmpty && sectionIDs.isSubset(of: selectedSessionIDs)
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(CorveilTheme.goldDark)

            Spacer()

            if isSelectionMode && !sectionIDs.isEmpty {
                Button {
                    if allSelected {
                        selectedSessionIDs.subtract(sectionIDs)
                    } else {
                        selectedSessionIDs.formUnion(sectionIDs)
                    }
                } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "checklist")
                        .font(.system(size: 12))
                        .foregroundStyle(allSelected ? CorveilTheme.gold : CorveilTheme.goldDark)
                }
                .buttonStyle(.plain)
                .help(allSelected ? "Deselect all \(title.lowercased())" : "Select all \(title.lowercased())")
                .accessibilityLabel(allSelected ? "Deselect all \(title.lowercased())" : "Select all \(title.lowercased())")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Manager Session Row

/// Sidebar row for an additional (non-primary) Manager session. Renders a
/// full-width selectable button with the manager's name, a remote-control
/// badge, and a deletion spinner when cleanup is in flight.
struct ManagerSessionRow: View {
    let session: Session
    @Bindable var appState: AppState
    @Binding var editingSessionID: UUID?

    @State private var editingName: String = ""
    @FocusState private var isEditing: Bool

    private var isActive: Bool { appState.selectedSessionID == session.id }
    private var isDeleting: Bool { appState.isDeletingSession[session.id] == true }
    private var isEditingThis: Bool { editingSessionID == session.id }
    private var needsAttention: Bool {
        appState.hookState(for: session.id).pendingNotification != nil
    }

    private var backgroundFill: Color {
        if needsAttention {
            return Color.orange.opacity(0.12)
        }
        return isActive ? CorveilTheme.bgCard : CorveilTheme.bgSurface
    }

    private var borderStroke: Color {
        if needsAttention {
            return Color.orange.opacity(0.4)
        }
        return isActive ? CorveilTheme.goldDark.opacity(0.6) : CorveilTheme.goldDark.opacity(0.3)
    }

    var body: some View {
        Button {
            appState.selectedSessionID = session.id
        } label: {
            HStack(spacing: 6) {
                if needsAttention {
                    AttentionDot(color: Color.orange, accessibilityLabel: "Needs attention")
                }
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11))
                if isEditingThis {
                    TextField("Name", text: $editingName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                        .focused($isEditing)
                        .onSubmit { commitRename() }
                        .onExitCommand { editingSessionID = nil }
                        .onChange(of: isEditing) { _, nowEditing in
                            if !nowEditing, isEditingThis { commitRename() }
                        }
                } else {
                    Text(session.name)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                }
                Spacer()
                if isDeleting {
                    ProgressView().controlSize(.small)
                }
            }
            .foregroundStyle(isActive ? CorveilTheme.gold : CorveilTheme.goldDark)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(borderStroke, lineWidth: 1)
                    )
            )
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: needsAttention)
            .overlay(alignment: .topTrailing) {
                if appState.isRemoteControlActive(sessionID: session.id) {
                    RemoteControlBadge(compact: true)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                editingSessionID = session.id
            }
        )
        .onChange(of: editingSessionID) { _, newValue in
            if newValue == session.id {
                editingName = session.name
                isEditing = true
            }
        }
    }

    private func commitRename() {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            appState.onRenameSession?(session.id, trimmed)
        }
        editingSessionID = nil
    }
}

// MARK: - Session Row

/// Sidebar row for a work session, showing name, ticket info, PR status, and Claude state.
struct SessionRow: View {
    let session: Session
    let appState: AppState
    var isSelectionMode: Bool = false
    var selectedSessionIDs: Binding<Set<UUID>>? = nil

    private var primaryWorktree: SessionWorktree? {
        appState.primaryWorktree(for: session.id)
    }

    private var isChecked: Bool {
        selectedSessionIDs?.wrappedValue.contains(session.id) ?? false
    }

    private func toggleSelection() {
        guard let binding = selectedSessionIDs else { return }
        if binding.wrappedValue.contains(session.id) {
            binding.wrappedValue.remove(session.id)
        } else {
            binding.wrappedValue.insert(session.id)
        }
    }

    private var prLink: SessionLink? {
        appState.links(for: session.id).first(where: { $0.linkType == .pr })
    }

    private var prStatus: PRStatus? {
        appState.prStatus[session.id]
    }

    private var activityState: AgentActivityState {
        appState.hookState(for: session.id).activityState
    }

    private var sessionLabels: [LabelInfo] {
        appState.labels(forSession: session)
    }

    /// Readiness of the primary terminal for this session.
    private var terminalReadiness: TerminalReadiness? {
        let terminals = appState.terminals(for: session.id)
        guard let primary = terminals.first else { return nil }
        return appState.terminalReadiness[primary.id]
    }


    private var isDeleting: Bool {
        appState.isDeletingSession[session.id] == true
    }

    private var deletionError: String? {
        appState.sessionDeletionError[session.id]
    }

    private var agent: (any CodingAgent)? {
        AgentRegistry.shared.agent(for: session.agentKind)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isSelectionMode {
                Button(action: toggleSelection) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isChecked ? CorveilTheme.gold : CorveilTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isChecked ? "Deselect \(session.name)" : "Select \(session.name)")
                .disabled(isDeleting)
            }

            rowContent
                .opacity(isDeleting ? 0.55 : 1.0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(rowBorderColor, lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: needsAttention)
        .animation(.easeInOut(duration: 0.2), value: appState.hideSessionDetails)
        .animation(.easeInOut(duration: 0.2), value: isDeleting)
        .padding(.vertical, 1)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: Name + status indicator
            HStack(spacing: 4) {
                if let agent {
                    Image(systemName: agent.iconSystemName)
                        .font(.caption2)
                        .foregroundStyle(CorveilTheme.textSecondary)
                        .help(agent.displayName)
                }
                Text(session.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CorveilTheme.textPrimary)
                    .lineLimit(1)
                if agent?.supportsRemoteControl == true,
                   appState.isRemoteControlActive(sessionID: session.id) {
                    RemoteControlBadge(compact: true)
                }
                Spacer()
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Deleting session")
                } else if let deletionError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .help("Delete failed: \(deletionError)")
                        .accessibilityLabel("Delete failed: \(deletionError)")
                } else {
                    statusIndicator
                }
            }

            // Row 2: Ticket title (if any)
            if !appState.hideSessionDetails, let title = session.ticketTitle {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
                    .lineLimit(1)
            }

            // Row 3: Repo + branch
            if !appState.hideSessionDetails, let wt = primaryWorktree {
                Text("\(wt.repoName) / \(shortenBranch(wt.branch))")
                    .font(.caption2)
                    .foregroundStyle(CorveilTheme.textMuted)
                    .lineLimit(1)
            }

            // Row 3.5: Labels
            if !appState.hideSessionDetails, !sessionLabels.isEmpty {
                LabelPillsView(labels: sessionLabels, maxVisible: 2)
            }

            // Row 4: Issue badge + PR badge + Claude state
            let hasIssueBadge = session.ticketNumber != nil
            let hasBadges = hasIssueBadge || prLink != nil || activityState != .idle
            if hasBadges {
                HStack(spacing: 6) {
                    if let num = session.ticketNumber {
                        CapsuleBadge("Issue #\(String(num))", color: CorveilTheme.gold)
                    }
                    if let pr = prLink {
                        PRBadge(label: pr.label, status: prStatus)
                    }
                    if activityState != .idle || appState.hookState(for: session.id).pendingNotification != nil {
                        activityStateBadge
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .active:
            // Reflect terminal readiness state
            switch terminalReadiness {
            case .failed:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Terminal failed to launch")
            case .uninitialized, nil:
                Circle()
                    .fill(CorveilTheme.textMuted)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Waiting for terminal")
            case .surfaceCreated:
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Terminal starting")
            case .timedOut:
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(.yellow.opacity(0.4), lineWidth: 2)
                            .scaleEffect(1.6)
                    )
                    .accessibilityLabel("Terminal didn't become ready — click to retry")
            case .shellReady:
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Shell ready")
            case .agentLaunched:
                if needsAttention {
                    AttentionDot(color: Color.orange, accessibilityLabel: "Needs attention")
                } else if activityState == .working {
                    AttentionDot(color: Color.green, accessibilityLabel: "Claude working")
                } else {
                    // done or idle — solid green
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Active")
                }
            }
        case .inReview:
            Image(systemName: "eye.circle.fill")
                .foregroundStyle(CorveilTheme.gold)
                .font(.caption)
                .accessibilityLabel("In review")
        case .paused:
            Circle()
                .fill(.yellow)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Paused")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(CorveilTheme.gold)
                .font(.caption)
                .accessibilityLabel("Completed")
        case .archived:
            Image(systemName: "archivebox.fill")
                .foregroundStyle(CorveilTheme.textMuted)
                .font(.caption)
                .accessibilityLabel("Archived")
        }
    }

    @ViewBuilder
    private var activityStateBadge: some View {
        let activity = appState.hookState(for: session.id).lastToolActivity
        let notification = appState.hookState(for: session.id).pendingNotification

        if let notification {
            // Attention badges
            if notification.notificationType == "permission_prompt" {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text("Permission")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
            } else if notification.notificationType == "question" {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.caption2)
                    Text("Question")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
            }
        } else {
            switch activityState {
            case .working:
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                    if let activity, activity.isActive {
                        Text(activity.toolName)
                            .font(.caption2)
                    } else {
                        Text("Working")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.orange)
            case .done:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                    Text("Done")
                        .font(.caption2)
                }
                .foregroundStyle(CorveilTheme.gold)
            case .waiting, .idle:
                EmptyView()
            }
        }
    }

    private var needsAttention: Bool {
        appState.hookState(for: session.id).pendingNotification != nil
    }

    private var rowBackgroundColor: Color {
        if needsAttention {
            return Color.orange.opacity(0.12)
        } else if activityState == .done && terminalReadiness == .agentLaunched {
            return CorveilTheme.bgDone
        }
        return CorveilTheme.bgCard
    }

    private var rowBorderColor: Color {
        if needsAttention {
            return Color.orange.opacity(0.4)
        }
        return CorveilTheme.borderSubtle
    }

}
