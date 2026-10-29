import Foundation

/// Filtering, ordering, and paging over one backfill scan (CROW-1378).
///
/// A whole scan can exceed the 1 MB socket reply cap on a dev root with a lot
/// of history, so `backfill-scan` answers with a summary by default and pages
/// the rows on request. Everything here is pure — the daemon owns the snapshot
/// that makes pages stable; this owns which rows a page holds.

/// The upload-status filter. `notUploaded` is everything a bulk upload would
/// still act on (`new`, `skipped`, `failed`).
public enum BackfillStatusFilter: String, Sendable, Equatable, CaseIterable {
    case new
    case uploaded
    case skipped
    case failed
    case notUploaded = "not_uploaded"

    func matches(_ status: BackfillUploadStatus) -> Bool {
        switch self {
        case .new: status == .new
        case .uploaded: status == .uploaded
        case .skipped: status == .skipped
        case .failed: status == .failed
        case .notUploaded: status != .uploaded
        }
    }
}

/// Row filter for a scan. Every field is optional; `nil` matches anything.
public struct BackfillScanFilter: Sendable, Equatable {
    /// Workspace name, matched case-insensitively (like `backfill-upload`).
    public var workspace: String?
    public var confidence: BackfillConfidence?
    public var status: BackfillStatusFilter?
    public var harness: LogSyncHarness?

    public init(
        workspace: String? = nil,
        confidence: BackfillConfidence? = nil,
        status: BackfillStatusFilter? = nil,
        harness: LogSyncHarness? = nil
    ) {
        self.workspace = workspace
        self.confidence = confidence
        self.status = status
        self.harness = harness
    }

    public var isEmpty: Bool { self == BackfillScanFilter() }

    public func matches(_ s: BackfillSession) -> Bool {
        if let workspace, s.workspace?.lowercased() != workspace.lowercased() { return false }
        if let confidence, s.confidence != confidence { return false }
        if let status, !status.matches(s.uploadStatus) { return false }
        if let harness, s.harness != harness { return false }
        return true
    }
}

/// Counts over a set of rows, broken down along each filterable dimension —
/// what `crow backfill scan` prints by default instead of the rows themselves.
public struct BackfillScanBreakdown: Sendable, Equatable {
    /// Key for rows with no reconstructed workspace (orphans).
    public static let noWorkspace = "(none)"

    public var total: Int
    public var byHarness: [String: Int]
    public var byWorkspace: [String: Int]
    public var byConfidence: [String: Int]
    public var byUploadStatus: [String: Int]

    public init(sessions: [BackfillSession]) {
        total = sessions.count
        var harness: [String: Int] = [:]
        var workspace: [String: Int] = [:]
        var confidence: [String: Int] = [:]
        var status: [String: Int] = [:]
        for s in sessions {
            harness[s.harness.rawValue, default: 0] += 1
            workspace[s.workspace ?? Self.noWorkspace, default: 0] += 1
            confidence[s.confidence.rawValue, default: 0] += 1
            status[s.uploadStatus.rawValue, default: 0] += 1
        }
        byHarness = harness
        byWorkspace = workspace
        byConfidence = confidence
        byUploadStatus = status
    }
}

/// One page of rows, plus where the next one starts.
public struct BackfillScanPage<Row> {
    public var rows: [Row]
    /// Offset of the first row of the next page; `nil` when this page ends the set.
    public var nextOffset: Int?
    /// True when the byte budget, not `limit`, ended the page early.
    public var truncatedByBytes: Bool
}

public enum BackfillScanQuery {
    /// Deterministic order — newest first, then harness, then UID — so a page
    /// boundary means the same thing on every call over one snapshot.
    public static func ordered(_ sessions: [BackfillSession]) -> [BackfillSession] {
        sessions.sorted { a, b in
            if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
            if a.harness != b.harness { return a.harness.rawValue < b.harness.rawValue }
            return a.claudeSessionUID < b.claudeSessionUID
        }
    }

    /// Slice `rows[offset...]` into a page of at most `limit` rows whose
    /// encoded sizes total at most `maxBytes`. `size` returns one row's encoded
    /// byte count. A page always carries at least one row when any remain, so
    /// paging makes progress even if a single row is over budget.
    public static func page<Row>(
        _ rows: [Row],
        offset: Int,
        limit: Int,
        maxBytes: Int,
        size: (Row) -> Int
    ) -> BackfillScanPage<Row> {
        let start = min(max(0, offset), rows.count)
        let limit = max(1, limit)
        var out: [Row] = []
        var bytes = 0
        var index = start
        var truncated = false
        while index < rows.count, out.count < limit {
            let rowBytes = size(rows[index]) + 1  // + the separating comma
            if !out.isEmpty, bytes + rowBytes > maxBytes {
                truncated = true
                break
            }
            out.append(rows[index])
            bytes += rowBytes
            index += 1
        }
        return BackfillScanPage(
            rows: out, nextOffset: index < rows.count ? index : nil, truncatedByBytes: truncated)
    }
}
