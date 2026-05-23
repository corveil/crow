import SwiftUI
import CrowCore

// MARK: - Changes Summary Board

/// Full-pane changes-summary board. Hit Generate to see a deterministic
/// cross-repo commit digest for the last 24 hours, grouped by repo
/// — the in-app counterpart to the `crow summary` CLI. Both converge on
/// `GitManager.summarizeCommits` via `appState.onGenerateSummary`.
public struct SummaryBoardView: View {
    @Bindable var appState: AppState

    /// Fixed window: the last 24 hours. More than a day of commits is already
    /// too much to skim, so there's no time-period selector — `git log --since`
    /// does the filtering.
    private static let sinceWindow = "24 hours ago"

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SectionHelpBanner(
                description: "A deterministic digest of the last 24 hours of commits, grouped by repo. Scoped to the repos you list in Settings → General → Changes Summary — nothing is summarized until at least one is listed. Same data as `crow summary`.",
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

            scopeMenu

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

    /// Dropdown listing the configured Changes-summary scope so it's clear which
    /// repos' commits are shown. Reflects `config.defaults.summaryRepos` (synced
    /// into `appState.summaryRepoScope`); edited in Settings, not here.
    private var scopeMenu: some View {
        Menu {
            if appState.summaryRepoScope.isEmpty {
                Text("No repos configured")
            } else {
                ForEach(appState.summaryRepoScope, id: \.self) { Text($0) }
            }
            Divider()
            Text("Edit in Settings → General → Changes Summary")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text("\(appState.summaryRepoScope.count) repo\(appState.summaryRepoScope.count == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(CorveilTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Text("Last 24 hours")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)
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
                Text("List repos in Settings → General → Changes Summary, then hit Generate to see what changed in the last 24 hours.")
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
                            commitRow(commit, urlPrefix: repo.commitURLPrefix)
                        }
                    } header: {
                        repoHeader(repo)
                    }
                }
            }
            .listStyle(.inset)
            .scrollIndicators(.visible)
        }
    }

    private func repoHeader(_ repo: RepoCommitSummary) -> some View {
        HStack {
            Text(repo.repo)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)
            Text("(\(repo.commits.count))")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)
            Spacer()
            Text("\(repo.totalFilesChanged) file\(repo.totalFilesChanged == 1 ? "" : "s"), +\(repo.totalInsertions) / -\(repo.totalDeletions)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(CorveilTheme.textMuted)
        }
    }

    /// A commit row. When the repo has a parseable remote (`urlPrefix`), the row
    /// is a button that opens the hosted commit page in the browser; otherwise
    /// it renders as plain text.
    @ViewBuilder
    private func commitRow(_ commit: CommitInfo, urlPrefix: String?) -> some View {
        let content = HStack(alignment: .top, spacing: 8) {
            Text(commit.shortHash)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(CorveilTheme.goldDark)
            Text(commit.subject)
                .font(.system(size: 14))
                .foregroundStyle(CorveilTheme.textPrimary)
            Spacer()
            Text(commit.authorName)
                .font(.system(size: 11))
                .foregroundStyle(CorveilTheme.textSecondary)
                .lineLimit(1)
            Text("+\(commit.insertions) / -\(commit.deletions)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(CorveilTheme.textMuted)
        }

        if let urlPrefix, let url = URL(string: urlPrefix + commit.hash) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open commit: \(urlPrefix + commit.hash)")
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            content
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: Actions

    private var totalCommits: Int {
        appState.lastSummary.reduce(0) { $0 + $1.commits.count }
    }

    /// Generate the digest for the fixed last-24-hours window.
    private func generate() {
        guard let onGenerate = appState.onGenerateSummary else { return }
        appState.isLoadingSummary = true
        Task {
            let result = await onGenerate(Self.sinceWindow, nil)
            appState.lastSummary = result
            appState.isLoadingSummary = false
        }
    }
}
