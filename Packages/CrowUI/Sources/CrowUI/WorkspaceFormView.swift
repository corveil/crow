import SwiftUI
import CrowCore

/// Outcome of a Jira live-status fetch for the workspace status-mapping UI (#523):
/// the workflow status names, or a user-facing error message.
public enum JiraStatusFetchResult: Sendable {
    case success([String])
    case failure(String)
}

/// Shared form for creating or editing a workspace.
///
/// Used by both the Settings workspace editor and the Setup Wizard.
/// Handles name, Code Backend (git/PR host) and Task Backend (ticket system)
/// selection, Jira-specific config, validation, and construction of a
/// `WorkspaceInfo` value on save.
///
/// Per ADR 0005 the Task Backend and Code Backend are two independent axes: a
/// workspace can keep code + PRs on GitHub while pulling tickets from Jira.
public struct WorkspaceFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var provider: String          // Code Backend: "github" | "gitlab"
    @State private var host: String
    @State private var taskProvider: String       // Task Backend: "github" | "gitlab" | "jira"
    @State private var jiraSite: String
    @State private var jiraProjectKey: String
    @State private var jiraJQL: String
    /// Per-pipeline-status Jira workflow name overrides, keyed by
    /// `TicketStatus.rawValue`. A blank/absent entry uses the built-in default
    /// (shown as the field's placeholder). See #523.
    @State private var jiraStatusMap: [String: String]
    /// Status names fetched from the live Jira workflow (bonus). Empty until the
    /// operator taps "Fetch from Jira"; surfaced as a dropdown of suggestions.
    @State private var fetchedStatuses: [String] = []
    @State private var isFetchingStatuses = false
    @State private var fetchStatusesError: String?
    @State private var corveilHost: String
    @State private var alwaysInclude: [String]
    @State private var autoReviewRepos: [String]
    @State private var excludeReviewRepos: [String]
    @State private var customInstructionsText: String
    @State private var gatewayBaseURL: String
    @State private var gatewayHeadersText: String

    /// Probed `acli` availability — gates whether Jira is offered as a Task Backend.
    @State private var jiraAvailability: JiraAvailability?

    private let existingID: UUID?
    private let existingNames: [String]
    private let onSave: (WorkspaceInfo) -> Void
    /// Injected live-status fetcher for the Jira mapping section (#523). Given a
    /// site host + project key, returns the workflow status names or a
    /// user-facing error. `nil` (e.g. the Setup Wizard) disables the button.
    private let fetchStatuses: ((String, String) async -> JiraStatusFetchResult)?

    /// - Parameters:
    ///   - workspace: An existing workspace to edit, or `nil` to create a new one.
    ///   - existingNames: Names of other workspaces, used for duplicate detection.
    ///   - fetchStatuses: Optional fetcher for the Jira status dropdown; `nil` disables it.
    ///   - onSave: Called with the validated `WorkspaceInfo` when the user taps Save/Add.
    public init(
        workspace: WorkspaceInfo? = nil,
        existingNames: [String] = [],
        fetchStatuses: ((String, String) async -> JiraStatusFetchResult)? = nil,
        onSave: @escaping (WorkspaceInfo) -> Void
    ) {
        self.fetchStatuses = fetchStatuses
        self.existingID = workspace?.id
        self._name = State(initialValue: workspace?.name ?? "")
        self._provider = State(initialValue: workspace?.provider ?? "github")
        self._host = State(initialValue: workspace?.host ?? "")
        self._taskProvider = State(initialValue: workspace?.derivedTaskProvider ?? workspace?.provider ?? "github")
        self._jiraSite = State(initialValue: workspace?.jiraSite ?? "")
        self._jiraProjectKey = State(initialValue: workspace?.jiraProjectKey ?? "")
        self._jiraJQL = State(initialValue: workspace?.jiraJQL ?? "")
        self._jiraStatusMap = State(initialValue: workspace?.jiraStatusMap ?? [:])
        self._corveilHost = State(initialValue: workspace?.corveilHost ?? "")
        self._alwaysInclude = State(initialValue: workspace?.alwaysInclude ?? [])
        self._autoReviewRepos = State(initialValue: workspace?.autoReviewRepos ?? [])
        self._excludeReviewRepos = State(initialValue: workspace?.excludeReviewRepos ?? [])
        self._customInstructionsText = State(initialValue: workspace?.customInstructions ?? "")
        self._gatewayBaseURL = State(initialValue: workspace?.gateway?.baseURL ?? "")
        self._gatewayHeadersText = State(initialValue: workspace?.gateway.map {
            WorkspaceGateway.headerLines(from: $0.customHeaders)
        } ?? "")
        self.existingNames = existingNames
        self.onSave = onSave
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var nameValidationError: String? {
        WorkspaceInfo.validateName(trimmedName, existingNames: existingNames)
    }

    private var jiraSelected: Bool { taskProvider == "jira" }
    private var corveilSelected: Bool { taskProvider == "corveil" }

    /// Jira is offered only when acli is installed + authenticated, OR when the
    /// workspace already had Jira selected (so an existing choice isn't silently
    /// hidden — we surface a warning instead).
    private var jiraOfferable: Bool {
        jiraAvailability == .ready || jiraSelected
    }

    /// Parsed header map from the editor text.
    private var parsedHeaders: [String: String] {
        WorkspaceGateway.parseHeaderLines(gatewayHeadersText)
    }

    /// Reject a half-filled gateway (base URL xor headers) — matches the
    /// parse-time validation in `WorkspaceGateway` so the UI never writes a
    /// config the decoder would later reject.
    private var gatewayValidationError: String? {
        let hasBaseURL = !gatewayBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHeaders = !parsedHeaders.isEmpty
        if hasBaseURL && !hasHeaders {
            return "Add at least one custom header (e.g. an API key), or clear the Base URL."
        }
        if hasHeaders && !hasBaseURL {
            return "Set a Base URL, or remove the custom headers."
        }
        return nil
    }

    /// The gateway to persist, or nil when both fields are empty.
    private var gatewayForSave: WorkspaceGateway? {
        let trimmedURL = gatewayBaseURL.trimmingCharacters(in: .whitespaces)
        let headers = parsedHeaders
        if trimmedURL.isEmpty && headers.isEmpty { return nil }
        return WorkspaceGateway(baseURL: trimmedURL, customHeaders: headers)
    }

    public var body: some View {
        Form {
            Section("Workspace") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                if let error = nameValidationError, !trimmedName.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Code Backend") {
                Picker("Code Backend", selection: $provider) {
                    Text("GitHub").tag("github")
                    Text("GitLab").tag("gitlab")
                }
                Text("Where code and pull/merge requests live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if provider == "gitlab" {
                    TextField("GitLab Host (e.g., gitlab.example.com)", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Task Backend") {
                Picker("Task Backend", selection: $taskProvider) {
                    Text("GitHub").tag("github")
                    Text("GitLab").tag("gitlab")
                    if jiraOfferable {
                        Text("Jira").tag("jira")
                    }
                    Text("Corveil").tag("corveil")
                }
                Text("Where tickets / work items live. Defaults to the Code Backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if jiraAvailability != nil, jiraAvailability != .ready {
                    Label(jiraAvailability?.fixHint ?? "Jira (acli) is not available.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(jiraSelected ? .red : .secondary)
                }

                if jiraSelected {
                    TextField("Atlassian Site (e.g., acme.atlassian.net)", text: $jiraSite)
                        .textFieldStyle(.roundedBorder)
                    TextField("Project Key (e.g., PROJ)", text: $jiraProjectKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("My-tickets JQL (optional)", text: $jiraJQL)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave JQL blank to use: assignee = currentUser() AND statusCategory != Done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if corveilSelected {
                    TextField("Corveil host (e.g., corveil.acme.io — optional)", text: $corveilHost)
                        .textFieldStyle(.roundedBorder)
                    Text("Only needed for self-hosted Corveil. Public corveil.io is auto-detected. The CLI authenticates against its own configured host (`corveil login`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if jiraSelected {
                Section("Jira Status Mapping") {
                    Text("Map Crow's pipeline states to this project's Jira workflow status names. Leave a field blank to use the default shown; names must match the project's workflow exactly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(TicketStatus.pipelineStatuses, id: \.self) { status in
                        HStack(spacing: 8) {
                            Text(status.rawValue)
                                .frame(width: 90, alignment: .leading)
                                .foregroundStyle(.secondary)
                            TextField(status.defaultJiraStatusName, text: jiraStatusBinding(for: status))
                                .textFieldStyle(.roundedBorder)
                            if !fetchedStatuses.isEmpty {
                                Menu {
                                    ForEach(fetchedStatuses, id: \.self) { name in
                                        Button(name) { jiraStatusMap[status.rawValue] = name }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Pick from statuses fetched from Jira")
                            }
                        }
                    }

                    HStack {
                        Button {
                            Task { await fetchJiraStatuses() }
                        } label: {
                            if isFetchingStatuses {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Fetch from Jira", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(isFetchingStatuses || !canFetchStatuses)
                        if let error = fetchStatusesError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Text(canFetchStatuses
                        ? "Populates a dropdown on each row from this project's live workflow."
                        : "Set the Atlassian Site + Project Key above and an Atlassian MCP credential in Settings → Automation to fetch live statuses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Repos") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always Include Repos")
                    TokenListEditor(tokens: $alwaysInclude, placeholder: "owner/repo or owner/*")
                    Text("Repo specs: owner/* lists all of an org's repos, or owner/repo for a single repo. Populates the Jobs repo picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Review Repos")
                    TokenListEditor(tokens: $autoReviewRepos, placeholder: "owner/repo or owner/*")
                    Text("Repos or patterns (e.g. org/repo, org/*). New review requests from matching repos will automatically create a review session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Review Repos")
                    TokenListEditor(tokens: $excludeReviewRepos, placeholder: "owner/repo or owner/*")
                    Text("Repos or patterns (e.g. org/repo, org/*). Review requests from matching repos are hidden from the review board and don't trigger notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Custom Instructions") {
                TextEditor(text: $customInstructionsText)
                    .font(.body)
                    .frame(minHeight: 80)
                Text("Instructions appended to the session prompt (e.g., \"Always run npm test before committing\").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Gateway") {
                TextField("Base URL (e.g., https://corveil.io)", text: $gatewayBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Text("Custom Headers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $gatewayHeadersText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60)
                Text("One `Name: Value` per line. A value starting with `op://` is resolved at launch via the 1Password CLI and kept out of config.json (the resolved value is cached owner-only in the worktree's settings.local.json). Any other value is stored in plain text in config.json — anyone with read access can see it; prefer an `op://` reference for production keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = gatewayValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("When set, `claude` launches in this workspace route through this gateway (ANTHROPIC_BASE_URL / ANTHROPIC_CUSTOM_HEADERS). Leave empty to use the vanilla Anthropic API. Does not affect the Manager session — set that under Automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            jiraAvailability = await AcliProbe.availability()
        }
        // A previously-fetched status list belongs to the old site/project — drop
        // it (and any error) when either changes so a stale list can't be applied
        // to a different project.
        .onChange(of: jiraSite) { _, _ in clearFetchedStatuses() }
        .onChange(of: jiraProjectKey) { _, _ in clearFetchedStatuses() }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(existingID != nil ? "Save" : "Add") {
                    onSave(buildWorkspace())
                    dismiss()
                }
                .disabled(nameValidationError != nil || gatewayValidationError != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 640)
    }

    private func buildWorkspace() -> WorkspaceInfo {
        let trimmedInstructions = customInstructionsText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Persist taskProvider only when it diverges from the code provider;
        // otherwise leave nil so the workspace "follows" the code backend.
        let resolvedTaskProvider: String? = (taskProvider == provider) ? nil : taskProvider
        let isJira = taskProvider == "jira"
        let isCorveil = taskProvider == "corveil"

        return WorkspaceInfo(
            id: existingID ?? UUID(),
            name: trimmedName,
            provider: provider,
            cli: provider == "github" ? "gh" : "glab",
            host: provider == "gitlab" && !host.isEmpty ? host : nil,
            alwaysInclude: alwaysInclude,
            autoReviewRepos: autoReviewRepos,
            excludeReviewRepos: excludeReviewRepos,
            customInstructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
            taskProvider: resolvedTaskProvider,
            jiraProjectKey: isJira ? nonEmpty(jiraProjectKey) : nil,
            jiraJQL: isJira ? nonEmpty(jiraJQL) : nil,
            jiraSite: isJira ? nonEmpty(jiraSite) : nil,
            jiraStatusMap: isJira ? statusMapForSave : nil,
            corveilHost: isCorveil ? nonEmpty(corveilHost) : nil,
            gateway: gatewayForSave
        )
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A two-way binding for one status's override field. Stores the value as
    /// typed; `statusMapForSave` trims and drops blanks at save time.
    private func jiraStatusBinding(for status: TicketStatus) -> Binding<String> {
        Binding(
            get: { jiraStatusMap[status.rawValue] ?? "" },
            set: { jiraStatusMap[status.rawValue] = $0 }
        )
    }

    /// The trimmed, non-empty overrides to persist, or `nil` when none are set
    /// (so the workspace falls back entirely to the built-in defaults).
    private var statusMapForSave: [String: String]? {
        var result: [String: String] = [:]
        for status in TicketStatus.pipelineStatuses {
            if let name = jiraStatusMap[status.rawValue]?.nonBlank { result[status.rawValue] = name }
        }
        return result.isEmpty ? nil : result
    }

    /// "Fetch from Jira" is available only when a fetcher is wired and the site +
    /// project key are filled in (the credential check happens in the fetcher).
    private var canFetchStatuses: Bool {
        fetchStatuses != nil
            && !jiraSite.trimmingCharacters(in: .whitespaces).isEmpty
            && !jiraProjectKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Pull the live workflow status names for the configured project into
    /// `fetchedStatuses` (drives the per-row dropdown). Best-effort: surfaces a
    /// caption-level error and leaves the free-text fields untouched on failure.
    /// Drop a stale fetched-status list (and error) when the site/project changes.
    private func clearFetchedStatuses() {
        fetchedStatuses = []
        fetchStatusesError = nil
    }

    private func fetchJiraStatuses() async {
        guard let fetchStatuses else { return }
        isFetchingStatuses = true
        fetchStatusesError = nil
        defer { isFetchingStatuses = false }
        switch await fetchStatuses(jiraSite, jiraProjectKey) {
        case .success(let names):
            fetchedStatuses = names
            if names.isEmpty { fetchStatusesError = "No statuses returned for this project." }
        case .failure(let message):
            fetchStatusesError = message
        }
    }
}
