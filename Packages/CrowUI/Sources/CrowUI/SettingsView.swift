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
    /// A pre-filled copy of a job, presented in the form (create mode) to duplicate it.
    @State private var duplicatingJob: JobConfig?
    /// Live result of the most recent corveil "Verify" run. `nil` until the
    /// user has clicked Verify at least once this Settings session. Starts
    /// with `✓` on success, `✗` on failure (CROW-482).
    @State private var corveilVerifyResult: String?
    /// True while the Verify button's subprocess is in flight.
    @State private var corveilVerifying: Bool = false
    /// Live result of the most recent "Reinstall skill" click. Shares the
    /// `✓ … / ✗ …` convention with `corveilVerifyResult` and is rendered in
    /// the same inline result line (only one operation runs at a time). Set
    /// to `nil` on path edits so stale results don't outlive a binary swap.
    @State private var corveilReinstallResult: String?
    /// True while the Reinstall skill button's subprocess is in flight.
    @State private var corveilReinstalling: Bool = false

    public var onSave: ((String, AppConfig) -> Void)?
    public var onRescaffold: ((String) -> Void)?
    /// Fired when the user commits a new value into the corveil picker
    /// (Browse confirm or Enter on the TextField), so AppDelegate can
    /// re-run just `Scaffolder.installCorveilSkill` instead of waiting for
    /// the next app restart (CROW-490). `nil` argument means "the user
    /// cleared the field" — the install is a no-op then but the caller
    /// still gets the signal to clear any stale warning banner.
    public var onCorveilReinstall: ((String?) -> Void)?

    public init(appState: AppState, devRoot: String, config: AppConfig,
                onSave: ((String, AppConfig) -> Void)? = nil,
                onRescaffold: ((String) -> Void)? = nil,
                onCorveilReinstall: ((String?) -> Void)? = nil) {
        self.appState = appState
        self._devRoot = State(initialValue: devRoot)
        self._config = State(initialValue: config)
        self.onSave = onSave
        self.onRescaffold = onRescaffold
        self.onCorveilReinstall = onCorveilReinstall
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
                managerGateway: $config.managerGateway,
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
        .sheet(item: $duplicatingJob) { job in
            JobFormView(
                job: job,
                isDuplicate: true,
                workspaces: config.workspaces,
                existingNames: otherJobNames(),
                listRepos: { ws in await appState.onListWorkspaceRepos?(ws) ?? [] }
            ) { newJob in
                config.jobs.append(newJob)
                save()
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
    private var githubSAMLWarningBanner: some View {
        if let warning = appState.githubSAMLWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
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

    @ViewBuilder
    private var corveilSkillWarningBanner: some View {
        if let warning = appState.corveilSkillInstallWarning {
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

    private var generalTab: some View {
        Form {
            if appState.githubScopeWarning != nil {
                Section { githubScopeWarningBanner }
            }
            if appState.githubSAMLWarning != nil {
                Section { githubSAMLWarningBanner }
            }
            if appState.rateLimitWarning != nil {
                Section { rateLimitWarningBanner }
            }
            if appState.corveilSkillInstallWarning != nil {
                Section { corveilSkillWarningBanner }
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

            Section("Defaults") {
                Picker("Default Agent", selection: $config.defaultAgentKind) {
                    ForEach(AgentRegistry.shared.allAgents(), id: \.kind) { agent in
                        Label(agent.displayName, systemImage: agent.iconSystemName)
                            .tag(agent.kind)
                    }
                }
                .onChange(of: config.defaultAgentKind) { _, _ in save() }
                .disabled(AgentRegistry.shared.allAgents().count < 2)
                Text("Selected agent runs new sessions. Disabled until a second agent (e.g., Codex) is registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                perActionAgentPicker(label: "Agent for coding", kind: .work)
                perActionAgentPicker(label: "Agent for reviews", kind: .review)
                perActionAgentPicker(label: "Agent for scheduled jobs", kind: .job)
                perActionAgentPicker(label: "Agent for Manager", kind: .manager)
                Text("Per-action overrides. “Use default” falls back to the Default Agent above. Manager changes take effect on next Manager respawn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Corveil CLI") {
                HStack {
                    TextField("Path to corveil binary", text: corveilBinding)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitCorveilPath() }
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            corveilBinding.wrappedValue = url.path
                            // Clear stale results — they're about a previous binary.
                            corveilVerifyResult = nil
                            corveilReinstallResult = nil
                            commitCorveilPath()
                        }
                    }
                    Button(corveilVerifying ? "Verifying…" : "Verify") { verifyCorveil() }
                        .disabled(corveilBinding.wrappedValue.isEmpty || corveilVerifying || corveilReinstalling)
                    Button(corveilReinstalling ? "Reinstalling…" : "Reinstall skill") {
                        reinstallCorveilSkill()
                    }
                    .disabled(corveilBinding.wrappedValue.isEmpty || corveilVerifying || corveilReinstalling)
                    .help(corveilBinding.wrappedValue.isEmpty
                          ? "Set the Corveil CLI path first."
                          : "Reinstall the bundled /query-corveil skill from this binary — picks up a rebuilt corveil without restarting Crow.")
                }
                // Single result line — coalesces Verify and Reinstall output.
                // Only one operation runs at a time (mutual `disabled`), and
                // newer clicks clear the older result first, so there's no
                // ambiguity about which click this line refers to.
                if let result = corveilReinstallResult ?? corveilVerifyResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
                        .textSelection(.enabled)
                }
                Text("On launch, Crow runs `corveil skill install --path` to install the `/query-corveil` slash command into this devRoot. Use **Reinstall skill** after rebuilding corveil to pick up the new embedded skill without restarting Crow. Leave blank to skip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("4 hours").tag(4)
                    Text("8 hours").tag(8)
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
                                        .background(Self.providerBadgeColor(ws.provider))
                                        .clipShape(Capsule())
                                    // Second badge for the task backend, shown only
                                    // when it diverges from the code backend.
                                    if ws.derivedTaskProvider != ws.provider {
                                        Text(ws.derivedTaskProvider)
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Self.providerBadgeColor(ws.derivedTaskProvider))
                                            .clipShape(Capsule())
                                    }
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
            Section("Auto-permission mode") {
                Toggle("Run scheduled jobs in auto permission mode", isOn: $config.jobsAutoPermissionMode)
                    .onChange(of: config.jobsAutoPermissionMode) { _, _ in save() }
                Text("Passes --permission-mode auto so scheduled jobs can run crow, gh, and git commands without per-call approval. Requires Claude Code 2.1.83+ on a Max, Team, Enterprise, or API plan with the Anthropic provider. Turn off if your account reports auto mode as unavailable. Takes effect on the next job run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                                appState.onRunJob?(job.id)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Run \(job.name) now")

                            Button {
                                editingJob = job
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(job.name)")

                            Button {
                                duplicatingJob = job.duplicated(existingNames: config.jobs.map(\.name))
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Duplicate \(job.name)")

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

    /// How a job's repo is shown. `repo` is already an `owner/repo` slug, so we
    /// show it as-is (avoiding a redundant "workspace/owner/repo"); the
    /// workspace is prefixed only for legacy bare-name jobs that lack an owner.
    private func jobScope(_ job: JobConfig) -> String {
        if job.repo.contains("/") { return job.repo }
        return job.workspace.isEmpty ? job.repo : "\(job.workspace)/\(job.repo)"
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

    /// Commit a corveil picker change: persist the config and hot-trigger
    /// the `/query-corveil` install for the new path (CROW-490). Both
    /// commit sites (Browse confirm and TextField `onSubmit`) funnel
    /// through here so the "persist → reinstall" pair stays atomic and
    /// the `nil`-on-empty rule has a single source of truth. We read the
    /// path through `corveilBinding.wrappedValue` rather than the raw
    /// input so the binding's whitespace-trim normalization wins — the
    /// install closure sees the same string that the next launch's
    /// scaffolder would see.
    private func commitCorveilPath() {
        save()
        let path = corveilBinding.wrappedValue
        onCorveilReinstall?(path.isEmpty ? nil : path)
    }

    /// Two-way binding into `config.defaults.binaries["corveil"]` that treats
    /// an empty string as "unset" (so the map doesn't accumulate stale empty
    /// entries when the user clears the field). Trimming happens on commit so
    /// pasted paths with stray whitespace are normalized.
    private var corveilBinding: Binding<String> {
        Binding(
            get: { config.defaults.binaries["corveil"] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    config.defaults.binaries.removeValue(forKey: "corveil")
                } else {
                    config.defaults.binaries["corveil"] = trimmed
                }
            }
        )
    }

    /// Run `<corveilPath> --version` and surface the result. Lives off the
    /// main actor so the spinning UI doesn't block. Truncates noisy output
    /// to keep the inline result line readable.
    private func verifyCorveil() {
        let path = corveilBinding.wrappedValue
        guard !path.isEmpty else { return }
        corveilVerifying = true
        corveilVerifyResult = nil
        // Clear the older reinstall result so the coalesced result line
        // doesn't shadow this verify with stale output.
        corveilReinstallResult = nil
        Task.detached {
            let result = SettingsView.runCorveilVersion(at: path)
            await MainActor.run {
                corveilVerifyResult = result
                corveilVerifying = false
            }
        }
    }

    /// Re-run `corveil skill install --path …` on demand — the same flow as
    /// the per-launch path (CROW-482), without requiring a restart, a
    /// workspace switch, or re-picking the binary (CROW-491). The common
    /// loop this serves is "I rebuilt corveil locally; install the new
    /// embedded skill." Goes through `AppState.onReinstallCorveilSkill`
    /// because SettingsView (CrowUI) can't import the app target where
    /// `Scaffolder` lives. The closure is async and offloads its blocking
    /// work to a detached task internally, so awaiting it from the main
    /// actor doesn't pin the UI for the install timeout.
    private func reinstallCorveilSkill() {
        let path = corveilBinding.wrappedValue
        guard !path.isEmpty else { return }
        corveilReinstalling = true
        corveilReinstallResult = nil
        // Clear the older verify result so the coalesced result line
        // doesn't shadow this reinstall with stale output.
        corveilVerifyResult = nil
        Task {
            // Closure may not be wired in unit tests / previews — degrade
            // gracefully. Mirrors the `onListWorkspaceRepos` invocation
            // pattern used elsewhere in this view.
            let warning = await appState.onReinstallCorveilSkill?(path)
            if let warning {
                corveilReinstallResult = "✗ \(warning)"
                // Mirror the launch-time surface so the orange banner at
                // the top of General also reflects the latest attempt —
                // keeps a single source of truth for "is corveil broken?"
                appState.corveilSkillInstallWarning = warning
            } else {
                corveilReinstallResult = "✓ Skill reinstalled"
                // A successful manual reinstall clears any stale
                // launch-time warning — if the user has just made it
                // work, they shouldn't keep staring at the old banner.
                appState.corveilSkillInstallWarning = nil
            }
            corveilReinstalling = false
        }
    }

    /// Pure helper for `verifyCorveil` — easier to reason about off the main
    /// actor and trivially testable. Returns a single-line summary suitable
    /// for inline display.
    ///
    /// Uses `proc.waitUntilExit()` (with a `TimeoutWatchdog` SIGTERM'ing the
    /// child if it hangs) rather than a polling loop on `proc.isRunning`.
    /// `waitUntilExit` is the only way to deterministically trigger
    /// Foundation's pipe-write-FD cleanup; a polling loop leaves Foundation's
    /// internal copy of the writeFD open and the post-exit reads either hang
    /// (with a background drain) or return empty (Foundation closes its copy
    /// on its own internal schedule). Once `waitUntilExit` returns, both
    /// pipe writers (child + Foundation) have closed, so a synchronous
    /// `readToEnd()` on each pipe returns immediately with the data.
    nonisolated static func runCorveilVersion(at path: String) -> String {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else {
            return "✗ Not executable: \(path)"
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return "✗ Could not launch: \(error.localizedDescription)"
        }

        // Watchdog: SIGTERM after `verifyTimeout` so a hung binary unblocks
        // `waitUntilExit` below. The watchdog also records the timeout so we
        // can distinguish a normal exit-N from a wall-clock kill.
        let watchdog = TimeoutWatchdog(deadline: verifyTimeout, proc: proc)
        watchdog.start()
        proc.waitUntilExit()
        let timedOut = watchdog.cancel()

        let outStr = Self.readAll(outPipe)
        let errStr = Self.readAll(errPipe)
        let combined = [outStr, errStr].filter { !$0.isEmpty }.joined(separator: " — ")
        let snippet = combined.split(separator: "\n").first.map(String.init) ?? combined

        if timedOut {
            return "✗ Timed out after \(Int(verifyTimeout))s — binary may be hung."
        }
        if proc.terminationStatus == 0 {
            return snippet.isEmpty ? "✓ Verified" : "✓ \(snippet)"
        }
        let detail = snippet.isEmpty ? "exit code \(proc.terminationStatus)" : snippet
        return "✗ \(detail)"
    }

    /// Synchronously read all bytes from a pipe's read end after the child
    /// has exited (so `readToEnd()` returns immediately). Trims whitespace
    /// and returns a UTF-8 string.
    nonisolated static func readAll(_ pipe: Pipe) -> String {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Wall-clock budget for the "Verify" subprocess. Matches the install
    /// path's `Scaffolder.corveilInstallTimeout` — a corveil that hangs on
    /// `--version` is bounded to the same 5s window as one that hangs on
    /// `skill install`. The Task wrapper runs off the main actor so the UI
    /// stays responsive while this wait elapses.
    nonisolated static let verifyTimeout: TimeInterval = 5.0

    /// One per-action agent picker (Coding/Reviews/Jobs). "Use default"
    /// removes the override; selecting a concrete agent writes the
    /// `config.agentsByKind` entry. Disabled until a second agent is
    /// registered, matching the Default Agent picker (CROW-421).
    @ViewBuilder
    private func perActionAgentPicker(label: String, kind: SessionKind) -> some View {
        let key = kind.rawValue
        let binding = Binding<AgentKind?>(
            get: { config.agentsByKind[key] },
            set: { newValue in
                if let newValue {
                    config.agentsByKind[key] = newValue
                } else {
                    config.agentsByKind.removeValue(forKey: key)
                }
                save()
            }
        )
        Picker(label, selection: binding) {
            Text("Use default").tag(AgentKind?.none)
            ForEach(AgentRegistry.shared.allAgents(), id: \.kind) { agent in
                Label(agent.displayName, systemImage: agent.iconSystemName)
                    .tag(Optional(agent.kind))
            }
        }
        .disabled(AgentRegistry.shared.allAgents().count < 2)
    }

    /// Tint for a provider badge (code or task backend).
    static func providerBadgeColor(_ provider: String) -> Color {
        switch provider {
        case "github": return Color.purple.opacity(0.15)
        case "jira": return Color.blue.opacity(0.15)
        default: return Color.orange.opacity(0.15)  // gitlab / other
        }
    }
}

/// SIGTERM a `Process` after `deadline` seconds if it's still running. Used
/// to bound `waitUntilExit` without a polling loop (a polling loop on
/// `proc.isRunning` defeats Foundation's pipe-write-FD cleanup, which only
/// runs as part of `waitUntilExit`). `cancel()` stops the timer and reports
/// whether it had already fired.
///
/// `@unchecked Sendable` is sound here: every member is either immutable
/// (`proc`, `timer`) or guarded by `lock` (`didFire`). `proc.terminate()`
/// and `proc.isRunning` are thread-safe per Foundation.
fileprivate final class TimeoutWatchdog: @unchecked Sendable {
    private let proc: Process
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var didFire = false

    init(deadline: TimeInterval, proc: Process) {
        self.proc = proc
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        self.timer.schedule(deadline: .now() + deadline)
    }

    func start() {
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.didFire = true
            self.lock.unlock()
            if self.proc.isRunning {
                self.proc.terminate()
            }
        }
        timer.resume()
    }

    /// Cancel the watchdog. Returns true if it had already fired (timeout).
    func cancel() -> Bool {
        timer.cancel()
        lock.lock(); defer { lock.unlock() }
        return didFire
    }
}
