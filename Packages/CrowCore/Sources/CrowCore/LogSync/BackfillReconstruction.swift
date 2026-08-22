import Foundation

/// How confident the reconstruction is that a historical on-disk transcript can
/// be attached to a real workspace / repo / ticket (CROW-1075).
///
/// The tiers drive the Settings dialog's default selection and the honesty of
/// the eventual upload: only a `high` session asserts a validated ticket
/// REFERENCE, a `medium` one uploads repo-only, and a `low` one uploads as an
/// attributed-but-unlinked Conversation (or is left unselected).
public enum BackfillConfidence: String, Sendable, Equatable, Codable, CaseIterable {
    /// Workspace + repo recovered **and** a ticket number parsed from the
    /// worktree name. Whether that ticket actually *validates* against the
    /// provider is decided at upload time (`TicketValidator`); the tier only
    /// says the metadata is fully shaped.
    case high
    /// A repo was recovered (worktree under a workspace, or a git remote) but no
    /// ticket number — uploads repo-only.
    case medium
    /// Neither a workspace nor a repo could be matched — a true orphan
    /// (`~/Downloads/…`, an ad-hoc `claude` run, a path outside the dev root).
    /// Uploads only if explicitly selected, as an attributed Conversation with
    /// no fabricated links.
    case low
}

/// What a parsed ticket turned out to be once validated against the provider.
public enum BackfillTicketKind: String, Sendable, Equatable, Codable {
    case issue
    case pullRequest = "pull_request"
    /// A number was parsed but not yet validated (the scan does not hit the
    /// provider — validation happens at upload).
    case unvalidated
    /// Validated and the provider reported it does not exist — no REFERENCE is
    /// asserted for it.
    case notFound = "not_found"
}

/// The upload status of a historical session, reconciled from the local ledger
/// (`logsync-ledger.json`) during a scan.
public enum BackfillUploadStatus: String, Sendable, Equatable, Codable {
    /// No ledger entry — never attempted.
    case new
    /// Stored (201) or already present (409) — an idempotent success.
    case uploaded
    /// Rejected in a way retrying can't fix (too large / auth / validation).
    case skipped
    /// A transient failure was recorded; a retry is allowed.
    case failed
}

/// A repo's identity, parsed from a git remote URL. `owner/repo` is what the
/// provider CLIs (`gh`, `glab`) address, so it is what ticket validation and the
/// upload sidecar need.
public struct RepoRemote: Sendable, Equatable {
    /// e.g. `github.com`, `gitlab.example.com`, `repo1.dso.mil`.
    public let host: String
    /// The owner / org / (GitLab) group path, e.g. `corveil` or
    /// `big-bang/product/packages`.
    public let owner: String
    /// The repo (project) name, e.g. `crow`.
    public let repo: String

    public init(host: String, owner: String, repo: String) {
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    /// `owner/repo` — the slug `gh -R …` and the sidecar `repo` hint use.
    public var slug: String { "\(owner)/\(repo)" }

    /// Whether the host is (public or enterprise) GitHub, which decides whether
    /// `gh` or `glab` validates it.
    public var isGitHub: Bool { host == "github.com" || host.hasPrefix("github.") }

    /// Parse a git remote URL (`git remote get-url origin`) into its parts.
    /// Handles the two forms git prints:
    /// - `https://github.com/owner/repo.git`
    /// - `git@github.com:owner/repo.git`
    /// GitLab subgroups (`host/group/sub/repo`) are preserved: `owner` keeps the
    /// full group path and `repo` is the last segment. Returns `nil` for a URL
    /// that isn't a recognizable `host + path` (e.g. a bare local path).
    public static func parse(_ raw: String) -> RepoRemote? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        var host = ""
        var path = ""
        if let range = s.range(of: "://") {
            // scheme://[user@]host/path
            var rest = String(s[range.upperBound...])
            if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
        } else if let at = s.firstIndex(of: "@"), let colon = s.firstIndex(of: ":"), at < colon {
            // scp-like: user@host:path
            host = String(s[s.index(after: at)..<colon])
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }

        // Strip a port (`host:22`) that a scp-like URL never has but an https one
        // might carry after the host in odd configs.
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        let segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard segments.count >= 2, !host.isEmpty else { return nil }
        let repo = segments.last!
        let owner = segments.dropLast().joined(separator: "/")
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return RepoRemote(host: host, owner: owner, repo: repo)
    }
}

