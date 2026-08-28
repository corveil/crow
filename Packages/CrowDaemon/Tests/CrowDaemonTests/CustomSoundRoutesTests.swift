import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import CrowDaemon
import CrowCore

@Suite("Custom sound HTTP routes")
struct CustomSoundRoutesTests {
    private func makeApp(_ library: CustomSoundLibrary) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        CustomSoundRoutes.mount(on: router, boundHost: "127.0.0.1", library: library)
        return Application(router: router)
    }

    @Test func getServesUploadedWav() async throws {
        let lib = CustomSoundLibrary.temporary()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        let sound = try lib.add(data: NotificationTestAudio.wav, filename: "chime.wav", requestedName: "Chime")

        try await makeApp(lib).test(.router) { client in
            try await client.execute(uri: sound.url, method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "audio/wav")
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.body.readableBytes == NotificationTestAudio.wav.count)
            }
        }
    }

    @Test func getRejectsTraversal() async throws {
        let lib = CustomSoundLibrary.temporary()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        try await makeApp(lib).test(.router) { client in
            try await client.execute(uri: "/sounds/../Package.swift", method: .get) { response in
                #expect(response.status == .badRequest || response.status == .notFound)
            }
            try await client.execute(uri: "/sounds/notes.txt", method: .get) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func postUploadsAndGetServes() async throws {
        let lib = CustomSoundLibrary.temporary()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        try await makeApp(lib).test(.router) { client in
            try await client.execute(
                uri: "/sounds",
                method: .post,
                headers: [HTTPField.Name("x-filename")!: "Office Bell.wav"],
                body: ByteBuffer(bytes: NotificationTestAudio.wav)
            ) { response in
                #expect(response.status == .ok)
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                )
                #expect(json["name"] as? String == "Office-Bell")
                #expect(json["file"] as? String == "Office-Bell.wav")
                #expect(json["url"] as? String == "/sounds/Office-Bell.wav")
            }
            try await client.execute(uri: "/sounds/Office-Bell.wav", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "audio/wav")
            }
        }
    }

    @Test func postRejectsNonAudio() async throws {
        let lib = CustomSoundLibrary.temporary()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        try await makeApp(lib).test(.router) { client in
            try await client.execute(
                uri: "/sounds",
                method: .post,
                headers: [HTTPField.Name("x-filename")!: "notes.wav"],
                body: ByteBuffer(bytes: Array("not a wav".utf8))
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func postRejectsUnsupportedExtension() async throws {
        let lib = CustomSoundLibrary.temporary()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        try await makeApp(lib).test(.router) { client in
            try await client.execute(
                uri: "/sounds",
                method: .post,
                headers: [HTTPField.Name("x-filename")!: "notes.txt"],
                body: ByteBuffer(bytes: NotificationTestAudio.wav)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
