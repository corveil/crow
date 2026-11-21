import ArgumentParser
import Testing

@testable import CrowCLILib

// Arg parsing for `crow review restrip` (CROW-1492). No socket is touched:
// `validate()` runs during `parse()`.

private let sampleUUID = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

@Test func reviewRestripParsesSession() throws {
    #expect(try ReviewRestrip.parse(["--session", sampleUUID]).session == sampleUUID)
}

@Test func reviewRestripRequiresSession() {
    #expect(throws: (any Error).self) { _ = try ReviewRestrip.parse([]) }
}

/// An unset `$CROW_SESSION_ID` expands to `--session ""`. That must fail in
/// the CLI, so the skill sees a non-zero exit and stops the review.
@Test func reviewRestripRejectsEmptyOrMalformedSession() {
    #expect(throws: (any Error).self) { _ = try ReviewRestrip.parse(["--session", ""]) }
    #expect(throws: (any Error).self) { _ = try ReviewRestrip.parse(["--session", "nope"]) }
}

/// The verb takes no path: the daemon resolves the clone from the session.
@Test func reviewRestripTakesNoPath() {
    #expect(throws: (any Error).self) {
        _ = try ReviewRestrip.parse(["--session", sampleUUID, "--path", "/tmp/x"])
    }
    #expect(throws: (any Error).self) {
        _ = try ReviewRestrip.parse(["--session", sampleUUID, "/tmp/x"])
    }
}

@Test func reviewGroupRoutesRestrip() throws {
    let parsed = try CrowCommand.parseAsRoot(["review", "restrip", "--session", sampleUUID])
    #expect(parsed is ReviewRestrip)
}
