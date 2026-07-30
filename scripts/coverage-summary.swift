#!/usr/bin/env swift
// Merge the per-package llvm-cov exports SwiftPM writes under
// Packages/<Pkg>/.build/<triple>/debug/codecov/<Pkg>.json into one repo-wide
// summary (CROW-928). Driven by scripts/coverage-summary.sh — see that file for
// the why; this one is the arithmetic.
//
// Written in Swift rather than Python/jq on purpose: the PR lane runs inside the
// `swift:6.1` container, which ships neither a `python3` interpreter nor `jq`
// (its Python is `libpython3-dev` — headers and stdlib for LLDB, no binary).
// Swift is the one language guaranteed present in *both* CI lanes and on any
// machine that can run `make coverage`, so leaning on it keeps the ticket's "no
// new dependencies" constraint honest.
//
// Two things this has to get right, both of which quietly produce garbage if
// skipped:
//
//   1. A test binary compiles its dependencies, so a package's raw export
//      describes far more than that package. CrowGit's own JSON reports ~3,700
//      lines at 6% — that is CrowCore and friends dragged in by the link, not
//      CrowGit. Every file is therefore attributed to the package that *owns*
//      its source (Packages/<Pkg>/Sources/…), and everything else in an export
//      is dropped from that package's row.
//
//   2. The same source file appears in several exports with different numbers:
//      covered where some suite exercised it, cold where another package merely
//      linked it. Summing would double-count and averaging would punish a file
//      for binaries that never called it, so files are folded across exports by
//      taking the *maximum* covered.
//
// Hence two numbers per file, and they answer different questions:
//
//   - own suite  — what <Pkg>'s own tests reach. The actionable one: it names
//                  the suite to go improve, and it is what the per-package table
//                  reports.
//   - any suite  — the max across every binary that linked the file. A CrowCore
//                  line exercised by CrowEngine's tests is exercised, whatever
//                  CrowGit's binary saw. The repo total is this, which is why it
//                  is better than the sum of the table's own-suite columns.
//
// Output is deterministic and free of timestamps, hostnames, and absolute
// paths: the same commit measured over the same package set produces identical
// bytes locally and in CI. The JSON is emitted by hand rather than through
// JSONSerialization for the same reason — Darwin escapes `/` as `\/` and
// swift-corelibs-foundation does not, which would make the two lanes disagree
// byte-for-byte over nothing.
//
// usage: swift scripts/coverage-summary.swift <repo-root> <out-dir> <export.json>…

import Foundation

// MARK: - llvm-cov export shape (the handful of fields we read)

struct Export: Decodable {
    let data: [Block]
}

struct Block: Decodable {
    let files: [FileEntry]
}

struct FileEntry: Decodable {
    let filename: String
    let summary: FileSummary
}

struct FileSummary: Decodable {
    let lines: Counter
    let regions: Counter
}

struct Counter: Decodable {
    let count: Int
    let covered: Int
}

// MARK: - Tallies

struct Metric {
    var count = 0
    var covered = 0

    var missed: Int { max(0, count - covered) }
    var percent: Double { count == 0 ? 0 : Double(covered) * 100 / Double(count) }

    static func += (lhs: inout Metric, rhs: Metric) {
        lhs.count += rhs.count
        lhs.covered += rhs.covered
    }

    /// Fold in another binary's view of the same file. Counts should already
    /// agree (same source, same compiler); `max` keeps a truncated export from
    /// shrinking the denominator.
    mutating func absorb(_ other: Metric) {
        count = max(count, other.count)
        covered = max(covered, other.covered)
    }
}

struct Coverage {
    var lines = Metric()
    var regions = Metric()

    static func += (lhs: inout Coverage, rhs: Coverage) {
        lhs.lines += rhs.lines
        lhs.regions += rhs.regions
    }

    mutating func absorb(_ other: Coverage) {
        lines.absorb(other.lines)
        regions.absorb(other.regions)
    }
}

struct FileCoverage {
    var ownSuite = Coverage()
    var anySuite = Coverage()
}

struct PackageCoverage {
    var name: String
    /// False when this package's own export was not among the inputs — it was
    /// seen only because something else linked its sources. Distinguishes "no
    /// suite ran here" from "the suite covers nothing", which otherwise look
    /// identical and turn the PR artifact into a false alarm.
    var ownSuiteMeasured = false
    var ownSuite = Coverage()
    var anySuite = Coverage()
    var files: [(path: String, coverage: FileCoverage)] = []
}

// MARK: - Formatting helpers (locale-independent, so output stays byte-stable)

func fixed(_ value: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", value)
}

/// 40502 → "40,502". Foundation's number formatters are locale-sensitive and
/// differ across platforms; this does not.
func grouped(_ value: Int) -> String {
    let digits = Array(String(abs(value)))
    var out: [Character] = []
    for (offset, digit) in digits.enumerated() {
        if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    return (value < 0 ? "-" : "") + String(out)
}

func jsonString(_ raw: String) -> String {
    var out = "\""
    for scalar in raw.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("coverage-summary: \(message)\n".utf8))
    exit(1)
}

