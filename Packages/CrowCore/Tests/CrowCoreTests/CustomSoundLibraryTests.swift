import Foundation
import Testing
@testable import CrowCore

@Suite("Custom sound library")
struct CustomSoundLibraryTests {
    private func library() -> CustomSoundLibrary {
        CustomSoundLibrary.temporary()
    }

    private func cleanup(_ lib: CustomSoundLibrary) {
        try? FileManager.default.removeItem(at: lib.directory)
    }

    // MARK: - add

    @Test func addCopiesWavAndListsIt() throws {
        let lib = library()
        defer { cleanup(lib) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-src-\(UUID().uuidString).wav")
        try TestAudio.wav.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let sound = try lib.add(from: source)
        #expect(sound.file.hasSuffix(".wav"))
        #expect(sound.url.hasPrefix(CustomSoundLibrary.urlPrefix))
        #expect(lib.list().map(\.name) == [sound.name])
        #expect(lib.sound(named: sound.name)?.file == sound.file)
        #expect(!sound.name.isEmpty)
    }

    @Test func addUsesRequestedNameAndSanitizes() throws {
        let lib = library()
        defer { cleanup(lib) }

        let sound = try lib.add(data: TestAudio.wav, filename: "ding.wav", requestedName: "Office Bell!")
        #expect(sound.name == "Office-Bell")
        #expect(sound.file == "Office-Bell.wav")
        #expect(sound.url == "/sounds/Office-Bell.wav")
    }

    @Test func addNormalizesAifToAiff() throws {
        let lib = library()
        defer { cleanup(lib) }
        let sound = try lib.add(data: TestAudio.aiff, filename: "tone.aif")
        #expect(sound.file == "tone.aiff")
        #expect(CustomSoundLibrary.contentType(for: sound.file) == "audio/aiff")
    }

    @Test func addRejectsUnsupportedExtension() {
        let lib = library()
        defer { cleanup(lib) }
        #expect(throws: CustomSoundError.unsupportedFormat) {
            try lib.add(data: TestAudio.wav, filename: "beep.txt")
        }
    }

