import CrowCore
import CrowIPC
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub compare call backing the version-update check (CROW-938).
///
/// Compares the stamped build SHA against `corveil/crow` `main` via
/// `GET /repos/corveil/crow/compare/{local}...main`, then fetches the branch
/// head separately so `remote_sha` stays correct when `behind_by` exceeds the
/// compare payload's 250-commit cap.
public enum VersionUpdateClient {
    public static let repository = "corveil/crow"
    public static let defaultBranch = "main"

    public enum CheckError: Error, Equatable {
        case indeterminateLocalSha
        case http(Int)
        case transport(String)
        case decode
        case rateLimited
    }

    /// Compare `build` against upstream `main`. Never throws for expected
    /// indeterminate cases — those return `.unknown` with a reason.
    public static func check(
        build: BuildInfo,
        updateCommand: String = "git -C <clone> pull && make install",
        authToken: String? = nil,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async -> VersionUpdateStatus {
        let base = VersionUpdateStatus(
            state: .unknown,
            localVersion: build.version,
            localSha: build.gitSha,
            buildDate: build.buildDate,
            checkedAtMs: currentTimeMs()
        )
        guard !build.isIndeterminate else {
            return VersionUpdateStatus(
                state: .unknown,
                localVersion: build.version,
                localSha: build.gitSha,
                buildDate: build.buildDate,
                reason: "Local build SHA is not a known git commit",
                checkedAtMs: base.checkedAtMs
            )
        }

        let localSha = build.compareSha
        guard let encodedSha = localSha.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let compareURL = URL(string:
                "https://api.github.com/repos/\(repository)/compare/\(encodedSha)...\(defaultBranch)"
              ) else {
            return unknown(base, reason: "Invalid compare URL")
        }

        let compareRequest = authorizedRequest(url: compareURL, build: build, authToken: authToken)

        let data: Data
        do {
            let (payload, response) = try await transport(compareRequest)
            guard let http = response as? HTTPURLResponse else {
                return unknown(base, reason: "No HTTP response from GitHub")
            }
            if http.statusCode == 403,
               let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
               remaining == "0" {
                return unknown(base, reason: "GitHub rate limit exceeded")
            }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 404 {
                    return unknown(base, reason: "Local SHA is not on GitHub")
                }
                return unknown(base, reason: "GitHub compare failed (HTTP \(http.statusCode))")
            }
            data = payload
        } catch {
            return unknown(base, reason: "Could not reach GitHub")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return unknown(base, reason: "Unexpected GitHub response")
        }

        let behindBy = json["behind_by"] as? Int ?? 0
        let aheadBy = json["ahead_by"] as? Int ?? 0
        let status = json["status"] as? String ?? ""

        // For `compare/{local}...{main}`, GitHub's `ahead_by` is how many commits
        // on `main` the local build lacks (i.e. how far behind we are); `behind_by`
        // is commits the local build has that `main` lacks (feature branch / fork).
        let remoteCommit: RemoteCommit?
        if status == "identical" {
            // `main`'s head is the local SHA — skip the second API call.
            remoteCommit = RemoteCommit(sha: build.gitSha, date: build.buildDate)
        } else {
            remoteCommit = await fetchBranchHead(
                build: build, authToken: authToken, transport: transport)
        }
        let remoteSha = remoteCommit?.sha
        let remoteDate = remoteCommit?.date

        if behindBy > 0 || status == "behind" || status == "diverged" {
            return VersionUpdateStatus(
                state: .unknown,
                localVersion: build.version,
                localSha: build.gitSha,
                buildDate: build.buildDate,
                remoteSha: remoteSha,
                remoteDate: remoteDate,
                behindBy: behindBy,
                aheadBy: aheadBy,
                reason: "Local build is not on upstream main",
                checkedAtMs: base.checkedAtMs
            )
        }

        if aheadBy > 0 || status == "ahead" {
            return VersionUpdateStatus(
                state: .behind,
                localVersion: build.version,
                localSha: build.gitSha,
                buildDate: build.buildDate,
                remoteSha: remoteSha,
                remoteDate: remoteDate,
                behindBy: aheadBy,
                aheadBy: behindBy,
                updateCommand: updateCommand,
                checkedAtMs: base.checkedAtMs
            )
        }

        return VersionUpdateStatus(
            state: .upToDate,
            localVersion: build.version,
            localSha: build.gitSha,
            buildDate: build.buildDate,
            remoteSha: remoteSha,
            remoteDate: remoteDate,
            behindBy: 0,
            aheadBy: 0,
            checkedAtMs: base.checkedAtMs
        )
    }