// MARK: - Arguments

let argv = CommandLine.arguments
guard argv.count >= 4 else {
    die("usage: swift scripts/coverage-summary.swift <repo-root> <out-dir> <export.json>…")
}

let repoRoot = argv[1].hasSuffix("/") ? String(argv[1].dropLast()) : argv[1]
let outDir = argv[2]
let reports = Array(argv.dropFirst(3))

/// llvm-cov records absolute source paths. Re-root them so the report is
/// portable — and so a file seen through two different exports collapses to one
/// key. The `/Packages/` fallback covers the case where the compiler recorded a
/// resolved path (`/private/var/…`) that no longer shares a prefix with the
/// root we were handed.
func repoRelative(_ absolute: String) -> String? {
    if absolute.hasPrefix(repoRoot + "/") {
        return String(absolute.dropFirst(repoRoot.count + 1))
    }
    if let hit = absolute.range(of: "/Packages/") {
        return String(absolute[absolute.index(after: hit.lowerBound)...])
    }
    return nil
}

/// A file counts only when it is the *source* of some package — that is the
/// dependency-scoping rule from gotcha 1. Returns the owning package name.
func owningPackage(of relative: String) -> String? {
    // SwiftPM's generated XCTest/swift-testing entry point lands in the export
    // as `…/<Pkg>PackageTests.derived/runner.swift`. It lives under .build so
    // the Sources check below already rejects it; the explicit guard documents
    // that this is deliberate rather than incidental.
    guard !relative.contains(".derived/") else { return nil }

    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count > 3, parts[0] == "Packages", parts[2] == "Sources" else { return nil }
    return String(parts[1])
}

/// Which package's test binary produced this export, from
/// `Packages/<Pkg>/.build/<triple>/debug/codecov/<Pkg>.json`. Used to tell "my
/// own suite covered this" from "something that linked me did".
func producingPackage(of reportPath: String) -> String? {
    let relative = repoRelative(reportPath) ?? reportPath
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count > 2, parts[0] == "Packages" else { return nil }
    return String(parts[1])
}

// MARK: - Merge

var merged: [String: FileCoverage] = [:]
var measuredPackages: Set<String> = []

for report in reports {
    guard let blob = FileManager.default.contents(atPath: report) else {
        die("cannot read \(report)")
    }
    let export: Export
    do {
        export = try JSONDecoder().decode(Export.self, from: blob)
    } catch {
        die("\(report) is not an llvm-cov export: \(error)")
    }
    let producer = producingPackage(of: report)
    if let producer { measuredPackages.insert(producer) }

    for block in export.data {
        for file in block.files {
            guard let relative = repoRelative(file.filename),
                  let owner = owningPackage(of: relative) else { continue }

            let observed = Coverage(
                lines: Metric(count: file.summary.lines.count, covered: file.summary.lines.covered),
                regions: Metric(count: file.summary.regions.count, covered: file.summary.regions.covered)
            )

            var entry = merged[relative] ?? FileCoverage()
            entry.anySuite.absorb(observed)
            if owner == producer { entry.ownSuite.absorb(observed) }
            merged[relative] = entry
        }
    }
}

guard !merged.isEmpty else {
    die("""
        no package sources found in \(reports.count) export(s).
        Expected files under Packages/<Pkg>/Sources/ — was the repo root (\(repoRoot)) correct?
        """)
}

// How many executable lines a file has is a property of the source, not of
// which binary measured it, so both views share one denominator. For a package
// with its own test target the two counts already agree; this matters for a
// package that has none, whose own-suite export does not exist — without it
// such a package would read "0 lines, 0 missed" instead of "0% of N, all N
// missed", which is the truth.
for (path, coverage) in merged {
    var normalized = coverage
    normalized.ownSuite.lines.count = coverage.anySuite.lines.count
    normalized.ownSuite.regions.count = coverage.anySuite.regions.count
    merged[path] = normalized
}

// MARK: - Roll up

var packages: [String: PackageCoverage] = [:]
var total = Coverage()

for (path, coverage) in merged {
    guard let owner = owningPackage(of: path) else { continue }
    var bucket = packages[owner] ?? PackageCoverage(name: owner)
    bucket.ownSuiteMeasured = measuredPackages.contains(owner)
    bucket.ownSuite += coverage.ownSuite
    bucket.anySuite += coverage.anySuite
    bucket.files.append((path: path, coverage: coverage))
    packages[owner] = bucket

    total += coverage.anySuite
}

// Worst first — the table exists to point at what needs tests. Packages whose
// own suite did not run in this lane sort last: they have no own-suite number to
// rank on, and leaving them at 0% would park them permanently at the top of a
// list that is supposed to mean "fix these". Name breaks ties so the ordering is
// total and the output stays byte-stable.
var ranked: [PackageCoverage] = []
for var pkg in packages.values {
    pkg.files.sort { $0.path < $1.path }
    ranked.append(pkg)
}
ranked.sort { lhs, rhs in
    if lhs.ownSuiteMeasured != rhs.ownSuiteMeasured { return lhs.ownSuiteMeasured }
    if lhs.ownSuiteMeasured, lhs.ownSuite.lines.percent != rhs.ownSuite.lines.percent {
        return lhs.ownSuite.lines.percent < rhs.ownSuite.lines.percent
    }
    return lhs.name < rhs.name
}

