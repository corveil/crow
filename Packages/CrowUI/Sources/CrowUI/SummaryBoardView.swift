import SwiftUI
import CrowCore

// MARK: - Changes Summary Board

/// Full-pane changes-summary board. Lets the user pick a time window, hit
/// Generate, and see a deterministic cross-repo commit digest grouped by repo
/// — the in-app counterpart to the `crow summary` CLI. Both converge on
/// `GitManager.summarizeCommits` via `appState.onGenerateSummary`.
public struct SummaryBoardView: View {
    @Bindable var appState: AppState

    /// Preset windows. Deliberately short — more than a day or two of commits is
    /// already too much to skim at a glance.
    private enum Period: String, CaseIterable, Identifiable {
        case day24 = "24 hours"
        case day48 = "48 hours"
        var id: String { rawValue }
    }

    @State private var period: Period = .day24

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
            narrativeCard
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

            HStack(spacing: 8) {
                Spacer()
                Button(action: summarizeWithLLM) {
                    HStack(spacing: 4) {
                        if appState.isSummarizingLLM {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                        }
                        Text("LLM Summarize")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(CorveilTheme.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(CorveilTheme.goldDark.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.lastSummary.isEmpty || appState.isLoadingSummary || appState.isSummarizingLLM)

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

    // MARK: LLM narrative

    /// Narrative card shown above the results once an LLM summary is produced
    /// (or an error if the run failed). Dismissible by clearing the text.
    @ViewBuilder
    private var narrativeCard: some View {
        if let error = appState.llmSummaryError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
                Spacer()
                Button {
                    appState.llmSummaryError = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CorveilTheme.textMuted)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
        } else if !appState.llmNarrative.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("LLM Summary", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CorveilTheme.gold)
                    Spacer()
                    Button {
                        appState.llmNarrative = ""
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CorveilTheme.textMuted)
                }
                Text(appState.llmNarrative)
                    .font(.system(size: 12))
                    .foregroundStyle(CorveilTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(CorveilTheme.gold.opacity(0.06))
        }
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
                            commitRow(commit, urlPrefix: repo.commitURLPrefix)
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

    /// A commit row. When the repo has a parseable remote (`urlPrefix`), the row
    /// is a button that opens the hosted commit page in the browser; otherwise
    /// it renders as plain text.
    @ViewBuilder
    private func commitRow(_ commit: CommitInfo, urlPrefix: String?) -> some View {
        let content = HStack(alignment: .top, spacing: 8) {
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

    /// Map the selected period to git date strings and generate.
    private func generate() {
        let since: String
        switch period {
        case .day24: since = "24 hours ago"
        case .day48: since = "48 hours ago"
        }
        let until: String? = nil

        guard let onGenerate = appState.onGenerateSummary else { return }
        appState.isLoadingSummary = true
        // The previous narrative describes a stale digest — drop it.
        appState.llmNarrative = ""
        appState.llmSummaryError = nil
        Task {
            let result = await onGenerate(since, until)
            appState.lastSummary = result
            appState.isLoadingSummary = false
        }
    }

    /// Build a text digest of the current results and hand it to the LLM.
    private func summarizeWithLLM() {
        guard let onSummarize = appState.onSummarizeWithLLM,
              !appState.lastSummary.isEmpty else { return }
        let digest = Self.buildDigest(appState.lastSummary)
        appState.isSummarizingLLM = true
        appState.llmSummaryError = nil
        appState.llmNarrative = ""
        Task {
            do {
                appState.llmNarrative = try await onSummarize(digest)
            } catch {
                appState.llmSummaryError = error.localizedDescription
            }
            appState.isSummarizingLLM = false
        }
    }

    /// Render the digest the same way a human reads the board: a header per repo
    /// with counts/stats, then one line per commit.
    static func buildDigest(_ summaries: [RepoCommitSummary]) -> String {
        var lines: [String] = []
        for repo in summaries {
            lines.append("## \(repo.repo) — \(repo.commits.count) commit\(repo.commits.count == 1 ? "" : "s"), \(repo.totalFilesChanged) file\(repo.totalFilesChanged == 1 ? "" : "s"), +\(repo.totalInsertions)/-\(repo.totalDeletions)")
            for c in repo.commits {
                lines.append("- \(c.shortHash) \(c.subject) (+\(c.insertions)/-\(c.deletions))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
