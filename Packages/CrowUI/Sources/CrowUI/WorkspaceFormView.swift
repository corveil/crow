import SwiftUI
import CrowCore

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
    @State private var alwaysIncludeText: String
    @State private var autoReviewReposText: String
    @State private var customInstructionsText: String

    /// Probed `acli` availability — gates whether Jira is offered as a Task Backend.
    @State private var jiraAvailability: JiraAvailability?

    private let existingID: UUID?
    private let existingNames: [String]
    private let onSave: (WorkspaceInfo) -> Void

    /// - Parameters:
    ///   - workspace: An existing workspace to edit, or `nil` to create a new one.
    ///   - existingNames: Names of other workspaces, used for duplicate detection.
    ///   - onSave: Called with the validated `WorkspaceInfo` when the user taps Save/Add.
    public init(
        workspace: WorkspaceInfo? = nil,
        existingNames: [String] = [],
        onSave: @escaping (WorkspaceInfo) -> Void
    ) {
        self.existingID = workspace?.id
        self._name = State(initialValue: workspace?.name ?? "")
        self._provider = State(initialValue: workspace?.provider ?? "github")
        self._host = State(initialValue: workspace?.host ?? "")
        self._taskProvider = State(initialValue: workspace?.derivedTaskProvider ?? workspace?.provider ?? "github")
        self._jiraSite = State(initialValue: workspace?.jiraSite ?? "")
        self._jiraProjectKey = State(initialValue: workspace?.jiraProjectKey ?? "")
        self._jiraJQL = State(initialValue: workspace?.jiraJQL ?? "")
        self._alwaysIncludeText = State(initialValue: workspace?.alwaysInclude.joined(separator: ", ") ?? "")
        self._autoReviewReposText = State(initialValue: workspace?.autoReviewRepos.joined(separator: ", ") ?? "")
        self._customInstructionsText = State(initialValue: workspace?.customInstructions ?? "")
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

    /// Jira is offered only when acli is installed + authenticated, OR when the
    /// workspace already had Jira selected (so an existing choice isn't silently
    /// hidden — we surface a warning instead).
    private var jiraOfferable: Bool {
        jiraAvailability == .ready || jiraSelected
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
            }

            Section("Repos") {
                TextField("Always Include Repos", text: $alwaysIncludeText)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated repo specs: owner/* lists all of an org's repos, or owner/repo for a single repo. Populates the Jobs repo picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Auto-Review Repos", text: $autoReviewReposText)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated repos or patterns (e.g. org/repo, org/*). New review requests from matching repos will automatically create a review session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Instructions") {
                TextEditor(text: $customInstructionsText)
                    .font(.body)
                    .frame(minHeight: 80)
                Text("Instructions appended to the session prompt (e.g., \"Always run npm test before committing\").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            jiraAvailability = await AcliProbe.availability()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(existingID != nil ? "Save" : "Add") {
                    onSave(buildWorkspace())
                    dismiss()
                }
                .disabled(nameValidationError != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 640)
    }

    private func buildWorkspace() -> WorkspaceInfo {
        let alwaysInclude = parseCSV(alwaysIncludeText)
        let autoReviewRepos = parseCSV(autoReviewReposText)
        let trimmedInstructions = customInstructionsText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Persist taskProvider only when it diverges from the code provider;
        // otherwise leave nil so the workspace "follows" the code backend.
        let resolvedTaskProvider: String? = (taskProvider == provider) ? nil : taskProvider
        let isJira = taskProvider == "jira"

        return WorkspaceInfo(
            id: existingID ?? UUID(),
            name: trimmedName,
            provider: provider,
            cli: provider == "github" ? "gh" : "glab",
            host: provider == "gitlab" && !host.isEmpty ? host : nil,
            alwaysInclude: alwaysInclude,
            autoReviewRepos: autoReviewRepos,
            customInstructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
            taskProvider: resolvedTaskProvider,
            jiraProjectKey: isJira ? nonEmpty(jiraProjectKey) : nil,
            jiraJQL: isJira ? nonEmpty(jiraJQL) : nil,
            jiraSite: isJira ? nonEmpty(jiraSite) : nil
        )
    }

    private func parseCSV(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
