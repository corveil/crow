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
                onSave: { save() }
            )
                .tabItem { Label("Automation", systemImage: "bolt.fill") }
            workspacesTab
                .tabItem { Label("Workspaces", systemImage: "rectangle.stack") }
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

    private func save() {
        onSave?(devRoot, config)
    }
}
