import SwiftUI
import CrowCore
import CrowTerminal

/// View for global terminals that exist outside of any session.
public struct GlobalTerminalView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    private var globalTerminals: [SessionTerminal] {
        appState.terminals(for: AppState.globalTerminalSessionID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SectionHelpBanner(
                description: "Standalone terminals that live outside of any session. Useful for long-lived processes, monitoring, or ad-hoc shell access.",
                storageKey: "helpDismissed_terminals"
            )
            Divider().overlay(CorveilTheme.borderSubtle)
            terminalArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Terminals")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
    }

    // MARK: - Terminal Area

    @ViewBuilder
    private var terminalArea: some View {
        if globalTerminals.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                TerminalTabBar(
                    terminals: globalTerminals,
                    activeID: appState.activeTerminalID[AppState.globalTerminalSessionID] ?? globalTerminals[0].id,
                    onSelect: { id in
                        appState.activeTerminalID[AppState.globalTerminalSessionID] = id
                    },
                    onClose: { id in
                        appState.onCloseGlobalTerminal?(id)
                    },
                    onRename: { id, name in
                        appState.onRenameTerminal?(AppState.globalTerminalSessionID, id, name)
                    },
                    onAdd: {
                        appState.onAddGlobalTerminal?()
                    }
                )
                Divider().overlay(CorveilTheme.borderSubtle)
                let activeID = appState.activeTerminalID[AppState.globalTerminalSessionID] ?? globalTerminals[0].id
                if let terminal = globalTerminals.first(where: { $0.id == activeID }) {
                    TerminalSurfaceView(
                        terminalID: terminal.id,
                        workingDirectory: terminal.cwd,
                        command: terminal.command
                    )
                    .id(terminal.id)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(CorveilTheme.textMuted)
            Text("No terminals open")
                .font(.headline)
                .foregroundStyle(CorveilTheme.textSecondary)
            Text("Create a terminal to get started.")
                .font(.subheadline)
                .foregroundStyle(CorveilTheme.textMuted)
            Button {
                appState.onAddGlobalTerminal?()
            } label: {
                Label("New Terminal", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(CorveilTheme.gold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CorveilTheme.bgDeep)
    }
}
