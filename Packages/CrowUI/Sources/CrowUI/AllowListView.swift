import SwiftUI
import CrowCore

// MARK: - Main Allowlist View

/// Full-pane view for aggregating and promoting allowlist entries.
public struct AllowListView: View {
    @Bindable var appState: AppState
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var hideGlobal = false

    public init(appState: AppState) {
        self.appState = appState
    }

    private var filteredEntries: [AllowEntry] {
        var entries = appState.allowEntries
        if hideGlobal {
            entries = entries.filter { !$0.isInGlobal }
        }
        if !searchText.isEmpty {
            entries = entries.filter {
                $0.pattern.localizedCaseInsensitiveContains(searchText)
            }
        }
        return entries
    }

    private var promotableSelection: Set<String> {
        selection.filter { pattern in
            appState.allowEntries.first { $0.pattern == pattern }?.isInGlobal == false
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SectionHelpBanner(
                description: "Promote worktree allow-list entries to the global list so you don't have to re-approve them in future worktrees.",
                storageKey: "helpDismissed_allowList"
            )
            Divider()
            toolbar
            Divider()
            entryList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            appState.onLoadAllowList?()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Allowlist")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)

            if appState.isLoadingAllowList {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text("\(appState.allowEntries.count) entries")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            SearchField("Filter patterns\u{2026}", text: $searchText)

            Toggle("Hide Global", isOn: $hideGlobal)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(CorveilTheme.textSecondary)

            Spacer()

            Button {
                appState.onLoadAllowList?()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                appState.onPromoteToGlobal?(promotableSelection)
                selection = []
            } label: {
                Label("Promote to Global", systemImage: "arrow.up.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(promotableSelection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(CorveilTheme.bgSurface)
    }

    // MARK: - Entry List

    private var entryList: some View {
        List(filteredEntries, selection: $selection) { entry in
            AllowEntryRow(entry: entry)
                .listRowSeparator(.visible)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(CorveilTheme.bgDeep)
    }
}

// MARK: - Entry Row

/// Row displaying a single allow-list entry with source badges.
struct AllowEntryRow: View {
    let entry: AllowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.pattern)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(entry.isInGlobal ? CorveilTheme.textMuted : CorveilTheme.textPrimary)

            HStack(spacing: 6) {
                if entry.isInGlobal {
                    CapsuleBadge("Global", color: .green)
                }
                ForEach(entry.worktreeSessionNames, id: \.self) { name in
                    CapsuleBadge(name, color: .blue)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(entry.isInGlobal ? 0.6 : 1.0)
    }
}