/// One historical coding session reconstructed from an on-disk transcript
/// (CROW-1075). This is the row the Settings "Backfill history" table renders and
/// the unit the uploader acts on. Everything but the identity fields is
/// best-effort — a `low`-confidence orphan carries only the file facts.
public struct BackfillSession: Sendable, Equatable, Codable {
    /// The harness that wrote this transcript (CROW-1089). Determines the ledger
    /// key's harness slot and the upload's `harness` value, so a Claude and a
    /// Codex session with the same UID never collide. Defaults to `.claude` for
    /// back-compat with rows persisted before the field existed.
    public var harness: LogSyncHarness
    /// The harness session UID — the transcript's identity. For Claude it is the
    /// `.jsonl` stem; for Codex it is the rollout's `session_meta.payload.id`.
    /// Used verbatim as the upload `{uid}`: stable, unique, and the natural
    /// idempotency key (decision #1). Named `claudeSessionUID` for historical
    /// reasons — it is any harness's session UID now.
    public var claudeSessionUID: String
    /// Absolute path to the transcript file.
    public var filePath: String
    /// The Claude project-slug directory name the file lives under.
    public var slug: String
    /// Working directory recorded in the transcript (authoritative — not the
    /// lossy slug). `nil` only for a transcript that recorded none.
    public var cwd: String?
    /// Git branch recorded in the transcript, a secondary metadata source.
    public var gitBranch: String?
    /// Newest file modification, epoch seconds — the session's "date".
    public var modifiedAt: Double
    /// Transcript size in bytes.
    public var sizeBytes: Int

    /// Reconstructed workspace (first path component of `cwd` under the dev
    /// root). `nil` ⇒ the session ran outside any workspace (orphan).
    public var workspace: String?
    /// The worktree directory name (`<repo>-<number>-<slug>`), when `cwd` is a
    /// worktree under a workspace.
    public var worktreeName: String?
    /// Bare repo name parsed from the worktree/branch, before owner resolution.
    public var repoName: String?
    /// `owner/repo`, resolved from a live git remote when one is reachable.
    public var ownerRepo: String?
    /// The repo host (`github.com`, …) when resolved, so validation picks the
    /// right provider CLI.
    public var host: String?
    /// Ticket / PR number parsed from the worktree name (corroborated by the
    /// branch). Whether it validates is decided at upload.
    public var ticketNumber: Int?
    /// What the ticket turned out to be, once validated (`unvalidated` until
    /// then).
    public var ticketKind: BackfillTicketKind
    /// Whether the worktree directory still exists on disk (a stronger signal
    /// and the only case a `git remote` read is possible for this exact path).
    public var worktreeExists: Bool

    public var confidence: BackfillConfidence
    /// Reconciled from the ledger at scan time.
    public var uploadStatus: BackfillUploadStatus

    public init(
        claudeSessionUID: String,
        filePath: String,
        slug: String,
        harness: LogSyncHarness = .claude,
        cwd: String? = nil,
        gitBranch: String? = nil,
        modifiedAt: Double = 0,
        sizeBytes: Int = 0,
        workspace: String? = nil,
        worktreeName: String? = nil,
        repoName: String? = nil,
        ownerRepo: String? = nil,
        host: String? = nil,
        ticketNumber: Int? = nil,
        ticketKind: BackfillTicketKind = .unvalidated,
        worktreeExists: Bool = false,
        confidence: BackfillConfidence = .low,
        uploadStatus: BackfillUploadStatus = .new
    ) {
        self.claudeSessionUID = claudeSessionUID
        self.filePath = filePath
        self.slug = slug
        self.harness = harness
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.workspace = workspace
        self.worktreeName = worktreeName
        self.repoName = repoName
        self.ownerRepo = ownerRepo
        self.host = host
        self.ticketNumber = ticketNumber
        self.ticketKind = ticketKind
        self.worktreeExists = worktreeExists
        self.confidence = confidence
        self.uploadStatus = uploadStatus
    }
}

