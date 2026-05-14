import AppKit
import CrowUI
import SwiftUI

struct AboutView: View {
    @State private var copied = false
    @State private var revealedCrashLogs = false

    var body: some View {
        VStack(spacing: 12) {
            // Corveil brandmark
            if let image = loadBrandmark() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140)
            }

            Text("Crow")
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundStyle(CorveilTheme.gold)

            Text("Version \(appVersion)")
                .font(.callout)
                .foregroundStyle(CorveilTheme.textSecondary)

            // Git SHA — click to copy full hash
            Button(action: copyGitSHA) {
                HStack(spacing: 4) {
                    Text(BuildInfo.gitCommitShortSHA)
                        .font(.system(.callout, design: .monospaced))
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .foregroundStyle(copied ? .green : CorveilTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Click to copy full commit SHA: \(BuildInfo.gitCommitSHA)")

            Text("Built \(BuildInfo.buildDate)")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textMuted)

            // Gold accent divider
            CorveilTheme.borderSubtle
                .frame(height: 1)
                .padding(.horizontal, 24)
                .padding(.vertical, 4)

            // Diagnostics: where signal-level crashes and stderr are logged.
            Button(action: revealCrashLogs) {
                HStack(spacing: 4) {
                    Text("Crash logs")
                        .font(.caption)
                    Image(systemName: revealedCrashLogs ? "checkmark" : "folder")
                        .font(.caption)
                }
                .foregroundStyle(revealedCrashLogs ? .green : CorveilTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help(CrashReporter.logDirectory.path)

            Text("© \(Calendar.current.component(.year, from: Date())) Radius Method")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textMuted)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 320)
        .background(CorveilTheme.bgDeep)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BuildInfo.version
    }

    private func loadBrandmark() -> NSImage? {
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "CorveilBrandmark", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private func copyGitSHA() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BuildInfo.gitCommitSHA, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func revealCrashLogs() {
        let dir = CrashReporter.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        revealedCrashLogs = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            revealedCrashLogs = false
        }
    }
}
