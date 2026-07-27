import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding and response encoding for the `notifications-*` RPC handlers (CROW-813).
@Suite("Notification RPC support")
struct NotificationRPCSupportTests {

    // MARK: - decodeEvent

    @Test func decodeEventAcceptsEveryCase() throws {
        for event in NotificationEvent.allCases {
            #expect(try NotificationRPC.decodeEvent(.string(event.rawValue)) == event)
        }
    }

    @Test func decodeEventRejectsUnknownAndMissing() {
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeEvent(.string("nope")) }
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeEvent(nil) }
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeEvent(.int(3)) }
    }

    /// The error has to name the valid values — the CLI surfaces it verbatim.
    @Test func decodeEventErrorListsEveryEvent() {
        do {
            _ = try NotificationRPC.decodeEvent(.string("nope"))
            Issue.record("expected a throw")
        } catch let error as RPCError {
            guard case .invalidParams(let message) = error else {
                Issue.record("expected invalidParams")
                return
            }
            for event in NotificationEvent.allCases {
                #expect(message.contains(event.rawValue))
            }
        } catch {
            Issue.record("expected RPCError")
        }
    }

    // MARK: - decodeSoundName

    @Test func decodeSoundNameCanonicalizesCase() throws {
        #expect(try NotificationRPC.decodeSoundName(.string("hero")) == "Hero")
        #expect(try NotificationRPC.decodeSoundName(.string("Glass")) == "Glass")
    }

    @Test func decodeSoundNameRejectsNonBuiltIns() {
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeSoundName(.string("Nope")) }
        #expect(throws: RPCError.self) {
            _ = try NotificationRPC.decodeSoundName(.string("/System/Library/Sounds/Glass.aiff"))
        }
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeSoundName(nil) }
    }

    // MARK: - settingsJSON

    @Test func settingsJSONListsEveryEventAsAnObject() throws {
        let object = try #require(NotificationRPC.settingsJSON(NotificationSettings()).objectValue)

        #expect(object["global_mute"]?.boolValue == false)
        #expect(object["sound_enabled"]?.boolValue == true)
        #expect(object["system_notifications_enabled"]?.boolValue == true)
        #expect(object["config_readable"]?.boolValue == true)
        #expect(object["available_sounds"]?.arrayValue?.count == NotificationSettings.builtInSounds.count)

        // An object keyed by raw value, NOT the flat alternating array that
        // JSONEncoder produces for a dictionary keyed by a non-CodingKey enum.
        let events = try #require(object["events"]?.objectValue)
        #expect(events.count == NotificationEvent.allCases.count)
        for event in NotificationEvent.allCases {
            let config = try #require(events[event.rawValue]?.objectValue)
            #expect(config["enabled"]?.boolValue == true)
            #expect(config["sound_name"]?.stringValue == event.defaultSound)
        }
    }

    /// Events missing from the stored config still report the defaults they
    /// will actually fire with, via `config(for:)`.
    @Test func settingsJSONResolvesEventsAbsentFromConfig() throws {
        let settings = NotificationSettings(eventSettings: [:])
        let object = try #require(NotificationRPC.settingsJSON(settings).objectValue)
        let events = try #require(object["events"]?.objectValue)

        #expect(events.count == NotificationEvent.allCases.count)
        let config = try #require(events["autoRebaseConflicts"]?.objectValue)
        #expect(config["sound_name"]?.stringValue == NotificationEvent.autoRebaseConflicts.defaultSound)
    }

    @Test func settingsJSONFilterKeepsGlobals() throws {
        var settings = NotificationSettings()
        settings.globalMute = true
        let object = try #require(
            NotificationRPC.settingsJSON(settings, only: .taskComplete).objectValue)

        let events = try #require(object["events"]?.objectValue)
        #expect(events.count == 1)
        #expect(events["taskComplete"] != nil)
        // Without the globals a caller can't tell that globalMute is why
        // nothing fires, so they stay in the filtered response.
        #expect(object["global_mute"]?.boolValue == true)
        #expect(object["sound_enabled"]?.boolValue == true)
    }

    /// Reads never validate: a config carrying a custom sound path predates the
    /// CLI's built-ins-only write rule and must echo back unchanged.
    @Test func settingsJSONEchoesCustomSoundNameUnvalidated() throws {
        var settings = NotificationSettings()
        settings.eventSettings[.taskComplete] = EventNotificationConfig(
            soundName: "/Users/me/Sounds/custom.aiff")
        let object = try #require(NotificationRPC.settingsJSON(settings).objectValue)
        let events = try #require(object["events"]?.objectValue)
        let config = try #require(events["taskComplete"]?.objectValue)

        #expect(config["sound_name"]?.stringValue == "/Users/me/Sounds/custom.aiff")
    }

    @Test func settingsJSONReportsUnreadableConfig() throws {
        let object = try #require(
            NotificationRPC.settingsJSON(NotificationSettings(), configReadable: false).objectValue)
        #expect(object["config_readable"]?.boolValue == false)
    }
}
