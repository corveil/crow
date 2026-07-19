import Foundation

public extension JSONValue {
    /// Bridge any `Encodable` value into a `JSONValue` by round-tripping through
    /// JSON. Lets RPC handlers return rich `Codable` payloads (e.g. the
    /// `get-state` snapshot) without hand-building `JSONValue` trees. A Swift
    /// client decodes the value back with `JSONDecoder` using the same models, so
    /// the default `Date`/enum strategies round-trip losslessly on both ends
    /// (CROW-581, Stage 2).
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