/// The result of attempting to back-fill one session (CROW-1075) — returned per
/// session so the Settings dialog and the CLI can show a truthful per-row
/// outcome (uploaded / linked / skipped-already / failed + reason).
public struct BackfillUploadOutcome: Sendable, Equatable, Codable {
    public var claudeSessionUID: String
    /// The harness this outcome is for — so a UI keying results back to scan rows
    /// distinguishes a Claude and a Codex session that share a UID (CROW-1089).
    public var harness: LogSyncHarness
    /// Terminal disposition of the attempt.
    public enum Result: String, Sendable, Equatable, Codable {
        case uploaded          // 201 stored
        case alreadyUploaded   // ledger says done, or server 409 — idempotent
        case skipped           // nothing to upload / no gateway / empty file
        case failed            // transient or permanent failure
    }
    public var result: Result
    /// Whether a **validated** ticket REFERENCE was included in the sidecar. A
    /// repo-only or orphan upload is `false` — no fabricated link.
    public var linked: Bool
    public var ownerRepo: String?
    public var ticketNumber: Int?
    public var ticketKind: BackfillTicketKind?
    /// Human-readable reason for a skip/failure (e.g. `no gateway for workspace`,
    /// `too_large`, `transient`).
    public var reason: String?

    public init(
        claudeSessionUID: String,
        result: Result,
        harness: LogSyncHarness = .claude,
        linked: Bool = false,
        ownerRepo: String? = nil,
        ticketNumber: Int? = nil,
        ticketKind: BackfillTicketKind? = nil,
        reason: String? = nil
    ) {
        self.claudeSessionUID = claudeSessionUID
        self.result = result
        self.harness = harness
        self.linked = linked
        self.ownerRepo = ownerRepo
        self.ticketNumber = ticketNumber
        self.ticketKind = ticketKind
        self.reason = reason
    }
}

