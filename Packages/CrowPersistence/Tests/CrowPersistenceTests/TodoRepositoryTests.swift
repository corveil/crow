import Foundation
import Testing
@testable import CrowPersistence
@testable import CrowCore

@Suite("TodoRepository (CROW-1231)")
struct TodoRepositoryTests {
    private func tempStore() -> (JSONStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (JSONStore(directory: dir), dir)
    }

    @Test func saveFindAndReload() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = TodoRepository(store: store)

        let item = TodoItem(text: "capture in place")
        repo.save(item)
        #expect(repo.find(id: item.id)?.text == "capture in place")

        let reloaded = TodoRepository(store: JSONStore(directory: dir))
        #expect(reloaded.all().count == 1)
        #expect(reloaded.find(id: item.id)?.text == "capture in place")
    }

    @Test func saveUpdatesExisting() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = TodoRepository(store: store)

        var item = TodoItem(text: "original")
        repo.save(item)
        item.text = "updated"
        item.state = .parked
        repo.save(item)
        #expect(repo.all().count == 1)
        #expect(repo.find(id: item.id)?.text == "updated")
        #expect(repo.find(id: item.id)?.state == .parked)
    }

    @Test func deleteRemovesOnlyThatItem() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = TodoRepository(store: store)

        let keep = TodoItem(text: "keep")
        let drop = TodoItem(text: "drop")
        repo.save(keep)
        repo.save(drop)
        #expect(repo.delete(id: drop.id))
        #expect(repo.all().map(\.id) == [keep.id])
        #expect(!repo.delete(id: drop.id))
    }

    @Test func olderStoreWithoutTodosKeyStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Minimal pre-CROW-1231 store.json: sessions only, no todos key.
        let json = """
        {"sessions":[],"worktrees":[],"links":[],"terminals":[]}
        """
        try json.write(
            to: dir.appendingPathComponent("store.json"), atomically: true, encoding: .utf8)

        let store = JSONStore(directory: dir)
        #expect(store.data.todos == nil)
        #expect(TodoRepository(store: store).all().isEmpty)
    }

    /// CROW-1477 stored a `kind` (`idea` / `friction`) on each item; CROW-1486
    /// reverted it. A store written in between must still load with every item
    /// intact — a decode failure here would send `store.json` down the
    /// corrupt-store backup path and empty the user's Scratch board.
    @Test func storeWithFrictionKindTodosStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let frictionID = UUID()
        let ideaID = UUID()
        let json = """
        {"sessions":[],"worktrees":[],"links":[],"terminals":[],"todos":[
          {"id":"\(frictionID.uuidString)","text":"[friction] crow send has no --wait-ready — polled",
           "note":"","tags":[],"state":"captured","kind":"friction","links":[],
           "createdAt":"2026-11-20T17:01:21Z","updatedAt":"2026-11-20T17:01:21Z"},
          {"id":"\(ideaID.uuidString)","text":"native scratch list","note":"","tags":["crow"],
           "state":"parked","kind":"idea","links":[],
           "createdAt":"2026-11-20T17:02:00Z","updatedAt":"2026-11-20T17:02:00Z"}
        ]}
        """
        let storeURL = dir.appendingPathComponent("store.json")
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let repo = TodoRepository(store: JSONStore(directory: dir))
        #expect(repo.all().count == 2)
        #expect(repo.find(id: frictionID)?.text == "[friction] crow send has no --wait-ready — polled")
        #expect(repo.find(id: frictionID)?.state == .captured)
        #expect(repo.find(id: ideaID)?.state == .parked)
        #expect(repo.find(id: ideaID)?.tags == ["crow"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("store.json.bak").path))
    }
}
