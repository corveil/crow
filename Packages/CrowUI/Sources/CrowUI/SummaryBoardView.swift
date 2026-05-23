import SwiftUI
import CrowCore

// MARK: - Changes Summary Board

/// Full-pane changes-summary board. Lets the user pick a time window, hit
/// Generate, and see a deterministic cross-repo commit digest grouped by repo
/// — the in-app counterpart to the `crow summary` CLI. Both converge on
/// `GitManager.summarizeCommits` via `appState.onGenerateSummary`.
public struct SummaryBoardView: View {
    @Bindable var appState: AppState

    /// Preset windows. `.custom` reveals two date pickers.
    private enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        case month = "30 days"
        case custom = "Custom"
        var id: String { rawValue }
    }

    @State private var period: Period = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SectionHelpBanner(
                description: "A deterministic digest of commits for the chosen window, grouped by repo. Scoped to the repos you list in Settings → General → Changes Summary — nothing is summarized until at least one is listed. Same data as `crow summary`.",
                storageKey: "helpDismissed_summary"
            )
            controls
            Divider()
            resultsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Changes Summary")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)

            if appState.isLoadingSummary {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if !appState.lastSummary.isEmpty {
                Text("\(totalCommits) commit\(totalCommits == 1 ? "" : "s") · \(appState.lastSummary.count) repo\(appState.lastSummary.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if period == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                .font(.caption)
            }

            HStack {
                Spacer()
                Button(action: generate) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                        Text("Generate")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(CorveilTheme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(appState.isLoadingSummary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        if appState.lastSummary.isEmpty {
            VStack {
                Spacer().frame(height: 40)
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 32))
                    .foregroundStyle(CorveilTheme.textMuted)
                Text(appState.isLoadingSummary ? "Generating…" : "No Summary Yet")
                    .font(.headline)
                    .foregroundStyle(CorveilTheme.textSecondary)
                    .padding(.top, 8)
                Text("List repos in Settings → General → Changes Summary, pick a window, and hit Generate to see what changed.")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(appState.lastSummary) { repo in
                    Section {
                        ForEach(repo.commits) { commit in
                            commitRow(commit)
                        }
                    } header: {
                        repoHeader(repo)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func repoHeader(_ repo: RepoCommitSummary) -> some View {
        HStack {
            Text(repo.repo)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)
            Text("(\(repo.commits.count))")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)
            Spacer()
            Text("\(repo.totalFilesChanged) file\(repo.totalFilesChanged == 1 ? "" : "s"), +\(repo.totalInsertions) / -\(repo.totalDeletions)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CorveilTheme.textMuted)
        }
    }

    private func commitRow(_ commit: CommitInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CorveilTheme.goldDark)
            Text(commit.subject)
                .font(.system(size: 12))
                .foregroundStyle(CorveilTheme.textPrimary)
            Spacer()
            Text("+\(commit.insertions) / -\(commit.deletions)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CorveilTheme.textMuted)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: Actions

    private var totalCommits: Int {
        appState.lastSummary.reduce(0) { $0 + $1.commits.count }
    }

    /// Map the selected period to git date strings and generate.
    private func generate() {
        let since: String
        let until: String?
        switch period {
        case .today:
            since = "midnight"
            until = nil
        case .week:
            since = "7 days ago"
            until = nil
        case .month:
            since = "30 days ago"
            until = nil
        case .custom:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            since = fmt.string(from: customStart)
            until = fmt.string(from: customEnd)
        }

        guard let onGenerate = appState.onGenerateSummary else { return }
        appState.isLoadingSummary = true
        Task {
            let result = await onGenerate(since, until)
            appState.lastSummary = result
            appState.isLoadingSummary = false
        }
    }
}
