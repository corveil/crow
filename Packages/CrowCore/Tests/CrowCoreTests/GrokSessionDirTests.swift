import Foundation
import Testing
@testable import CrowCore

@Suite struct GrokSessionDirTests {
    @Test func encodesSlashesToUppercasePercent2F() {
        // `/` → `%2F` (uppercase), the core of Grok's directory naming.
        #expect(GrokSessionDir.encode("/Users/j/Dev/acme-12")
                == "%2FUsers%2Fj%2FDev%2Facme-12")
    }

    @Test func preservesUnreservedCharacters() {
        // Dashes, dots, underscores, tildes and alphanumerics are the RFC 3986
        // unreserved set — left as-is (verified against #1090's real tree, where
        // `shell-crm-359` kept its dashes).
        #expect(GrokSessionDir.encode("/a/shell-crm-359_v2.1~x")
                == "%2Fa%2Fshell-crm-359_v2.1~x")
    }

    @Test func matchesReferenceExampleFrom1090() {
        // The exact directory name captured in reference ticket #1090.
        let path = "/Users/danny/Projects/devroot/corveil/shell-crm-359-x"
        #expect(GrokSessionDir.encode(path)
                == "%2FUsers%2Fdanny%2FProjects%2Fdevroot%2Fcorveil%2Fshell-crm-359-x")
    }

    @Test func decodeIsInverseOfEncode() {
        let paths = [
            "/Users/j/Dev/acme-12",
            "/Users/dustinhilgaertner/Dev2/RadiusMethod/crow-1098-wire-grok-logs",
            "/a/b c/weird %path",  // space + literal percent survive the round-trip
        ]
        for p in paths {
            #expect(GrokSessionDir.decode(GrokSessionDir.encode(p)) == p)
        }
    }

    @Test func decodesRealDirectoryNameToCwd() {
        #expect(GrokSessionDir.decode("%2FUsers%2Fj%2FDev%2Facme-12")
                == "/Users/j/Dev/acme-12")
    }
}
