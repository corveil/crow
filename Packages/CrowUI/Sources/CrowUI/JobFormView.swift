import SwiftUI
import CrowCore

/// Form for creating or editing a scheduled job (CROW-317).
///
/// Mirrors `WorkspaceFormView`: holds field state, validates, and constructs a
/// `JobConfig` on save. A job is scoped to a repo within a workspace; the repo
/// list is loaded from the workspace's provider. The job carries one or more
/// prompts and fires on an interval or daily at a time.
public struct JobFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var workspace: String
    @State private var repo: String
    @State private var prompts: [String]
    @State private var scheduleMode: ScheduleMode
    @State private var intervalValue: Int
    @State private var intervalUnit: IntervalUnit
    @State private var dailyTime: Date
    @State private var weekdays: Set<Int>
    @State private var enabled: Bool

    /// Repo slugs for the selected workspace, loaded via `listRepos`.
    @State private var repoOptions: [String] = []
    @State private var isLoadingRepos = false
    @State private var didLoadRepos = false

    private let workspaces: [WorkspaceInfo]
    private let listRepos: (WorkspaceInfo) async -> [String]
    private let existingID: UUID?
    private let existingLastRunAt: Date?
    private let existingCreatedAt: Date
    private let existingNames: [String]
    private let onSave: (JobConfig) -> Void

    enum ScheduleMode: Hashable { case interval, daily }

    enum IntervalUnit: String, CaseIterable, Identifiable {
        case minutes, hours, days
        var id: String { rawValue }
        var seconds: Int {
            switch self {
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86400
            }
        }
        var label: String { rawValue.capitalized }
    }

    /// Weekday options in display order, mapped to `Calendar`'s ints (Sun = 1 … Sat = 7).
    private static let weekdayOptions: [(label: String, value: Int)] = [
        ("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5), ("Fri", 6), ("Sat", 7), ("Sun", 1),
    ]

    /// - Parameters:
    ///   - job: An existing job to edit, or `nil` to create a new one.
    ///   - workspaces: Workspaces to choose from; their providers source the repo list.
    ///   - existingNames: Names of other jobs, used for duplicate detection.
    ///   - listRepos: Loads the `owner/repo` slugs available to a workspace.
    ///   - onSave: Called with the validated `JobConfig` when the user taps Save/Add.
    public init(
        job: JobConfig? = nil,
        workspaces: [WorkspaceInfo] = [],
        existingNames: [String] = [],
        listRepos: @escaping (WorkspaceInfo) async -> [String] = { _ in [] },
        onSave: @escaping (JobConfig) -> Void
    ) {
        self.workspaces = workspaces
        self.listRepos = listRepos
        self.existingID = job?.id
        self.existingLastRunAt = job?.lastRunAt
        self.existingCreatedAt = job?.createdAt ?? Date()
        self.existingNames = existingNames
        self.onSave = onSave

        self._name = State(initialValue: job?.name ?? "")
        // Default to the job's workspace, else the first available workspace.
        self._workspace = State(initialValue: job?.workspace ?? workspaces.first?.name ?? "")
        self._repo = State(initialValue: job?.repo ?? "")
        self._prompts = State(initialValue: job?.prompts.isEmpty == false ? job!.prompts : [""])
        self._enabled = State(initialValue: job?.enabled ?? true)

        // Decompose the schedule into editable fields.
        switch job?.schedule {
        case .interval(let seconds):
            let (value, unit) = Self.decomposeInterval(seconds)
            self._scheduleMode = State(initialValue: .interval)
            self._intervalValue = State(initialValue: value)
            self._intervalUnit = State(initialValue: unit)
            self._dailyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            self._weekdays = State(initialValue: [])
        case .dailyAt(let hour, let minute, let days):
            self._scheduleMode = State(initialValue: .daily)
            self._intervalValue = State(initialValue: 1)
            self._intervalUnit = State(initialValue: .hours)
            self._dailyTime = State(initialValue: Self.time(hour: hour, minute: minute))
            self._weekdays = State(initialValue: days)
        case nil:
            self._scheduleMode = State(initialValue: .interval)
            self._intervalValue = State(initialValue: 1)
            self._intervalUnit = State(initialValue: .hours)
            self._dailyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            self._weekdays = State(initialValue: [])
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nonEmptyPrompts: [String] {
        prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var nameValidationError: String? {
        JobConfig.validateName(trimmedName, existingNames: existingNames)
    }

    /// The currently selected workspace, if any.
    private var selectedWorkspace: WorkspaceInfo? {
        workspaces.first { $0.name == workspace }
    }

    /// Repo options shown in the picker. Includes the current `repo` (when
    /// editing) even if it isn't in the loaded list, so the saved value survives.
    private var repoChoices: [String] {
        var choices = repoOptions
        if !repo.isEmpty, !choices.contains(repo) { choices.insert(repo, at: 0) }
        return choices
    }

    private var isValid: Bool {
        nameValidationError == nil
            && !workspace.isEmpty
            && !repo.trimmingCharacters(in: .whitespaces).isEmpty
            && !nonEmptyPrompts.isEmpty
            && (scheduleMode == .daily || intervalValue >= 1)
    }

    /// Load the selected workspace's repo list, replacing any prior options.
    private func loadRepos() async {
        guard let ws = selectedWorkspace else {
            repoOptions = []
            return
        }
        isLoadingRepos = true
        defer { isLoadingRepos = false; didLoadRepos = true }
        repoOptions = await listRepos(ws)
    }

    public var body: some View {
        Form {
            Section("Job") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                if let error = nameValidationError, !trimmedName.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Picker("Workspace", selection: $workspace) {
                    ForEach(workspaces) { ws in Text(ws.name).tag(ws.name) }
                }
                .onChange(of: workspace) { _, _ in
                    // Reset repo when it no longer belongs to the chosen workspace.
                    repo = ""
                    Task { await loadRepos() }
                }

                HStack {
                    Picker("Repo", selection: $repo) {
                        Text("Select…").tag("")
                        ForEach(repoChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(isLoadingRepos)
                    if isLoadingRepos {
                        ProgressView().controlSize(.small)
                    }
                }
                if didLoadRepos, !isLoadingRepos, repoOptions.isEmpty {
                    Text("No repos found for this workspace. Set its “Always Include Repos” to e.g. \(workspace.isEmpty ? "owner" : workspace.lowercased())/* in Workspaces settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Toggle("Enabled", isOn: $enabled)
            }

            Section {
                ForEach(prompts.indices, id: \.self) { idx in
                    HStack(alignment: .top) {
                        TextField("Prompt \(idx + 1)", text: $prompts[idx], axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...6)
                        Button(role: .destructive) {
                            prompts.remove(at: idx)
                            if prompts.isEmpty { prompts = [""] }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(prompts.count == 1)
                        .accessibilityLabel("Remove prompt \(idx + 1)")
                    }
                }
            } header: {
                HStack {
                    Text("Prompts")
                    Spacer()
                    Button {
                        prompts.append("")
                    } label: {
                        Label("Add", systemImage: "plus").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text("Sent in order. The first launches Claude Code; the rest follow after it starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Schedule") {
                Picker("Run", selection: $scheduleMode) {
                    Text("Every").tag(ScheduleMode.interval)
                    Text("Daily at").tag(ScheduleMode.daily)
                }
                .pickerStyle(.segmented)

                if scheduleMode == .interval {
                    HStack {
                        TextField("Every", value: $intervalValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Picker("", selection: $intervalUnit) {
                            ForEach(IntervalUnit.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if intervalValue < 1 {
                        Text("Interval must be at least 1.").font(.caption).foregroundStyle(.red)
                    }
                } else {
                    DatePicker("Time", selection: $dailyTime, displayedComponents: .hourAndMinute)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(Self.weekdayOptions, id: \.value) { option in
                                let on = weekdays.contains(option.value)
                                Button(option.label) {
                                    if on { weekdays.remove(option.value) }
                                    else { weekdays.insert(option.value) }
                                }
                                .buttonStyle(.bordered)
                                .tint(on ? .accentColor : .secondary)
                            }
                        }
                        Text("No day selected = every day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(existingID != nil ? "Save" : "Add") {
                    onSave(buildJob())
                    dismiss()
                }
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 600)
        .task { await loadRepos() }
    }

    private func buildJob() -> JobConfig {
        let schedule: JobSchedule
        switch scheduleMode {
        case .interval:
            schedule = .interval(seconds: max(1, intervalValue) * intervalUnit.seconds)
        case .daily:
            let comps = Calendar.current.dateComponents([.hour, .minute], from: dailyTime)
            schedule = .dailyAt(hour: comps.hour ?? 9, minute: comps.minute ?? 0, weekdays: weekdays)
        }
        return JobConfig(
            id: existingID ?? UUID(),
            name: trimmedName,
            workspace: workspace,
            repo: repo.trimmingCharacters(in: .whitespaces),
            prompts: nonEmptyPrompts,
            schedule: schedule,
            enabled: enabled,
            lastRunAt: existingLastRunAt,
            createdAt: existingCreatedAt
        )
    }

    // MARK: - Helpers

    private static func decomposeInterval(_ seconds: Int) -> (Int, IntervalUnit) {
        if seconds > 0, seconds % 86400 == 0 { return (seconds / 86400, .days) }
        if seconds > 0, seconds % 3600 == 0 { return (seconds / 3600, .hours) }
        return (max(1, seconds / 60), .minutes)
    }

    private static func time(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            from: DateComponents(hour: hour, minute: minute)
        ) ?? Date()
    }
}
