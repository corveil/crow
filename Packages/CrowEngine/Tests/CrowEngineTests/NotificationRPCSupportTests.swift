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

    @Test func decodeSoundNameAcceptsCustomNames() throws {
        #expect(try NotificationRPC.decodeSoundName(
            .string("office-bell"), customNames: ["Office-Bell"]) == "Office-Bell")
        #expect(throws: RPCError.self) {
            _ = try NotificationRPC.decodeSoundName(.string("Nope"), customNames: ["Office-Bell"])
        }
    }

    // MARK: - settingsJSON

    @Test func settingsJSONListsEveryEventAsAnObject() throws {
        let object = try #require(NotificationRPC.settingsJSON(NotificationSettings()).objectValue)

        #expect(object["global_mute"]?.boolValue == false)
        #expect(object["sound_enabled"]?.boolValue == true)
        #expect(object["system_notifications_enabled"]?.boolValue == true)
        #expect(object["config_readable"]?.boolValue == true)
        #expect(object["available_sounds"]?.arrayValue?.count == NotificationSettings.builtInSounds.count)
        #expect(object["custom_sounds"]?.arrayValue?.isEmpty == true)

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

    @Test func settingsJSONMergesCustomSoundsIntoAvailable() throws {
        let custom = CustomSound(name: "Office-Bell", file: "Office-Bell.wav", url: "/sounds/Office-Bell.wav")
        let object = try #require(
            NotificationRPC.settingsJSON(NotificationSettings(), customSounds: [custom]).objectValue)
        let available = try #require(object["available_sounds"]?.arrayValue)
        #expect(available.last == .string("Office-Bell"))
        let listed = try #require(object["custom_sounds"]?.arrayValue)
        #expect(listed.count == 1)
        #expect(listed[0].objectValue?["url"]?.stringValue == "/sounds/Office-Bell.wav")
    }

    @Test func settingsJSONReportsUnreadableConfig() throws {
        let object = try #require(
            NotificationRPC.settingsJSON(NotificationSettings(), configReadable: false).objectValue)
        #expect(object["config_readable"]?.boolValue == false)
    }

    // MARK: - Voice (voice spike)

    @Test func settingsJSONReportsResolvedVoiceFields() {
        var settings = NotificationSettings(voiceEnabled: true, voiceName: "Samantha", voiceRate: 1.25)
        settings.eventSettings[.agentWaiting] = EventNotificationConfig(
            soundName: "Funk", voiceEnabled: false, voiceTemplate: "{session} wants you")
        guard case .object(let root) = NotificationRPC.settingsJSON(settings),
              case .object(let events) = root["events"],
              case .object(let waiting) = events["agentWaiting"],
              case .object(let done) = events["taskComplete"]
        else { Issue.record("unexpected shape"); return }
        #expect(root["voice_enabled"] == .bool(true))
        #expect(root["voice_name"] == .string("Samantha"))
        #expect(root["voice_rate"] == .double(1.25))
        #expect(root["chime_before_voice"] == .bool(false))
        #expect(waiting["voice_enabled"] == .bool(false))
        #expect(waiting["voice_template"] == .string("{session} wants you"))
        #expect(waiting["default_voice_template"] == .string("{session} needs you"))
        #expect(done["voice_enabled"] == .bool(true))
        #expect(done["voice_template"] == .string("{session} is done"))
    }

    @Test func settingsJSONReportsNullVoiceNameWhenUnset() {
        guard case .object(let root) = NotificationRPC.settingsJSON(NotificationSettings()) else {
            Issue.record("unexpected shape"); return
        }
        #expect(root["voice_name"] == .null)
        #expect(root["voice_enabled"] == .bool(false))
    }

    @Test func decodeVoiceRateAcceptsIntAndDoubleInRange() throws {
        #expect(try NotificationRPC.decodeVoiceRate(.int(1)) == 1.0)
        #expect(try NotificationRPC.decodeVoiceRate(.double(1.5)) == 1.5)
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeVoiceRate(.double(3)) }
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeVoiceRate(.string("fast")) }
        #expect(try NotificationRPC.decodeVoiceVolume(.int(0)) == 0.0)
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeVoiceVolume(.double(1.5)) }
    }

    @Test func decodeVoiceNameAndTemplateTreatEmptyAsReset() throws {
        #expect(try NotificationRPC.decodeVoiceName(.string("")) == nil)
        #expect(try NotificationRPC.decodeVoiceName(.string("Fred")) == "Fred")
        #expect(try NotificationRPC.decodeVoiceTemplate(.string("  ")) == nil)
        #expect(try NotificationRPC.decodeVoiceTemplate(.string("{repo} broke")) == "{repo} broke")
        #expect(throws: RPCError.self) { _ = try NotificationRPC.decodeVoiceTemplate(.bool(true)) }
        #expect(throws: RPCError.self) {
            _ = try NotificationRPC.decodeVoiceTemplate(.string(String(repeating: "x", count: 500)))
        }
    }
}
