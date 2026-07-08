import SwiftUI
import CrowCore

/// Settings view for automation toggles: which repos surface review/ticket activity,
/// whether new sessions opt into remote control, Manager Terminal and code-review
/// permission modes, and auto-respond on PR review / CI signals.
public struct AutomationSettingsView: View {
    @Binding var defaults: ConfigDefaults
    @Binding var remoteControlEnabled: Bool
    @Binding var managerAutoPermissionMode: Bool
    @Binding var reviewAutoPermissionMode: Bool
    @Binding var managerGateway: WorkspaceGateway?
    @Binding var jiraCredential: JiraCredential?
    @Binding var autoRespond: AutoRespondSettings
    @Binding var attributionTrailers: Bool
    @Binding var autoMergeWatcherEnabled: Bool
    @Binding var autoCreateWatcherEnabled: Bool
    var onSave: (() -> Void)?

    @State private var managerGatewayBaseURL: String
    @State private var managerGatewayHeadersText: String

    @State private var jiraCredentialUsername: String
    @State private var jiraCredentialToken: String

    public init(
        defaults: Binding<ConfigDefaults>,
        remoteControlEnabled: Binding<Bool>,
        managerAutoPermissionMode: Binding<Bool>,
        reviewAutoPermissionMode: Binding<Bool>,
        managerGateway: Binding<WorkspaceGateway?>,
        jiraCredential: Binding<JiraCredential?>,
        autoRespond: Binding<AutoRespondSettings>,
        attributionTrailers: Binding<Bool>,
        autoMergeWatcherEnabled: Binding<Bool>,
        autoCreateWatcherEnabled: Binding<Bool>,
        onSave: (() -> Void)? = nil
    ) {
        self._defaults = defaults
        self._remoteControlEnabled = remoteControlEnabled
        self._managerAutoPermissionMode = managerAutoPermissionMode
        self._reviewAutoPermissionMode = reviewAutoPermissionMode
        self._managerGateway = managerGateway
        self._jiraCredential = jiraCredential
        self._autoRespond = autoRespond
        self._attributionTrailers = attributionTrailers
        self._autoMergeWatcherEnabled = autoMergeWatcherEnabled
        self._autoCreateWatcherEnabled = autoCreateWatcherEnabled
        self.onSave = onSave
        self._managerGatewayBaseURL = State(initialValue: managerGateway.wrappedValue?.baseURL ?? "")
        self._managerGatewayHeadersText = State(initialValue: managerGateway.wrappedValue.map {
            WorkspaceGateway.headerLines(from: $0.customHeaders)
        } ?? "")
        self._jiraCredentialUsername = State(initialValue: jiraCredential.wrappedValue?.username ?? "")
        self._jiraCredentialToken = State(initialValue: jiraCredential.wrappedValue?.tokenRef ?? "")
    }

    /// Reject a half-filled Manager gateway (base URL xor headers), matching the
    /// parse-time validation in `WorkspaceGateway`.
    private var managerGatewayValidationError: String? {
        let hasBaseURL = !managerGatewayBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHeaders = !WorkspaceGateway.parseHeaderLines(managerGatewayHeadersText).isEmpty
        if hasBaseURL && !hasHeaders { return "Add at least one custom header, or clear the Base URL." }
        if hasHeaders && !hasBaseURL { return "Set a Base URL, or remove the custom headers." }
        return nil
    }

    /// Push the editor fields back into the `managerGateway` binding (nil when
    /// both are empty, or while half-filled so an invalid block isn't persisted).
    private func commitManagerGateway() {
        let trimmedURL = managerGatewayBaseURL.trimmingCharacters(in: .whitespaces)
        let headers = WorkspaceGateway.parseHeaderLines(managerGatewayHeadersText)
        if trimmedURL.isEmpty && headers.isEmpty {
            managerGateway = nil
        } else if managerGatewayValidationError == nil {
            managerGateway = WorkspaceGateway(baseURL: trimmedURL, customHeaders: headers)
        } else {
            return  // half-filled — don't persist until valid
        }
        onSave?()
    }

    /// Reject a half-filled Jira credential (username xor token). Basic auth
    /// needs both.
    private var jiraCredentialValidationError: String? {
        let hasUsername = !jiraCredentialUsername.trimmingCharacters(in: .whitespaces).isEmpty
        let hasToken = !jiraCredentialToken.trimmingCharacters(in: .whitespaces).isEmpty
        if hasUsername && !hasToken { return "Add an API token, or clear the username." }
        if hasToken && !hasUsername { return "Add the username, or clear the API token." }
        return nil
    }

