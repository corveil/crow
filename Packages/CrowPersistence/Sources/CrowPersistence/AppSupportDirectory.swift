import CrowCore
import Foundation

/// Provides the canonical Application Support directory for Crow, performing
/// a one-time migration from the legacy "rm-ai-ide" directory if needed.
enum AppSupportDirectory {
    /// `~/Library/Application Support/crow/`, created on first access.
    /// If the directory doesn't exist but a legacy `rm-ai-ide` directory does,
    /// the legacy directory is copied over automatically.
    static let url: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let crowDir = appSupport.appendingPathComponent("crow", isDirectory: true)
        // One-time migration from the pre-rename "rm-ai-ide" directory
        let oldDir = appSupport.appendingPathComponent("rm-ai-ide", isDirectory: true)
        if !FileManager.default.fileExists(atPath: crowDir.path),
           FileManager.default.fileExists(atPath: oldDir.path) {
            do {
                try FileManager.default.copyItem(at: oldDir, to: crowDir)
                CrowLog.info("[AppSupportDirectory] Migrated data from rm-ai-ide to crow")
            } catch {
                CrowLog.info("[AppSupportDirectory] Failed to migrate rm-ai-ide data: \(error.localizedDescription)")
            }
        }
        return crowDir
    }()
}