/// Pure metadata reconstruction for a historical session (CROW-1075). Every
/// function here is a total, side-effect-free transform of strings the scanner
/// has already read (the transcript's `cwd`/`gitBranch`, the workspace list, and
/// a `repoName → RepoRemote` map built from live git remotes), so the whole of
/// the "fill in the gaps" logic is unit-testable without touching disk or the
/// network.
public enum BackfillReconstructor {
    /// The workspace folder name for a `cwd`: `{devRoot}/{workspace}/…` →
    /// `{workspace}`. Mirrors `SessionService.workspaceName` (which lives in
    /// CrowEngine and can't be imported here) — pure path math, so it is copied
    /// rather than shared, and pinned by a test asserting the two agree.
    public static func workspace(cwd: String, devRoot: String) -> String? {
        let root = (devRoot as NSString).standardizingPath
        let full = (cwd as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { return nil }
        let relative = String(full.dropFirst(root.count + 1))
        return relative.split(separator: "/").first.map(String.init)
    }

    /// The worktree directory name — the second path component under the dev
    /// root (`{devRoot}/{workspace}/{worktree}/…` → `{worktree}`). `nil` when the
    /// cwd is the workspace root itself or lies outside the dev root.
    public static func worktreeName(cwd: String, devRoot: String) -> String? {
        let root = (devRoot as NSString).standardizingPath
        let full = (cwd as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { return nil }
        let parts = String(full.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
        return parts.count >= 2 ? parts[1] : nil
    }

    /// Parse a Crow-convention worktree directory name into `(repo, ticket)`.
    ///
    /// The name is `<repo>-<number>-<slug>`, but both `<repo>` and `<slug>` can
    /// contain dashes and digits, so the split is ambiguous from the string
    /// alone (`corveil-cloud-terraform-331-…` vs `alloy-86-502-…`). The
    /// disambiguator is `knownRepoNames` — the repo names of live clones found
    /// under the dev root: the **longest** one that prefixes the worktree name
    /// wins, and the digits right after it are the ticket. Only when no known
    /// repo matches does it fall back to the greedy generic split (lower
    /// confidence). A review clone (`<repo>-pr-<n>`) is recognized too.
    public static func parseWorktree(
        _ name: String, knownRepoNames: [String]
    ) -> (repo: String?, ticket: Int?) {
        // Review clones live at `{devRoot}/crow-reviews/{repo}-pr-{N}`.
        if let r = name.range(of: "-pr-") {
            let repo = String(name[..<r.lowerBound])
            let tail = String(name[r.upperBound...])
            let digits = tail.prefix { $0.isNumber }
            if !repo.isEmpty, let n = Int(digits) { return (repo, n) }
        }

        // Longest known repo that the worktree name starts with.
        let candidates = knownRepoNames
            .filter { name == $0 || name.hasPrefix($0 + "-") }
            .sorted { $0.count > $1.count }
        if let repo = candidates.first {
            if name == repo { return (repo, nil) }
            let tail = name.dropFirst(repo.count + 1) // drop "repo-"
            let digits = tail.prefix { $0.isNumber }
            return (repo, Int(digits))
        }

        // Generic fallback: first non-numeric run, then the first number.
        // `^(.+?)-(\d+)(?:-.*)?$`
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        for i in 1..<max(parts.count, 1) where i < parts.count {
            if let n = Int(parts[i]), !parts[i].isEmpty {
                let repo = parts[0..<i].joined(separator: "-")
                return (repo.isEmpty ? nil : repo, n)
            }
        }
        return (name.isEmpty ? nil : name, nil)
    }

    /// A plausible ticket number from a git branch (`feature/crow-1075-slug` →
    /// 1075), used to corroborate (or, when the worktree name has none, supply)
    /// the number. Takes the first number that is flanked by a dash on the left
    /// — a bare leading number in a branch is unusual and skipped.
    public static func ticketNumber(fromBranch branch: String) -> Int? {
        let scalars = Array(branch)
        var i = 0
        while i < scalars.count {
            if scalars[i].isNumber, i > 0, scalars[i - 1] == "-" {
                var j = i
                while j < scalars.count, scalars[j].isNumber { j += 1 }
                // Require a trailing dash so a slug like `-v2` doesn't read as
                // the ticket, matching the `<num>-<slug>` convention.
                if j < scalars.count, scalars[j] == "-" {
                    return Int(String(scalars[i..<j]))
                }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    /// The confidence tier for a reconstructed session, before provider
    /// validation. `high` needs a repo **and** a ticket number; `medium` a repo
    /// alone; `low` is an orphan with neither a workspace nor a repo.
    public static func confidence(
        workspace: String?, repoName: String?, ticket: Int?
    ) -> BackfillConfidence {
        if repoName != nil, ticket != nil { return .high }
        if repoName != nil || workspace != nil { return .medium }
        return .low
    }

    /// Build a public issue/PR URL for the sidecar `ticket_url` hint, once the
    /// kind is known. `nil` when the pieces aren't all present.
    public static func ticketURL(
        remote: RepoRemote?, number: Int?, kind: BackfillTicketKind
    ) -> String? {
        guard let remote, let number else { return nil }
        let segment: String
        switch kind {
        case .pullRequest: segment = remote.isGitHub ? "pull" : "merge_requests"
        case .issue: segment = "issues"
        case .unvalidated, .notFound: return nil
        }
        return "https://\(remote.host)/\(remote.owner)/\(remote.repo)/\(segment)/\(number)"
    }
}