    @Test func addRejectsNonAudioBytes() {
        let lib = library()
        defer { cleanup(lib) }
        #expect(throws: CustomSoundError.notAudio) {
            try lib.add(data: Data("not audio".utf8), filename: "beep.wav")
        }
    }

    @Test func addRejectsTooLarge() {
        let lib = library()
        defer { cleanup(lib) }
        var data = TestAudio.wav
        data.append(Data(repeating: 0, count: CustomSoundLibrary.maxBytes))
        #expect(throws: CustomSoundError.tooLarge(maxBytes: CustomSoundLibrary.maxBytes)) {
            try lib.add(data: data, filename: "huge.wav")
        }
    }

    @Test func addRejectsBuiltInNameCollision() {
        let lib = library()
        defer { cleanup(lib) }
        #expect(throws: CustomSoundError.nameConflict("Glass")) {
            try lib.add(data: TestAudio.wav, filename: "x.wav", requestedName: "glass")
        }
    }

    @Test func addRejectsDuplicateCustomName() throws {
        let lib = library()
        defer { cleanup(lib) }
        _ = try lib.add(data: TestAudio.wav, filename: "a.wav", requestedName: "Chime")
        #expect(throws: CustomSoundError.nameConflict("Chime")) {
            try lib.add(data: TestAudio.mp3, filename: "b.mp3", requestedName: "chime")
        }
    }

    @Test func addRejectsEmptySanitizedName() {
        let lib = library()
        defer { cleanup(lib) }
        #expect(throws: CustomSoundError.invalidName) {
            try lib.add(data: TestAudio.wav, filename: "x.wav", requestedName: "!!!")
        }
    }

    @Test func addFromMissingPath() {
        let lib = library()
        defer { cleanup(lib) }
        let missing = URL(fileURLWithPath: "/no/such/crow-sound-\(UUID().uuidString).wav")
        #expect(throws: CustomSoundError.fileNotFound(missing.path)) {
            try lib.add(from: missing)
        }
    }

    // MARK: - list / drop-in

    @Test func listPicksUpDroppedFilesAndSkipsBuiltInNames() throws {
        let lib = library()
        defer { cleanup(lib) }
        try FileManager.default.createDirectory(at: lib.directory, withIntermediateDirectories: true)
        try TestAudio.wav.write(to: lib.directory.appendingPathComponent("Dropped.wav"))
        try TestAudio.wav.write(to: lib.directory.appendingPathComponent("Glass.wav"))
        try Data("nope".utf8).write(to: lib.directory.appendingPathComponent("notes.txt"))

        let names = lib.list().map(\.name)
        #expect(names == ["Dropped"])
    }

    @Test func listSkipsOversizedDroppedFiles() throws {
        let lib = library()
        defer { cleanup(lib) }
        try FileManager.default.createDirectory(at: lib.directory, withIntermediateDirectories: true)
        try TestAudio.wav.write(to: lib.directory.appendingPathComponent("ok.wav"))
        let huge = Data(repeating: 0, count: CustomSoundLibrary.maxBytes + 1)
        try huge.write(to: lib.directory.appendingPathComponent("huge.wav"))
        #expect(lib.list().map(\.name) == ["ok"])
        #expect(lib.resolvedFile("huge.wav") == nil)
    }

    // MARK: - remove

    @Test func removeDeletesTheFile() throws {
        let lib = library()
        defer { cleanup(lib) }
        let sound = try lib.add(data: TestAudio.wav, filename: "gone.wav", requestedName: "Gone")
        try lib.remove(name: "gone")
        #expect(lib.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lib.directory.appendingPathComponent(sound.file).path))
    }

    @Test func removeMissingName() {
        let lib = library()
        defer { cleanup(lib) }
        #expect(throws: CustomSoundError.missing("Nope")) {
            try lib.remove(name: "Nope")
        }
    }

    // MARK: - guards

    @Test func isSafeFileName() {
        #expect(CustomSoundLibrary.isSafeFileName("chime.wav"))
        #expect(CustomSoundLibrary.isSafeFileName("a.MP3"))
        #expect(CustomSoundLibrary.isSafeFileName("tone.aiff"))
        #expect(!CustomSoundLibrary.isSafeFileName("../secret.wav"))
        #expect(!CustomSoundLibrary.isSafeFileName("sub/dir.wav"))
        #expect(!CustomSoundLibrary.isSafeFileName("notes.txt"))
        #expect(!CustomSoundLibrary.isSafeFileName(""))
    }

    @Test func sanitizeStem() {
        #expect(CustomSoundLibrary.sanitizeStem("Office Bell") == "Office-Bell")
        #expect(CustomSoundLibrary.sanitizeStem("  --x--  ") == "x")
        #expect(CustomSoundLibrary.sanitizeStem("!!!") == nil)
        #expect(CustomSoundLibrary.sanitizeStem(String(repeating: "a", count: 80))?.count == 64)
    }

    @Test func looksLikeAudio() {
        #expect(CustomSoundLibrary.looksLikeAudio(TestAudio.wav, ext: "wav"))
        #expect(CustomSoundLibrary.looksLikeAudio(TestAudio.mp3, ext: "mp3"))
        #expect(CustomSoundLibrary.looksLikeAudio(TestAudio.aiff, ext: "aiff"))
        #expect(!CustomSoundLibrary.looksLikeAudio(Data("RIFF....NOTWAVE".utf8), ext: "wav"))
        #expect(!CustomSoundLibrary.looksLikeAudio(Data("short".utf8), ext: "wav"))
    }

    @Test func resolvedPathRejectsEscapingSymlink() throws {
        let lib = library()
        defer { cleanup(lib) }
        try FileManager.default.createDirectory(at: lib.directory, withIntermediateDirectories: true)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-sound-secret-\(UUID().uuidString).txt")
        try Data("SECRET".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = lib.directory.appendingPathComponent("shot.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(lib.resolvedFile("shot.wav") == nil)

        let real = lib.directory.appendingPathComponent("ok.wav")
        try TestAudio.wav.write(to: real)
        #expect(lib.resolvedFile("ok.wav") != nil)
        #expect(lib.resolvedFile("../ok.wav") == nil)
    }
}

enum TestAudio {
    static var wav: Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(contentsOf: [36, 0, 0, 0])
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x44, 0xAC, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0])
        d.append(contentsOf: Array("data".utf8))
        d.append(contentsOf: [0, 0, 0, 0])
        return d
    }

    static var mp3: Data {
        var d = Data(Array("ID3".utf8))
        d.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        d.append(contentsOf: [0xFF, 0xFB])
        d.append(Data(repeating: 0, count: 32))
        return d
    }

    static var aiff: Data {
        var d = Data()
        d.append(contentsOf: Array("FORM".utf8))
        d.append(contentsOf: [0, 0, 0, 4])
        d.append(contentsOf: Array("AIFF".utf8))
        return d
    }
}
