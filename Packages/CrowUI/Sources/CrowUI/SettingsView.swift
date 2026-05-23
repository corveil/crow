import SwiftUI
import CrowCore

/// Settings panel accessible via Cmd+,
///
/// Four-tab interface: General (devRoot, sidebar, telemetry, cleanup),
/// Automation (review/ticket filtering, remote control, Manager Terminal,
/// auto-respond), Workspaces (defaults + list), and Notifications (global +
/// per-event config). Every change is persisted immediately via the `onSave`
/// callback — there is no explicit "Apply" button.
public struct SettingsView: View {
    let appState: AppState
    @State var devRoot: String
    @State var config: AppConfig
    @State private var isAddingWorkspace = false
    @State private var editingWorkspace: WorkspaceInfo?
    @State private var isAddingJob = false
    @State private var editingJob: JobConfig?

    public var onSave: ((String, AppConfig) -> Void)?
    public var onRescaffold: ((String) -> Void)?

    public init(appState: AppState, devRoot: String, config: AppConfig,
                onSave: ((String, AppConfig) -> Void)? = nil,
                onRescaffold: ((String) -> Void)? = nil) {
        self.appState = appState
        self._devRoot = State(initialValue: devRoot)
        self._config = State(initialValue: config)
        self.onSave = onSave
        self.onRescaffold = onRescaffold
    }