    private static func authorizedRequest(
        url: URL, build: BuildInfo, authToken: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Crow/\(build.version)", forHTTPHeaderField: "User-Agent")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func unknown(_ base: VersionUpdateStatus, reason: String) -> VersionUpdateStatus {
        VersionUpdateStatus(
            state: .unknown,
            localVersion: base.localVersion,
            localSha: base.localSha,
            buildDate: base.buildDate,
            reason: reason,
            checkedAtMs: base.checkedAtMs
        )
    }

    private static func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private struct RemoteCommit {
        var sha: String
        var date: String?
    }

    /// Fetch `main`'s tip — not inferred from the compare payload, which caps at
    /// 250 commits and would give the wrong sha/date (and banner-dismiss key)
    /// when further behind.
    private static func fetchBranchHead(
        build: BuildInfo,
        authToken: String?,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> RemoteCommit? {
        guard let url = URL(string:
            "https://api.github.com/repos/\(repository)/commits/\(defaultBranch)"
        ) else { return nil }
        let request = authorizedRequest(url: url, build: build, authToken: authToken)
        guard let (data, response) = try? await transport(request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseCommitNode(json)
    }

    private static func parseCommitNode(_ node: [String: Any]) -> RemoteCommit? {
        guard let sha = node["sha"] as? String, !sha.isEmpty else { return nil }
        let commit = node["commit"] as? [String: Any]
        let committer = commit?["committer"] as? [String: Any]
        let author = commit?["author"] as? [String: Any]
        let rawDate = (committer?["date"] as? String) ?? (author?["date"] as? String)
        let date = rawDate.map(shortDate)
        return RemoteCommit(sha: String(sha.prefix(7)), date: date)
    }

    /// `2026-08-05T12:34:56Z` → `2026-08-05`.
    static func shortDate(_ iso: String) -> String {
        if let tIndex = iso.firstIndex(of: "T") {
            return String(iso[..<tIndex])
        }
        return iso
    }
}

/// Wire encoding for `version-update-*` RPCs (CROW-938).
public enum VersionUpdateRPC {
    public static func configJSON(_ config: VersionUpdateConfig) -> JSONValue {
        .object([
            "enabled": .bool(config.enabled),
            "interval_hours": .int(config.intervalHours),
        ])
    }

    public static func statusJSON(_ status: VersionUpdateStatus?) -> JSONValue {
        guard let status else { return .null }
        return .object([
            "state": .string(status.state.rawValue),
            "local_version": .string(status.localVersion),
            "local_sha": .string(status.localSha),
            "build_date": .string(status.buildDate),
            "remote_sha": status.remoteSha.map { .string($0) } ?? .null,
            "remote_date": status.remoteDate.map { .string($0) } ?? .null,
            "behind_by": status.behindBy.map { .int($0) } ?? .null,
            "ahead_by": status.aheadBy.map { .int($0) } ?? .null,
            "update_command": status.updateCommand.map { .string($0) } ?? .null,
            "reason": status.reason.map { .string($0) } ?? .null,
            "checked_at_ms": status.checkedAtMs.map { .int(Int($0)) } ?? .null,
        ])
    }

    public static func patchIntervalHours(
        _ params: [String: JSONValue], _ key: String = "interval_hours"
    ) throws -> Int? {
        guard let value = params[key], value != .null else { return nil }
        guard let hours = value.intValue else {
            throw RPCError.invalidParams("\(key) must be an integer")
        }
        guard hours >= VersionUpdateConfig.minimumIntervalHours else {
            throw RPCError.invalidParams(
                "\(key) must be at least \(VersionUpdateConfig.minimumIntervalHours) hours")
        }
        return hours
    }
}
