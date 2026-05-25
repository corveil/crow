import SwiftUI
import CrowCore

// MARK: - Main Review Board View

/// Full-pane review board shown when the Review Board tab is selected.
public struct ReviewBoardView: View {
    @Bindable var appState: AppState
    @State private var isSelectionMode = false
    @State private var selectedRequestIDs: Set<String> = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            reviewBoardHeader
            SectionHelpBanner(
                description: "PRs where your review has been requested. Quickly kick off a review session from here.",
                storageKey: "helpDismissed_reviews"
            )
            Divider()
            reviewList

            if isSelectionMode && !selectedRequestIDs.isEmpty {
                batchActionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            // Mark all current review requests as seen
            for request in appState.filteredReviewRequests {
                appState.seenReviewRequestIDs.insert(request.id)
            }
        }
    }

    private var reviewBoardHeader: some View {
        HStack {
            Text("Reviews")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)

            if appState.isLoadingReviews {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text("\(appState.filteredReviewRequests.count) pending")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)

            refreshButton

            selectToggleButton
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
        .disabled(appState.isLoadingReviews)
        .help("Refresh")
        .accessibilityLabel("Refresh reviews")
    }

    private var selectToggleButton: some View {
        Button {
            isSelectionMode.toggle()
            if !isSelectionMode {
                selectedRequestIDs.removeAll()
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
            Text("\(selectedRequestIDs.count) review\(selectedRequestIDs.count == 1 ? "" : "s") selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CorveilTheme.textSecondary)

            Spacer()

            Button {
                isSelectionMode = false
                selectedRequestIDs.removeAll()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13))
                    .foregroundStyle(CorveilTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button {
                let urls = appState.filteredReviewRequests
                    .filter { selectedRequestIDs.contains($0.id) }
                    .map(\.url)
                appState.onBatchStartReview?(urls)
                selectedRequestIDs.removeAll()
                isSelectionMode = false
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye.circle")
                        .font(.system(size: 10))
                    Text("Start Review (\(selectedRequestIDs.count))")
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

    @ViewBuilder
    private var reviewList: some View {
        if appState.filteredReviewRequests.isEmpty {
            VStack {
                Spacer().frame(height: 40)
                Image(systemName: "eye.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(CorveilTheme.textMuted)
                Text("No Pending Reviews")
                    .font(.headline)
                    .foregroundStyle(CorveilTheme.textSecondary)
                    .padding(.top, 8)
                Text("When someone requests your review on a PR, it will appear here.")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(appState.filteredReviewRequests) { request in
                ReviewRow(
                    request: request,
                    appState: appState,
                    isSelectionMode: isSelectionMode,
                    isSelected: selectedRequestIDs.contains(request.id),
                    onToggleSelection: {
                        if selectedRequestIDs.contains(request.id) {
                            selectedRequestIDs.remove(request.id)
                        } else {
                            selectedRequestIDs.insert(request.id)
                        }
                    }
                )
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Review Row

struct ReviewRow: View {
    let request: ReviewRequest
    @Bindable var appState: AppState
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)?

    private var linkedSession: Session? {
        guard let sessionID = request.reviewSessionID else { return nil }
        return appState.sessions.first { $0.id == sessionID }
    }

    private var isSelectable: Bool {
        linkedSession == nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isSelectionMode {
                selectionIndicator
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(request.repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("#\(String(request.prNumber))")
                        .font(.callout)
                        .fontWeight(.medium)
                    if request.isDraft {
                        draftBadge
                    }
                }
                Text(request.title)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("by @\(request.author)")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                    Text("\u{2022}")
                        .font(.caption2)
                        .foregroundStyle(CorveilTheme.textMuted)
                    Text(request.headBranch)
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                        .lineLimit(1)
                    if let date = request.requestedAt {
                        Text("\u{2022}")
                            .font(.caption2)
                            .foregroundStyle(CorveilTheme.textMuted)
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(CorveilTheme.textMuted)
                    }
                }

                if !request.labels.isEmpty {
                    LabelPillsView(labels: request.labels, maxVisible: 3)
                }
            }

            Spacer()

            reviewAction
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode && isSelectable {
                onToggleSelection?()
            }
        }
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(isSelected ? CorveilTheme.gold : CorveilTheme.textMuted.opacity(0.4))
            .opacity(isSelectable ? 1.0 : 0.3)
    }

    private var draftBadge: some View {
        Text("Draft")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var reviewAction: some View {
        if isSelectionMode {
            EmptyView()
        } else if let sessionID = request.reviewSessionID,
           appState.sessions.contains(where: { $0.id == sessionID }) {
            Button {
                appState.selectedSessionID = sessionID
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                    Text("Go to Session")
                        .lineLimit(1)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                appState.onStartReview?(request.url)
            } label: {
                Label("Start Review", systemImage: "eye.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Sidebar Row

/// Combined Manager, Reviews, and Allowlist toggle buttons in the sidebar. The
/// Manager toggle and its "new Manager" (+) button appear once the primary
/// Manager has loaded; Reviews and Allowlist are always present.
public struct ManagerReviewsAllowListRow: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 6) {
            if appState.managerSession != nil {
                managerButton
                newManagerButton
            }
            reviewButton
            allowListButton
        }
        .padding(.vertical, 2)
    }

    private var managerButton: some View {
        sidebarButton(
            title: "Manager",
            isActive: appState.selectedSessionID == AppState.managerSessionID
        ) {
            appState.selectedSessionID = AppState.managerSessionID
        }
        .overlay(alignment: .topTrailing) {
            if appState.isRemoteControlActive(sessionID: AppState.managerSessionID) {
                RemoteControlBadge(compact: true)
                    .padding(4)
            }
        }
    }

    private var newManagerButton: some View {
        Button {
            appState.onCreateManager?()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(CorveilTheme.goldDark)
                .frame(width: 28)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CorveilTheme.bgSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(CorveilTheme.goldDark.opacity(0.3), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .help("New Manager session")
        .accessibilityLabel("New Manager session")
    }

    /// Shared full-width pill styling for the toggle buttons in this row.
    private func sidebarButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isActive ? CorveilTheme.gold : CorveilTheme.goldDark)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? CorveilTheme.bgCard : CorveilTheme.bgSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    isActive ? CorveilTheme.goldDark.opacity(0.6) : CorveilTheme.goldDark.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var allowListButton: some View {
        let isActive = appState.selectedSessionID == AppState.allowListSessionID
        return Button {
            appState.selectedSessionID = AppState.allowListSessionID
        } label: {
            Text("Allowlist")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isActive ? CorveilTheme.gold : CorveilTheme.goldDark)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? CorveilTheme.bgCard : CorveilTheme.bgSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    isActive ? CorveilTheme.goldDark.opacity(0.6) : CorveilTheme.goldDark.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var reviewButton: some View {
        let isActive = appState.selectedSessionID == AppState.reviewBoardSessionID
        return Button {
            appState.selectedSessionID = AppState.reviewBoardSessionID
        } label: {
            HStack(spacing: 4) {
                Text("Reviews")
                    .font(.system(size: 12, weight: .bold))
                if appState.isLoadingReviews {
                    ProgressView()
                        .controlSize(.mini)
                }
                if appState.filteredReviewRequests.count > 0 {
                    Text("\(appState.filteredReviewRequests.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(appState.unseenReviewCount > 0 ? CorveilTheme.gold.opacity(0.2) : Color.secondary.opacity(0.15))
                        .foregroundStyle(appState.unseenReviewCount > 0 ? CorveilTheme.gold : CorveilTheme.textSecondary)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isActive ? CorveilTheme.gold : CorveilTheme.goldDark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? CorveilTheme.bgCard : CorveilTheme.bgSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isActive ? CorveilTheme.goldDark.opacity(0.6) : CorveilTheme.goldDark.opacity(0.3),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