    /// Names of all workspaces except the one currently being edited.
    private func otherWorkspaceNames(excluding id: UUID? = nil) -> [String] {
        config.workspaces
            .filter { $0.id != id }
            .map(\.name)
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            AutomationSettingsView(
                defaults: $config.defaults,
                remoteControlEnabled: $config.remoteControlEnabled,
                managerAutoPermissionMode: $config.managerAutoPermissionMode,
                autoRespond: $config.autoRespond,
                attributionTrailers: $config.attributionTrailers,
                autoMergeWatcherEnabled: $config.autoMergeWatcherEnabled,
                autoCreateWatcherEnabled: $config.autoCreateWatcherEnabled,
                autoRebaseWatcherEnabled: $config.autoRebaseWatcherEnabled,
                onSave: { save() }
            )
                .tabItem { Label("Automation", systemImage: "bolt.fill") }
            workspacesTab
                .tabItem { Label("Workspaces", systemImage: "rectangle.stack") }
            jobsTab
                .tabItem { Label("Jobs", systemImage: "clock.badge") }
            NotificationSettingsView(
                settings: $config.notifications,
                onSave: { save() }
            )
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 720, height: 480)
        .sheet(isPresented: $isAddingWorkspace) {
            WorkspaceFormView(
                existingNames: otherWorkspaceNames()
            ) { ws in
                config.workspaces.append(ws)
                save()
            }
        }
        .sheet(item: $editingWorkspace) { ws in
            WorkspaceFormView(
                workspace: ws,
                existingNames: otherWorkspaceNames(excluding: ws.id)
            ) { updated in
                if let idx = config.workspaces.firstIndex(where: { $0.id == updated.id }) {
                    config.workspaces[idx] = updated
                    save()
                }
            }
        }
        .sheet(isPresented: $isAddingJob) {
            JobFormView(
                workspaces: config.workspaces,
                existingNames: otherJobNames(),
                listRepos: { ws in await appState.onListWorkspaceRepos?(ws) ?? [] }
            ) { job in
                config.jobs.append(job)
                save()
            }
        }
        .sheet(item: $editingJob) { job in
            JobFormView(
                job: job,
                workspaces: config.workspaces,
                existingNames: otherJobNames(excluding: job.id),
                listRepos: { ws in await appState.onListWorkspaceRepos?(ws) ?? [] }
            ) { updated in
                if let idx = config.jobs.firstIndex(where: { $0.id == updated.id }) {
                    config.jobs[idx] = updated
                    save()
                }
            }
        }
    }

    /// Names of all jobs except the one currently being edited.
    private func otherJobNames(excluding id: UUID? = nil) -> [String] {
        config.jobs.filter { $0.id != id }.map(\.name)
    }

    // MARK: - General Tab

    @ViewBuilder
    private var githubScopeWarningBanner: some View {
        if let warning = appState.githubScopeWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warning)
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var rateLimitWarningBanner: some View {
        if let warning = appState.rateLimitWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.orange)
                Text(warning)
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(6)
        }
    }

    private var generalTab: some View {
        Form {
            if appState.githubScopeWarning != nil {
                Section { githubScopeWarningBanner }
            }
            if appState.rateLimitWarning != nil {
                Section { rateLimitWarningBanner }
            }
            Section("Development Root") {
                HStack {
                    TextField("Path", text: $devRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            devRoot = url.path
                            save()
                        }
                    }
                }

                Button("Re-scaffold .claude/ directory") {
                    onRescaffold?(devRoot)
                }
                .font(.caption)
            }

            Section("Sidebar") {
                Toggle("Hide session details", isOn: $config.sidebar.hideSessionDetails)
                    .onChange(of: config.sidebar.hideSessionDetails) { _, _ in save() }
                Text("Hides ticket title and repo/branch lines in sidebar rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Telemetry") {
                Toggle("Enable session analytics", isOn: $config.telemetry.enabled)
                    .onChange(of: config.telemetry.enabled) { _, _ in save() }
                Text("Collects cost, token, and tool usage metrics from Claude Code sessions via OpenTelemetry. Requires app restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("OTLP receiver port")
                    TextField("Port", value: $config.telemetry.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { save() }
                }
                .disabled(!config.telemetry.enabled)

                Picker("Retention", selection: $config.telemetry.retentionDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }
                .onChange(of: config.telemetry.retentionDays) { _, _ in save() }
                .disabled(!config.telemetry.enabled)
            }

            Section("Session Cleanup") {
                Toggle("Auto-delete completed sessions", isOn: $config.cleanup.enabled)
                    .onChange(of: config.cleanup.enabled) { _, _ in save() }
                Text("Automatically deletes completed and archived sessions after the retention period. Includes worktree and branch cleanup. Manager and virtual tab sessions are never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Retention", selection: $config.cleanup.retentionHours) {
                    Text("1 hour").tag(1)
                    Text("1 day").tag(24)
                    Text("3 days").tag(72)
                    Text("7 days").tag(168)
                    Text("30 days").tag(720)
                }
                .onChange(of: config.cleanup.retentionHours) { _, _ in save() }
                .disabled(!config.cleanup.enabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Workspaces Tab

    private var workspacesTab: some View {
        Form {
            Section("Defaults") {
                Picker("Default Provider", selection: $config.defaults.provider) {
                    Text("GitHub").tag("github")
                    Text("GitLab").tag("gitlab")
                }
                .onChange(of: config.defaults.provider) { _, _ in save() }

                TextField("Branch Prefix", text: $config.defaults.branchPrefix)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }

                if !ConfigDefaults.isValidBranchPrefix(config.defaults.branchPrefix) {
                    Text("Contains characters invalid in git branch names.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Applied when creating new workspaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if config.workspaces.isEmpty {
                    Text("No workspaces configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(config.workspaces) { ws in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ws.name)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    Text(ws.provider)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(ws.provider == "github" ? Color.purple.opacity(0.15) : Color.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                    if let host = ws.host {
                                        Text(host)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            Button {
                                editingWorkspace = ws
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(ws.name)")

                            Button(role: .destructive) {
                                config.workspaces.removeAll { $0.id == ws.id }
                                save()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(ws.name)")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Workspaces")
                    Spacer()
                    Button {
                        isAddingWorkspace = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Jobs Tab

    private var jobsTab: some View {
        Form {
            Section {
                if config.jobs.isEmpty {
                    Text("No jobs configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($config.jobs) { $job in
                        HStack(alignment: .top) {
                            Toggle("", isOn: $job.enabled)
                                .labelsHidden()
                                .onChange(of: job.enabled) { _, _ in save() }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name).fontWeight(.medium)
                                Text("\(jobScope(job)) · \(scheduleSummary(job.schedule))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(lastRunText(job)) · \(nextRunText(job))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                editingJob = job
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(job.name)")

                            Button(role: .destructive) {
                                config.jobs.removeAll { $0.id == job.id }
                                save()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(job.name)")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Jobs")
                    Spacer()
                    Button {
                        isAddingJob = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(config.workspaces.isEmpty)
                }
            } footer: {
                if config.workspaces.isEmpty {
                    Text("Add a workspace first — jobs are scoped to a repo in a workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scheduled prompt sets. When a job fires, Crow creates a worktree + session in the scoped repo and runs its prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "workspace/repo" for a job, or just the repo when no workspace is stored
    /// (jobs persisted before the workspace field returned).
    private func jobScope(_ job: JobConfig) -> String {
        job.workspace.isEmpty ? job.repo : "\(job.workspace)/\(job.repo)"
    }

    /// Human-readable summary of a job's schedule (e.g. "every 4 hours", "Mon,Wed at 09:00").
    private func scheduleSummary(_ schedule: JobSchedule) -> String {
        switch schedule {
        case .interval(let seconds):
            let value: Int
            let unit: String
            if seconds > 0, seconds % 86400 == 0 { value = seconds / 86400; unit = "day" }
            else if seconds > 0, seconds % 3600 == 0 { value = seconds / 3600; unit = "hour" }
            else { value = max(1, seconds / 60); unit = "minute" }
            return "every \(value) \(unit)\(value == 1 ? "" : "s")"
        case .dailyAt(let hour, let minute, let weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            guard !weekdays.isEmpty else { return "daily at \(time)" }
            let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
            let days = weekdays
                .sorted { (($0 + 5) % 7) < (($1 + 5) % 7) } // Monday-first ordering
                .compactMap { names[$0] }
                .joined(separator: ",")
            return "\(days) at \(time)"
        }
    }

    private func lastRunText(_ job: JobConfig) -> String {
        guard let last = job.lastRunAt else { return "Last run: never" }
        return "Last run: \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    private func nextRunText(_ job: JobConfig) -> String {
        guard job.enabled else { return "disabled" }
        let baseline = job.lastRunAt ?? job.createdAt
        guard let next = job.nextRunDate(after: baseline) else { return "Next: —" }
        return "Next: \(next.formatted(date: .abbreviated, time: .shortened))"
    }

    private func save() {
        onSave?(devRoot, config)
    }
}
