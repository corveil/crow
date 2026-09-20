import Foundation

/// Web-access password material (CROW-593): a PBKDF2-HMAC-SHA256 hash of the
/// password plus its salt and iteration count — never the plaintext. Presence of
/// this block means "a web password is set". `SettingsSecrets` blanks `hashB64`
/// and `saltB64` before the config is sent to a browser, so a client only learns
/// that a password exists, not its hash. Decodes tolerantly (missing fields → "")
/// so a partially-written config never traps.
public struct WebAuthConfig: Codable, Sendable, Equatable {
    public var hashB64: String
    public var saltB64: String
    public var iterations: Int

    public init(hashB64: String, saltB64: String, iterations: Int) {
        self.hashB64 = hashB64
        self.saltB64 = saltB64
        self.iterations = iterations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hashB64 = try c.decodeIfPresent(String.self, forKey: .hashB64) ?? ""
        saltB64 = try c.decodeIfPresent(String.self, forKey: .saltB64) ?? ""
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
    }

    enum CodingKeys: String, CodingKey { case hashB64, saltB64, iterations }
}
