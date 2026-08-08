import Foundation

/// Settings for the periodic upstream version check (CROW-938).
public struct VersionUpdateConfig: Codable, Sendable, Equatable {
    /// When false, `crowd` does not phone GitHub on a schedule. Defaults to
    /// true — the check is on unless the user opts out.
    public var enabled: Bool
    /// Minimum hours between automatic checks. Floored at 1 — hourly checks are
    /// ~48 GitHub API calls/day, well within unauthenticated limits (60 req/hr/IP).
    public var intervalHours: Int

    public static let minimumIntervalHours = 1

    public init(enabled: Bool = true, intervalHours: Int = 1) {
        self.enabled = enabled
        self.intervalHours = max(Self.minimumIntervalHours, intervalHours)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let raw = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? Self.minimumIntervalHours
        intervalHours = max(Self.minimumIntervalHours, raw)
    }

    enum CodingKeys: String, CodingKey { case enabled, intervalHours }
}

/// Build metadata stamped by `scripts/generate-build-info.sh` into
/// `version.json` and served at `/version.json`.
public struct BuildInfo: Codable, Sendable, Equatable {
    public var version: String
    /// Short SHA for display (`git rev-parse --short`).
    public var gitSha: String
    /// Full SHA for GitHub compare; falls back to `gitSha` when absent.
    public var gitShaFull: String?
    public var buildDate: String

    public init(version: String, gitSha: String, gitShaFull: String? = nil, buildDate: String) {
        self.version = version
        self.gitSha = gitSha
        self.gitShaFull = gitShaFull
        self.buildDate = buildDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "?"
        gitSha = try c.decodeIfPresent(String.self, forKey: .gitSha) ?? "dev"
        gitShaFull = try c.decodeIfPresent(String.self, forKey: .gitShaFull)
        buildDate = try c.decodeIfPresent(String.self, forKey: .buildDate) ?? ""
    }

    /// SHA sent to GitHub's compare API — full when stamped, else short.
    public var compareSha: String { gitShaFull ?? gitSha }

    /// Whether this build's SHA is too ambiguous for an upstream comparison.
    public var isIndeterminate: Bool {
        let sha = compareSha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sha.isEmpty || sha == "dev"
    }

    enum CodingKeys: String, CodingKey { case version, gitSha, gitShaFull, buildDate }
}

/// Cached result of comparing the local build against `origin/main`.
public struct VersionUpdateStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case upToDate = "up_to_date"
        case behind
        case unknown
    }

    public var state: State
    public var localVersion: String
    public var localSha: String
    public var buildDate: String
    public var remoteSha: String?
    public var remoteDate: String?
    public var behindBy: Int?
    public var aheadBy: Int?
    public var updateCommand: String?
    /// Human-readable reason when `state == .unknown`.
    public var reason: String?
    /// Epoch milliseconds when this result was produced.
    public var checkedAtMs: Int64?

    public init(
        state: State,
        localVersion: String,
        localSha: String,
        buildDate: String,
        remoteSha: String? = nil,
        remoteDate: String? = nil,
        behindBy: Int? = nil,
        aheadBy: Int? = nil,
        updateCommand: String? = nil,
        reason: String? = nil,
        checkedAtMs: Int64? = nil
    ) {
        self.state = state
        self.localVersion = localVersion
        self.localSha = localSha
        self.buildDate = buildDate
        self.remoteSha = remoteSha
        self.remoteDate = remoteDate
        self.behindBy = behindBy
        self.aheadBy = aheadBy
        self.updateCommand = updateCommand
        self.reason = reason
        self.checkedAtMs = checkedAtMs
    }
}
