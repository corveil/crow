import Foundation

/// Null-tolerant accessors for `JSONSerialization`-decoded JSON payloads.
///
/// **Why this type exists. Do NOT "simplify" these back to `as? [[String: Any]]`.**
///
/// GitHub's GraphQL connections declare *nullable elements* (`nodes: [Node]`),
/// and GitHub uses that: when a single element can't be resolved — most often
/// an org PR/issue behind SAML enforcement the OAuth token hasn't been granted
/// access to — the server nullifies **that element** and returns every sibling
/// normally, reporting the hole in `errors` with a path like
/// `["viewerPRs","pullRequests","nodes",3]`.
///
/// `JSONSerialization` decodes those holes as `NSNull`. Swift's conditional
/// array downcast is element-wise and all-or-nothing: **one** `NSNull` makes
/// the whole cast return nil, so `guard let nodes = … as? [[String: Any]]
/// else { return [] }` silently discards every accessible sibling.
///
/// That is #894. A user with one open PR in a SAML-restricted org lost CI
/// status — failing glyphs, the Fix Checks button, auto-respond-to-failed-checks
/// — for *all* of their PRs, because `parseViewerPRs` returned `[]` for a
/// response that carried 8 perfectly good PRs alongside 7 nulls.
///
/// These helpers filter rather than fail: unresolvable elements are dropped,
/// resolvable ones survive. Same partial-recovery philosophy as
/// `GitHubTaskBackend.recoverPartialIssues` and
/// `GitHubCodeBackend.recoverPartialMonitoredPRs`, applied one level down —
/// those two recover a partial *response*, this recovers a partial *array*.
///
/// Note: single-object casts (`node["repository"] as? [String: Any]`) do **not**
/// need this treatment. A null value there correctly yields nil for that field
/// alone. Only *arrays of objects* are affected.
enum LenientJSON {

    /// Object elements of `value`, dropping `null`s and non-object entries.
    /// Returns `[]` when `value` is nil, `null`, or not an array.
    ///
    /// Use for plain (non-connection) arrays — e.g. a Projects v2
    /// `ProjectV2SingleSelectField.options` list.
    static func objects(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    /// Object elements of `connection["nodes"]`, for a GraphQL connection
    /// object already in hand — e.g. a `search(…)` result: `searchObj`.
    static func nodes(_ connection: [String: Any]?) -> [[String: Any]] {
        objects(connection?["nodes"])
    }

    /// Object elements of `container[key]["nodes"]` — the nested-connection
    /// shape that dominates these queries (`node["labels"]["nodes"]`,
    /// `rollup["contexts"]["nodes"]`, `viewer["pullRequests"]["nodes"]`).
    /// Tolerates a null/missing `container`, `key`, and `nodes` at every hop.
    static func nodes(_ container: [String: Any]?, _ key: String) -> [[String: Any]] {
        nodes(container?[key] as? [String: Any])
    }
}
