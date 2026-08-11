import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - `crow telemetry` / `crow cleanup` / `crow ui` parsing (CROW-814)
//
// `validate()` runs during `parse`, so range and "nothing to set" rejections
// surface here without a socket.

// MARK: - crow telemetry

@Test func telemetrySetParsesAllFlags() throws {
    let cmd = try TelemetrySet.parse([
        "--enabled", "true",
        "--port", "4319",
        "--retention-days", "30",
    ])
    #expect(cmd.enabled == true)
    #expect(cmd.port == 4319)
    #expect(cmd.retentionDays == 30)
}

/// The reason booleans are `@Option ... Bool?` and not `@Flag`: a patch has to
/// tell "set it to false" apart from "don't touch it", which a flag cannot express.
@Test func telemetrySetParsesExplicitFalse() throws {
    let cmd = try TelemetrySet.parse(["--enabled", "false"])
    #expect(cmd.enabled == false)
    #expect(cmd.port == nil)
    #expect(cmd.retentionDays == nil)
}

@Test func telemetrySetOmittedFlagsAreNil() throws {
    let cmd = try TelemetrySet.parse(["--port", "5000"])
    #expect(cmd.enabled == nil)
    #expect(cmd.retentionDays == nil)
    #expect(cmd.port == 5000)
}

/// ArgumentParser routes `Bool` through `LosslessStringConvertible`, which takes
/// only the exact literals — hence "(true or false)" in every help string.
@Test func telemetrySetRejectsNonBooleanEnabled() {
    for bad in ["yes", "1", "on", "True", "TRUE"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try TelemetrySet.parse(["--enabled", bad])
        }
    }
}

@Test func telemetrySetRejectsOutOfRangePort() {
    for bad in ["0", "80", "1023", "65536", "70000", "-1"] {
        #expect(throws: (any Error).self, "expected port '\(bad)' to be rejected") {
            _ = try TelemetrySet.parse(["--port", bad])
        }
    }
}

@Test func telemetrySetAcceptsZeroRetentionDays() throws {
    let cmd = try TelemetrySet.parse(["--retention-days", "0"])
    #expect(cmd.retentionDays == 0)
}

@Test func telemetrySetRejectsNegativeRetentionDays() {
    #expect(throws: (any Error).self) {
        _ = try TelemetrySet.parse(["--retention-days", "-1"])
    }
}

@Test func telemetrySetRequiresAtLeastOneField() {
    #expect(throws: (any Error).self) {
        _ = try TelemetrySet.parse([])
    }
}

// MARK: - crow cleanup

@Test func cleanupSetParsesAllFlags() throws {
    let cmd = try CleanupSet.parse(["--enabled", "true", "--retention-hours", "72"])
    #expect(cmd.enabled == true)
    #expect(cmd.retentionHours == 72)
}

@Test func cleanupSetParsesExplicitFalse() throws {
    let cmd = try CleanupSet.parse(["--enabled", "false"])
    #expect(cmd.enabled == false)
    #expect(cmd.retentionHours == nil)
}

/// A non-preset value the web UI's dropdown can't express is still valid — the
/// CLI validates ranges, not the picker's option list.
@Test func cleanupSetAcceptsNonPresetRetention() throws {
    #expect(try CleanupSet.parse(["--retention-hours", "48"]).retentionHours == 48)
}

@Test func cleanupSetRejectsZeroOrNegativeRetentionHours() {
    for bad in ["0", "-1", "-24"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try CleanupSet.parse(["--retention-hours", bad])
        }
    }
}

@Test func cleanupSetRequiresAtLeastOneField() {
    #expect(throws: (any Error).self) {
        _ = try CleanupSet.parse([])
    }
}

// MARK: - crow ui

@Test func uiSetParsesHideSessionDetails() throws {
    #expect(try UISet.parse(["--hide-session-details", "true"]).hideSessionDetails == true)
}

@Test func uiSetParsesSwitcherFlags() throws {
    let cmd = try UISet.parse([
        "--switcher-enabled", "false",
        "--switcher-binding", "ctrl+`",
        "--switcher-capture-in-terminal", "false",
        "--switcher-order", "sidebar",
        "--switcher-preview", "false",
        "--switcher-include", "managers=true",
        "--switcher-include", "completed=true",
    ])
    #expect(cmd.switcherEnabled == false)
    #expect(cmd.switcherBinding == "ctrl+`")
    #expect(cmd.switcherCaptureInTerminal == false)
    #expect(cmd.switcherOrder == "sidebar")
    #expect(cmd.switcherPreview == false)
    #expect(cmd.switcherIncludes == ["managers=true", "completed=true"])
}

@Test func uiSetParsesExplicitFalse() throws {
    #expect(try UISet.parse(["--hide-session-details", "false"]).hideSessionDetails == false)
}

@Test func uiSetRequiresAtLeastOneField() {
    #expect(throws: (any Error).self) {
        _ = try UISet.parse([])
    }
}

// MARK: - Groups

@Test func settingsGetCommandsTakeNoArguments() throws {
    _ = try TelemetryGet.parse([])
    _ = try CleanupGet.parse([])
    _ = try UIGet.parse([])
}

@Test func settingsGroupsRouteToSubcommands() throws {
    #expect(try Telemetry.parseAsRoot(["get"]) is TelemetryGet)
    #expect(try Telemetry.parseAsRoot(["set", "--enabled", "true"]) is TelemetrySet)
    #expect(try Cleanup.parseAsRoot(["get"]) is CleanupGet)
    #expect(try Cleanup.parseAsRoot(["set", "--enabled", "true"]) is CleanupSet)
    #expect(try UI.parseAsRoot(["get"]) is UIGet)
    #expect(try UI.parseAsRoot(["set", "--hide-session-details", "true"]) is UISet)
}

@Test func settingsGroupsRejectUnknownSubcommands() {
    #expect(throws: (any Error).self) { _ = try Telemetry.parseAsRoot(["enable"]) }
    #expect(throws: (any Error).self) { _ = try Cleanup.parseAsRoot(["run"]) }
    #expect(throws: (any Error).self) { _ = try UI.parseAsRoot(["open"]) }
}
