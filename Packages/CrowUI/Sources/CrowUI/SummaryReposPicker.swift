import SwiftUI
import CrowCore

/// Checklist of repos discovered under the dev root, used in Settings to scope
/// which repositories the Changes board summarizes. Selections are stored as
/// "workspace/name" keys in `ConfigDefaults.summaryRepos`. Repos are loaded
/// asynchronously once via the injected `listRepos` closure.
struct SummaryReposPicker: View {
    @Binding var selected: [String]
    let listRepos: () async -> [String]
    var onSave: (() -> Void)?

    @State private var options: [String] = []
    @State private var isLoading = false
    @State private var didLoad = false

    var body: some View {
        Group {
            if isLoading && options.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Discovering repos…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if options.isEmpty {
                Text("No repositories found under the dev root.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options, id: \.self) { repo in
                    Toggle(repo, isOn: binding(for: repo))
                }
            }
        }
        .task { await load() }
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(repo) },
            set: { isOn in
                if isOn {
                    if !selected.contains(repo) { selected.append(repo) }
                } else {
                    selected.removeAll { $0 == repo }
                }
                onSave?()
            }
        )
    }

    // Loads once per view lifetime: a repo added to the dev root while Settings
    // is open won't appear until the panel is closed and reopened.
    private func load() async {
        guard !didLoad else { return }
        isLoading = true
        options = await listRepos().sorted()
        isLoading = false
        didLoad = true
    }
}
