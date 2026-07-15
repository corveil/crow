import SwiftUI
import CrowCore

// MARK: - Main Ticket Board View

/// Full-pane ticket board shown when the Ticket Board tab is selected.
public struct TicketBoardView: View {
    @Bindable var appState: AppState
    @State private var isSelectionMode = false
    @State private var selectedIssueIDs: Set<String> = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            ticketBoardHeader
            Divider().overlay(CorveilTheme.borderSubtle)
            PipelineView(appState: appState)
            Divider().overlay(CorveilTheme.borderSubtle)
            TicketListView(
                appState: appState,
                isSelectionMode: isSelectionMode,
                selectedIssueIDs: $selectedIssueIDs
            )

            if isSelectionMode && !selectedIssueIDs.isEmpty {
                batchActionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CorveilTheme.bgDeep)
    }

    private var ticketBoardHeader: some View {
        VStack(spacing: 10) {
            // Row 1: Title + count + sort
            HStack {
                Text("Ticket Board")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(CorveilTheme.gold)

                if appState.isLoadingIssues {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text("\(appState.filteredAssignedIssues.count) issues")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)

                refreshButton

                selectToggleButton

                SortMenu(sortOrder: $appState.ticketSortOrder)
            }

            // Row 2: Search field
            SearchField("Search tickets...", text: $appState.ticketSearchText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CorveilTheme.bgSurface)
    }

    private var refreshButton: some View {
        Button {
            appState.onManualRefresh?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CorveilTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CorveilTheme.bgCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(CorveilTheme.borderSubtle, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(appState.isLoadingIssues)
        .help("Refresh")
        .accessibilityLabel("Refresh tickets")
    }

    private var selectToggleButton: some View {
        Button {
            isSelectionMode.toggle()
            if !isSelectionMode {
                selectedIssueIDs.removeAll()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelectionMode ? "xmark" : "checkmark.circle")
                    .font(.system(size: 10))
                Text(isSelectionMode ? "Cancel" : "Select")
                    .font(.caption)
            }
            .foregroundStyle(isSelectionMode ? .red : CorveilTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelectionMode ? Color.red.opacity(0.1) : CorveilTheme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelectionMode ? Color.red.opacity(0.3) : CorveilTheme.borderSubtle, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedIssueIDs.count) ticket\(selectedIssueIDs.count == 1 ? "" : "s") selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CorveilTheme.textSecondary)

            Spacer()

            Button {
                isSelectionMode = false
                selectedIssueIDs.removeAll()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13))
                    .foregroundStyle(CorveilTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button {
                let urls = appState.filteredAssignedIssues
                    .filter { selectedIssueIDs.contains($0.id) }
                    .map(\.url)
                appState.onBatchWorkOnIssues?(urls)
                selectedIssueIDs.removeAll()
                isSelectionMode = false
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Start Working (\(selectedIssueIDs.count))")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(CorveilTheme.gold)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
        .overlay(alignment: .top) {
            Divider().overlay(CorveilTheme.borderSubtle)
        }
    }
}

// MARK: - Sort Menu

struct SortMenu: View {
    @Binding var sortOrder: TicketSortOrder

    var body: some View {
        Menu {
            ForEach(TicketSortOrder.allCases, id: \.self) { order in
                Button {
                    sortOrder = order
                } label: {
                    HStack {
                        Text(order.rawValue)
                        if sortOrder == order {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10))
                Text(sortOrder.rawValue)
                    .font(.caption)
            }
            .foregroundStyle(CorveilTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(CorveilTheme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(CorveilTheme.borderSubtle, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pipeline View

/// Horizontal status timeline with "All" and the five pipeline stages.
struct PipelineView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // "All" segment
                AllPipelineSegment(
                    count: appState.filteredAssignedIssues.count,
                    isSelected: appState.selectedTicketStatus == nil
                ) {
                    appState.selectedTicketStatus = nil
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 2)

                ForEach(Array(TicketStatus.pipelineStatuses.enumerated()), id: \.element) { index, status in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 2)
                    }

                    PipelineSegment(
                        status: status,
                        count: appState.issueCount(for: status),
                        isSelected: appState.selectedTicketStatus == status
                    ) {
                        appState.selectedTicketStatus = status
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface.opacity(0.5))
    }
}

/// "All" segment in the pipeline view, showing total issue count.
struct AllPipelineSegment: View {
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.callout)
                    .foregroundStyle(CorveilTheme.gold)
                Text("All")
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? CorveilTheme.gold.opacity(0.2) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .foregroundStyle(isSelected ? CorveilTheme.gold : CorveilTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? CorveilTheme.gold.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Single pipeline stage segment with count badge.
struct PipelineSegment: View {
    let status: TicketStatus
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .font(.callout)
                    .foregroundStyle(status.color)
                Text(status.rawValue)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? status.color.opacity(0.2) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .foregroundStyle(isSelected ? status.color : CorveilTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? status.color.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ticket List View

/// Scrollable list of ticket cards, filtered by the selected pipeline stage.
struct TicketListView: View {
    @Bindable var appState: AppState
    var isSelectionMode: Bool
    @Binding var selectedIssueIDs: Set<String>

    var body: some View {
        let issues = appState.filteredSortedIssues
        if issues.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(issues) { issue in
                        TicketCard(
                            issue: issue,
                            appState: appState,
                            isDone: issue.projectStatus == .done,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedIssueIDs.contains(issue.id),
                            onToggleSelection: {
                                if selectedIssueIDs.contains(issue.id) {
                                    selectedIssueIDs.remove(issue.id)
                                } else {
                                    selectedIssueIDs.insert(issue.id)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "ticket")
                .font(.system(size: 36))
                .foregroundStyle(CorveilTheme.textMuted.opacity(0.5))
            if let status = appState.selectedTicketStatus {
                Text("No \(status.rawValue) Tickets")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CorveilTheme.textSecondary)
                if appState.ticketSearchText.isEmpty {
                    Text("No issues are in the \(status.rawValue) state.")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                } else {
                    Text("No \(status.rawValue) issues match \"\(appState.ticketSearchText)\"")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                }
            } else {
                Text("No Tickets Found")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CorveilTheme.textSecondary)
                if !appState.ticketSearchText.isEmpty {
                    Text("No issues match \"\(appState.ticketSearchText)\"")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Ticket Card

/// Card displaying a single ticket with repo, title, labels, status, and worktree action.
struct TicketCard: View {
    let issue: AssignedIssue
    @Bindable var appState: AppState
    let isDone: Bool
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)?

    private var linkedSession: Session? {
        appState.linkedSession(for: issue)
    }

    private var isSelectable: Bool {
        linkedSession == nil && !isDone
    }

    var body: some View {
        HStack(spacing: 8) {
            if isSelectionMode {
                selectionIndicator
            }

            VStack(alignment: .leading, spacing: 6) {
                // Row 1: Repo + issue number + PR badge + timestamp
                HStack(spacing: 6) {
                    Text(issue.repo)
                        .font(.caption)
                        .foregroundStyle(isDone ? CorveilTheme.textMuted : CorveilTheme.textSecondary)

                    LinkChip(
                        label: "Issue #\(String(issue.number))",
                        url: issue.url,
                        icon: "link"
                    )

                    if let prNum = issue.prNumber, let prURL = issue.prURL {
                        LinkChip(
                            label: "PR #\(String(prNum))",
                            url: prURL,
                            icon: "arrow.triangle.pull"
                        )
                    }

                    Spacer()

                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.6))
                    }

                    if let date = issue.updatedAt {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(CorveilTheme.textMuted)
                    }
                }

                // Row 2: Title
                Text(issue.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDone ? CorveilTheme.textMuted : CorveilTheme.textPrimary)
                    .lineLimit(2)

                // Row 3: Labels + status badge + session link
                HStack(spacing: 6) {
                    if !issue.labels.isEmpty {
                        labelRow
                    }

                    statusBadge

                    Spacer()

                    worktreeAction
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(cardBorder, lineWidth: 1)
                )
        )
        .opacity(isDone ? 0.7 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode && isSelectable {
                onToggleSelection?()
            }
        }
    }

    private var cardBackground: Color {
        if linkedSession != nil {
            return CorveilTheme.bgDone
        }
        return CorveilTheme.bgCard
    }

    private var cardBorder: Color {
        if isSelectionMode && isSelected {
            return CorveilTheme.gold.opacity(0.6)
        }
        if linkedSession != nil {
            return Color.green.opacity(0.2)
        }
        return CorveilTheme.borderSubtle
    }

    // MARK: - Subviews

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(isSelected ? CorveilTheme.gold : CorveilTheme.textMuted.opacity(0.4))
            .opacity(isSelectable ? 1.0 : 0.3)
    }

    private var labelRow: some View {
        LabelPillsView(labels: issue.labels, maxVisible: 3, muted: isDone)
    }

    private var statusBadge: some View {
        let status = issue.projectStatus
        return Text(status.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.12))
            .foregroundStyle(isDone ? status.color.opacity(0.6) : status.color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var worktreeAction: some View {
        if isSelectionMode {
            EmptyView()
        } else if let session = linkedSession {
            Button {
                appState.selectedSessionID = session.id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text(session.name)
                        .lineLimit(1)
                        .font(.caption)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.12))
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.3), lineWidth: 0.5))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        } else if !isDone {
            Button {
                appState.onWorkOnIssue?(issue.url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("Start Working")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(CorveilTheme.gold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(CorveilTheme.gold.opacity(0.1))
                .overlay(Capsule().strokeBorder(CorveilTheme.goldDark.opacity(0.3), lineWidth: 0.5))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Sidebar Row

/// Compact sidebar row showing ticket board with status counts using SF Symbols.
public struct TicketBoardSidebarRow: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Text("Tickets")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CorveilTheme.gold)
                if appState.isLoadingIssues {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
            }
            .overlay(alignment: .trailing) {
                refreshButton
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                StatusCount(status: .backlog, count: appState.issueCount(for: .backlog))
                StatusCount(status: .ready, count: appState.issueCount(for: .ready))
                StatusCount(status: .inProgress, count: appState.issueCount(for: .inProgress))
                StatusCount(status: .inReview, count: appState.issueCount(for: .inReview))
                StatusCount(status: .done, count: appState.doneIssuesLast24h)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CorveilTheme.bgSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(CorveilTheme.borderSubtle, lineWidth: 1)
                )
        )
    }

    /// Refreshes the ticket board without leaving the sidebar — same action as
    /// the board toolbar's refresh (`onManualRefresh`). `.plain` style keeps the
    /// tap on the button rather than selecting the enclosing list row.
    private var refreshButton: some View {
        Button {
            appState.onManualRefresh?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CorveilTheme.textSecondary)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CorveilTheme.bgCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(CorveilTheme.borderSubtle, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(appState.isLoadingIssues)
        .help("Refresh")
        .accessibilityLabel("Refresh tickets")
    }
}

/// Compact icon + count pair for a pipeline status in the sidebar.
struct StatusCount: View {
    let icon: String
    let color: Color
    let count: Int

    /// Derive icon + color from a single `TicketStatus` so the pair can't drift
    /// — the same source-of-truth guarantee the pipeline row relies on.
    init(status: TicketStatus, count: Int) {
        self.icon = status.icon
        self.color = status.color
        self.count = count
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(CorveilTheme.textSecondary)
        }
    }
}
