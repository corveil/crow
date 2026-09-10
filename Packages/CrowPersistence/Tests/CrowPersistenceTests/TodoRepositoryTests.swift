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
}
