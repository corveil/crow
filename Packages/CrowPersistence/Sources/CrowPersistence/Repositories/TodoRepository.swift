import Foundation
import CrowCore

/// Repository for the durable pre-ticket Scratch list (CROW-1231).
///
/// Goes through the injected `JSONStore` — never a throwaway instance — so
/// mutations cannot clobber sessions via the whole-file write race (#728).
/// The collection is **not** cascaded when a session is deleted and is **not**
/// visited by the retention reaper: a parked idea must persist until acted on.
public struct TodoRepository: Sendable {
    private let store: JSONStore

    public init(store: JSONStore) {
        self.store = store
    }

    public func all() -> [TodoItem] {
        store.data.todos ?? []
    }

    public func find(id: UUID) -> TodoItem? {
        all().first { $0.id == id }
    }

    public func save(_ item: TodoItem) {
        store.mutate { data in
            var items = data.todos ?? []
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = item
            } else {
                items.append(item)
            }
            data.todos = items
        }
    }

    public func delete(id: UUID) -> Bool {
        var removed = false
        store.mutate { data in
            var items = data.todos ?? []
            let before = items.count
            items.removeAll { $0.id == id }
            removed = items.count != before
            data.todos = items
        }
        return removed
    }
}
