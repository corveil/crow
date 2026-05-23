import SwiftUI
import CrowCore

/// Settings view for automation toggles: which repos surface review/ticket activity,
/// whether new sessions opt into remote control, Manager Terminal permission mode,
/// and auto-respond on PR review / CI signals.
public struct AutomationSettingsView: View {
    @Binding var defaults: ConfigDefaults
    @Binding var remoteControlEnabled: Bool
    @Binding var managerAutoPermissionMode: Bool
    @Binding var autoRespond: AutoRespondSettings
    @Binding var attributionTrailers: Bool
    @Binding var autoMergeWatcherEnabled: Bool
    @Binding var autoCreateWatcherEnabled: Bool
    @Binding var autoRebaseWatcherEnabled: Bool
    var onSave: (() -> Void)?

    @State private var excludeReviewReposText: String
    @State private var ignoreReviewLabelsText: String
    @State private var excludeTicketReposText: String

    public init(
        defaults: Binding<ConfigDefaults>,
        remoteControlEnabled: Binding<Bool>,
        managerAutoPermissionMode: Binding<Bool>,
        autoRespond: Binding<AutoRespondSettings>,
        attributionTrailers: Binding<Bool>,
        autoMergeWatcherEnabled: Binding<Bool>,
        autoCreateWatcherEnabled: Binding<Bool>,
        autoRebaseWatcherEnabled: Binding<Bool>,
        onSave: (() -> Void)? = nil
    ) {
        self._defaults = defaults
        self._remoteControlEnabled = remoteControlEnabled
        self._managerAutoPermissionMode = managerAutoPermissionMode
        self._autoRespond = autoRespond
        self._attributionTrailers = attributionTrailers
        self._autoMergeWatcherEnabled = autoMergeWatcherEnabled
        self._autoCreateWatcherEnabled = autoCreateWatcherEnabled
        self._autoRebaseWatcherEnabled = autoRebaseWatcherEnabled
        self.onSave = onSave
        self._excludeReviewReposText = State(initialValue: defaults.wrappedValue.excludeReviewRepos.joined(separator: ", "))
        self._ignoreReviewLabelsText = State(initialValue: defaults.wrappedValue.ignoreReviewLabels.joined(separator: ", "))
        self._excludeTicketReposText = State(initialValue: defaults.wrappedValue.excludeTicketRepos.joined(separator: ", "))
    }

    public var body: some View {
        Form {
            Section("Reviews") {
                TextField("Excluded Repos", text: $excludeReviewReposText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: excludeReviewReposText) { _, _ in
                        defaults.excludeReviewRepos = excludeReviewReposText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave?()
                    }
                Text("Comma-separated repos to hide from the review board. Supports wildcards (e.g., zarf-dev/*, bmlt-enabled/yap).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Per-workspace auto-review opt-ins are configured in Workspaces → edit a workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Ignored Labels", text: $ignoreReviewLabelsText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ignoreReviewLabelsText) { _, _ in
                        defaults.ignoreReviewLabels = ignoreReviewLabelsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave?()
                    }
                Text("Comma-separated labels to ignore from the review board (e.g., dependencies, renovate, automated).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tickets") {
                TextField("Excluded Repos", text: $excludeTicketReposText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: excludeTicketReposText) { _, _ in
                        defaults.excludeTicketRepos = excludeTicketReposText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave?()
                    }
                Text("Comma-separated repos to hide from the ticket board. Supports wildcards (e.g., zarf-dev/*, bmlt-enabled/yap).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote Control") {
                Toggle("Enable remote control for new sessions", isOn: $remoteControlEnabled)
                    .onChange(of: remoteControlEnabled) { _, _ in onSave?() }
                Text("New Claude Code sessions start with --rc so you can control them from claude.ai or the Claude mobile app. Each session's name matches its Crow session name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manager Terminal") {
                Toggle("Launch in auto permission mode", isOn: $managerAutoPermissionMode)
                    .onChange(of: managerAutoPermissionMode) { _, _ in onSave?() }
                Text("Passes --permission-mode auto so the Manager can run crow, gh, and git commands without per-call approval. Requires Claude Code 2.1.83+ on a Max, Team, Enterprise, or API plan with the Anthropic provider. Turn off if your account reports auto mode as unavailable. Takes effect on next app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Attribution") {
                Toggle("Add Crow-Session trailer to commits", isOn: $attributionTrailers)
                    .onChange(of: attributionTrailers) { _, _ in onSave?() }
                Text("Writes a per-worktree .claude/settings.local.json that overrides Claude Code's commit attribution to include a Crow-Session: <uuid> trailer alongside Co-Authored-By: Claude. Applies to new worktrees only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Auto-launch workspaces") {
                Toggle("Auto-launch workspaces for crow:auto labeled issues", isOn: $autoCreateWatcherEnabled)
                    .onChange(of: autoCreateWatcherEnabled) { _, _ in onSave?() }
                Text("When enabled, the Manager detects assigned issues tagged crow:auto and runs /crow-workspace automatically. The label is removed after dispatch so each issue triggers once. Requires Crow (and the Manager) to be running. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Auto-merge") {
                Toggle("Enable crow:merge auto-merge for Crow-authored PRs", isOn: $autoMergeWatcherEnabled)
                    .onChange(of: autoMergeWatcherEnabled) { _, _ in onSave?() }
                Text("When a PR linked to a Crow session carries the crow:merge label, Crow enables GitHub native auto-merge with squash + delete branch. Only PRs whose commits include a Crow-Session trailer matching a known session are eligible. GitHub holds the merge until required reviews and checks pass. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Auto-rebase") {
                Toggle("Auto-rebase Crow-authored PR branches that fall behind or conflict", isOn: $autoRebaseWatcherEnabled)
                    .onChange(of: autoRebaseWatcherEnabled) { _, _ in onSave?() }
                Text("When a PR linked to a Crow session falls behind its base or develops conflicts, Crow rebases the session's worktree onto the base and force-pushes with --force-with-lease. No label required. Only PRs whose commits include a Crow-Session trailer matching a known session are eligible. If the rebase hits conflicts, Crow asks the session's Claude Code terminal to resolve them. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            autoRespondSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var autoRespondSection: some View {
        Section {
            Toggle("Respond to 'changes requested' reviews", isOn: $autoRespond.respondToChangesRequested)
                .onChange(of: autoRespond.respondToChangesRequested) { _, _ in onSave?() }
            Toggle("Respond to failed CI checks", isOn: $autoRespond.respondToFailedChecks)
                .onChange(of: autoRespond.respondToFailedChecks) { _, _ in onSave?() }
            Text("When enabled, Crow types an instruction into the session's Claude Code terminal asking Claude to read the review or CI logs and address the issue. Off by default — typing into a terminal unprompted is intrusive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-respond")
                Text("Automatically prompt Claude to fix PR feedback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