// Packages present only as somebody else's dependency get a "—" row rather than
// a fabricated 0%.
let unmeasured = ranked.filter { !$0.ownSuiteMeasured }
let measuredCount = ranked.count - unmeasured.count

// MARK: - Emit

func metricJSON(_ metric: Metric, indent: String) -> String {
    """
    {
    \(indent)  "count": \(metric.count),
    \(indent)  "covered": \(metric.covered),
    \(indent)  "missed": \(metric.missed),
    \(indent)  "percent": \(fixed(metric.percent, 2))
    \(indent)}
    """
}

func coverageJSON(_ coverage: Coverage, indent: String) -> String {
    var out = "{\n"
    out += "\(indent)  \"lines\": \(metricJSON(coverage.lines, indent: indent + "  ")),\n"
    out += "\(indent)  \"regions\": \(metricJSON(coverage.regions, indent: indent + "  "))\n"
    out += "\(indent)}"
    return out
}

var json = "{\n"
json += "  \"schemaVersion\": 1,\n"
json += "  \"packageCount\": \(ranked.count),\n"
json += "  \"measuredPackageCount\": \(measuredCount),\n"
json += "  \"totals\": \(coverageJSON(total, indent: "  ")),\n"
json += "  \"packages\": [\n"
for (index, pkg) in ranked.enumerated() {
    json += "    {\n"
    json += "      \"name\": \(jsonString(pkg.name)),\n"
    json += "      \"ownSuiteMeasured\": \(pkg.ownSuiteMeasured),\n"
    json += "      \"ownSuite\": \(coverageJSON(pkg.ownSuite, indent: "      ")),\n"
    json += "      \"anySuite\": \(coverageJSON(pkg.anySuite, indent: "      ")),\n"
    json += "      \"files\": [\n"
    for (fileIndex, entry) in pkg.files.enumerated() {
        json += "        {\n"
        json += "          \"path\": \(jsonString(entry.path)),\n"
        json += "          \"ownSuite\": \(coverageJSON(entry.coverage.ownSuite, indent: "          ")),\n"
        json += "          \"anySuite\": \(coverageJSON(entry.coverage.anySuite, indent: "          "))\n"
        json += "        }\(fileIndex == pkg.files.count - 1 ? "" : ",")\n"
    }
    json += "      ]\n"
    json += "    }\(index == ranked.count - 1 ? "" : ",")\n"
}
json += "  ]\n"
json += "}\n"

var markdown = "# Swift test coverage\n\n"
markdown += "**Whole repo: \(fixed(total.lines.percent, 1))% line / "
markdown += "\(fixed(total.regions.percent, 1))% region** — "
markdown += "\(grouped(total.lines.count)) executable lines, \(grouped(total.lines.missed)) missed.\n\n"
markdown += "\(measuredCount) package\(measuredCount == 1 ? "" : "s") measured, worst first. "
markdown += "**Line %**, **Region %** and **Missed** are what each package's *own* test suite\n"
markdown += "reaches — the number to act on. **Any suite %** additionally credits a file that some\n"
markdown += "other package's tests exercised through a dependency, which is what the repo total\n"
markdown += "above is computed from; that is why the total beats the Missed column's sum.\n\n"
markdown += "| Package | Line % | Region % | Lines | Missed | Any suite % |\n"
markdown += "|---|---:|---:|---:|---:|---:|\n"
for pkg in ranked {
    markdown += "| \(pkg.name)"
    if pkg.ownSuiteMeasured {
        markdown += " | \(fixed(pkg.ownSuite.lines.percent, 1))%"
        markdown += " | \(fixed(pkg.ownSuite.regions.percent, 1))%"
        markdown += " | \(grouped(pkg.anySuite.lines.count))"
        markdown += " | \(grouped(pkg.ownSuite.lines.missed))"
    } else {
        markdown += " | — | — | \(grouped(pkg.anySuite.lines.count)) | —"
    }
    markdown += " | \(fixed(pkg.anySuite.lines.percent, 1))% |\n"
}

if unmeasured.isEmpty {
    markdown += "\nPer-file numbers are in `coverage-summary.json`.\n"
} else {
    let names = unmeasured.map(\.name).joined(separator: ", ")
    markdown += "\n**—** means this lane never ran that package's own suite; the sources were seen\n"
    markdown += "only because another package linked them, so **Any suite %** is all the evidence\n"
    markdown += "there is. Not a coverage regression. Affects: \(names).\n"
    markdown += "\nPer-file numbers are in `coverage-summary.json`.\n"
}

do {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    try json.write(toFile: "\(outDir)/coverage-summary.json", atomically: true, encoding: .utf8)
    try markdown.write(toFile: "\(outDir)/coverage-summary.md", atomically: true, encoding: .utf8)
} catch {
    die("cannot write into \(outDir): \(error)")
}

print(markdown, terminator: "")
