import Foundation
import CrowPersistence

extension JSONStore {
    /// A `JSONStore` isolated to a unique temp directory, so a test never opens
    /// or mutates the live `~/Library/Application Support/crow/store.json`
    /// (#764, ADR 0012). Mirrors `LocalStatusTests.seededRouter`'s pattern.
    /// Always prefer this over a bare `JSONStore()` in tests — the bare form now
    /// traps under a test process.
    static func temporary() -> JSONStore {
        JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-test-\(UUID().uuidString)"))
    }
}