    /// Push the editor fields back into the `jiraCredential` binding (nil when both
    /// username and token are empty, or while half-filled so an invalid credential
    /// isn't persisted).
    private func commitJiraCredential() {
        let username = jiraCredentialUsername.trimmingCharacters(in: .whitespaces)
        let token = jiraCredentialToken.trimmingCharacters(in: .whitespaces)
        if username.isEmpty && token.isEmpty {
            jiraCredential = nil
        } else if jiraCredentialValidationError == nil {
            jiraCredential = JiraCredential(username: username, tokenRef: token)
        } else {
            return  // half-filled — don't persist until valid
        }
        onSave?()
    }

    public var body: some View {
        Form {
            Section("Reviews") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Repos")
                    TokenListEditor(tokens: $defaults.excludeReviewRepos, placeholder: "owner/repo")
                        .onChange(of: defaults.excludeReviewRepos) { _, _ in onSave?() }
                    Text("Repos to hide from the review board. Supports wildcards (e.g., zarf-dev/*, bmlt-enabled/yap).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Per-workspace auto-review opt-ins are configured in Workspaces → edit a workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored Labels")
                    TokenListEditor(tokens: $defaults.ignoreReviewLabels, placeholder: "label")
                        .onChange(of: defaults.ignoreReviewLabels) { _, _ in onSave?() }
                    Text("Labels to ignore from the review board (e.g., dependencies, renovate, automated).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tickets") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Repos")
                    TokenListEditor(tokens: $defaults.excludeTicketRepos, placeholder: "owner/repo")
                        .onChange(of: defaults.excludeTicketRepos) { _, _ in onSave?() }
                    Text("Repos to hide from the ticket board. Supports wildcards (e.g., zarf-dev/*, bmlt-enabled/yap).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Code Review") {
                Toggle("Run code reviews in auto permission mode", isOn: $reviewAutoPermissionMode)
                    .onChange(of: reviewAutoPermissionMode) { _, _ in onSave?() }
                Text("Passes --permission-mode auto so review sessions can run their review flow — crow, gh, and git commands — without per-call approval. Turn off to launch reviews in plan mode instead. Applies to newly kicked-off reviews.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manager AI Gateway") {
                TextField("Base URL (e.g., https://corveil.io)", text: $managerGatewayBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: managerGatewayBaseURL) { _, _ in commitManagerGateway() }

                Text("Custom Headers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $managerGatewayHeadersText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60)
                    .onChange(of: managerGatewayHeadersText) { _, _ in commitManagerGateway() }
                Text("One `Name: Value` per line. A value starting with `op://` is resolved at launch via the 1Password CLI and kept out of config.json (the resolved value is cached owner-only in settings.local.json); any other value is stored in plain text in config.json — prefer an `op://` reference for production keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = managerGatewayValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("The Manager sits at the dev root and isn't tied to one workspace, so it has its own gateway. Per-workspace gateways are set under Workspaces. Leave empty to use the vanilla Anthropic API. Takes effect on next app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Jira (status fetch)") {
                TextField("Username (JIRA_USERNAME, e.g. you@corp.com)", text: $jiraCredentialUsername)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: jiraCredentialUsername) { _, _ in commitJiraCredential() }

                TextField("API token (op:// reference or plaintext)", text: $jiraCredentialToken)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: jiraCredentialToken) { _, _ in commitJiraCredential() }
                Text("Personal API token from id.atlassian.com, sent as HTTP Basic (base64 of username:token). A value starting with `op://` is resolved on demand via the 1Password CLI and kept out of config.json; any other value is stored in plain text in config.json — prefer an `op://` reference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = jiraCredentialValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Used only by the in-app \"Fetch from Jira\" button under Workspaces, which queries a project's workflow statuses for the status map (the app can't use the MCP). Claude Code sessions get Jira via the global `jira` MCP server in ~/.claude.json, so nothing is injected here.")
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
            Toggle("Auto-rebase onto base and resolve conflicts", isOn: $autoRespond.autoRebaseAndResolveConflicts)
                .onChange(of: autoRespond.autoRebaseAndResolveConflicts) { _, _ in onSave?() }
            Text("When a Crow-authored PR falls behind its base or develops conflicts, Crow rebases the session's worktree onto the base and force-pushes with --force-with-lease. No label required. Only PRs whose commits include a Crow-Session trailer matching a known session are eligible. If the rebase hits conflicts, Crow asks the session's Claude Code terminal to resolve them. Never applies to review sessions. Off by default.")
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
