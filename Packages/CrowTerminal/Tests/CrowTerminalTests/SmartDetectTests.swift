import Foundation
import Testing
@testable import CrowTerminal

@Suite("SmartDetect URL and file:line heuristics")
struct SmartDetectTests {
    private let schemes: Set<String> = ["http", "https", "mailto"]

    // MARK: - detectURL

    @Test func detectsHttpsURLInPlainSelection() {
        let url = SmartDetect.detectURL(
            in: "https://github.com/corveil/crow",
            allowedSchemes: schemes
        )
        #expect(url?.absoluteString == "https://github.com/corveil/crow")
    }

    @Test func detectURLTolersWhitespace() {
        let url = SmartDetect.detectURL(
            in: "   https://example.com   ",
            allowedSchemes: schemes
        )
        #expect(url?.host == "example.com")
    }

    @Test func detectURLDropsDisallowedSchemes() {
        let url = SmartDetect.detectURL(
            in: "file:///etc/passwd",
            allowedSchemes: schemes
        )
        #expect(url == nil)
    }

    @Test func detectURLPicksFirstAllowedHit() {
        let text = "see http://a.test then https://b.test"
        let url = SmartDetect.detectURL(in: text, allowedSchemes: schemes)
        #expect(url?.host == "a.test")
    }

    @Test func detectURLEmptyOrNoMatch() {
        #expect(SmartDetect.detectURL(in: "", allowedSchemes: schemes) == nil)
        #expect(SmartDetect.detectURL(in: "just text", allowedSchemes: schemes) == nil)
    }

    // MARK: - detectURLFallback (Linux path; exercised on all platforms)

    @Test func fallbackPreservesBalancedParensInPath() {
        let url = SmartDetect.detectURLFallback(
            in: "https://en.wikipedia.org/wiki/Crow_(disambiguation)",
            allowedSchemes: schemes)
        #expect(url?.absoluteString == "https://en.wikipedia.org/wiki/Crow_(disambiguation)")
    }

    @Test func fallbackPreservesQueryParens() {
        let url = SmartDetect.detectURLFallback(
            in: "https://example.com/a?b=1&c=(2)",
            allowedSchemes: schemes)
        #expect(url?.absoluteString == "https://example.com/a?b=1&c=(2)")
    }

    @Test func fallbackDetectsMailto() {
        let url = SmartDetect.detectURLFallback(
            in: "mailto:dev@example.com",
            allowedSchemes: schemes)
        #expect(url?.absoluteString == "mailto:dev@example.com")
    }

    @Test func fallbackStripsWrappingParen() {
        let url = SmartDetect.detectURLFallback(
            in: "(https://example.com)",
            allowedSchemes: schemes)
        #expect(url?.host == "example.com")
    }

    @Test func fallbackDoesNotMatchBareHost() {
        #expect(SmartDetect.detectURLFallback(
            in: "visit github.com/corveil/crow",
            allowedSchemes: schemes) == nil)
    }

    @Test func fallbackPicksFirstURLBeforeMailto() {
        let url = SmartDetect.detectURLFallback(
            in: "See https://example.com/first then mailto:dev@example.com",
            allowedSchemes: schemes)
        #expect(url?.host == "example.com")
        #expect(url?.path == "/first")
    }

    @Test func fallbackPreservesIPv6Literal() {
        let url = SmartDetect.detectURLFallback(
            in: "http://[::1]",
            allowedSchemes: schemes)
        #expect(url?.absoluteString == "http://[::1]")
    }

    // MARK: - detectFileLine

    @Test func detectsBasicPathLine() throws {
        let hit = try #require(SmartDetect.detectFileLine(in: "Sources/Foo.swift:42"))
        #expect(hit.path == "Sources/Foo.swift")
        #expect(hit.line == 42)
    }

    @Test func detectsPathLineColumn() throws {
        let hit = try #require(SmartDetect.detectFileLine(in: "src/main.rs:10:5"))
        #expect(hit.path == "src/main.rs")
        #expect(hit.line == 10)
    }

    @Test func detectsAbsolutePath() throws {
        let hit = try #require(SmartDetect.detectFileLine(in: "/usr/local/lib/foo.swift:1"))
        #expect(hit.path == "/usr/local/lib/foo.swift")
        #expect(hit.line == 1)
    }

    @Test func rejectsURLLike() {
        // Should not collide with `detectURL` — schemes contain `://`.
        #expect(SmartDetect.detectFileLine(in: "https://github.com:443") == nil)
    }

    @Test func rejectsExtensionlessPath() {
        // Basename must have a dot so we don't grab e.g. `foo:42` from
        // a random shell prompt token.
        #expect(SmartDetect.detectFileLine(in: "build:42") == nil)
    }

    @Test func rejectsMissingLine() {
        #expect(SmartDetect.detectFileLine(in: "Sources/Foo.swift") == nil)
    }

    @Test func trimsWhitespace() throws {
        let hit = try #require(SmartDetect.detectFileLine(in: "  Sources/Foo.swift:7  "))
        #expect(hit.path == "Sources/Foo.swift")
        #expect(hit.line == 7)
    }
}
