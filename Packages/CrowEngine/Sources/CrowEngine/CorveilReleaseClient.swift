import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub Releases client for `corveil/corveil-releases` (CROW-1210).
///
/// Public repo, no auth. Same injectable-transport shape as
/// ``VersionUpdateClient`` so tests never hit the network.
public enum CorveilReleaseClient {
    public static let repository = "corveil/corveil-releases"

    public enum FetchError: Error, Equatable {
        case invalidURL
        case http(Int)
        case transport(String)
        case decode
        case assetMissing(String)
        case assetTooLarge(Int)
    }

    public struct Release: Equatable, Sendable {
        public var tag: String
        public var assets: [Asset]

        public init(tag: String, assets: [Asset]) {
            self.tag = tag
            self.assets = assets
        }

        public func asset(named name: String) -> Asset? {
            assets.first { $0.name == name }
        }
    }

    public struct Asset: Equatable, Sendable {
        public var name: String
        public var downloadURL: URL
        public var size: Int

        public init(name: String, downloadURL: URL, size: Int) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
        }
    }

    /// `latest` hits `/releases/latest`; anything else is `/releases/tags/{tag}`.
    public static func fetchRelease(
        version: String,
        userAgent: String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Release {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed.lowercased() == "latest" {
            path = "https://api.github.com/repos/\(repository)/releases/latest"
        } else {
            guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw FetchError.invalidURL
            }
            path = "https://api.github.com/repos/\(repository)/releases/tags/\(encoded)"
        }
        guard let url = URL(string: path) else { throw FetchError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            let (payload, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else {
                throw FetchError.transport("No HTTP response from GitHub")
            }
            guard (200...299).contains(http.statusCode) else {
                throw FetchError.http(http.statusCode)
            }
            data = payload
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            throw FetchError.decode
        }
        let rawAssets = json["assets"] as? [[String: Any]] ?? []
        var assets: [Asset] = []
        for node in rawAssets {
            guard let name = node["name"] as? String, !name.isEmpty,
                  let urlString = node["browser_download_url"] as? String,
                  let downloadURL = URL(string: urlString) else {
                continue
            }
            let size = node["size"] as? Int ?? 0
            assets.append(Asset(name: name, downloadURL: downloadURL, size: size))
        }
        return Release(tag: tag, assets: assets)
    }

    public static func download(
        url: URL,
        userAgent: String,
        maxBytes: Int = CorveilAutoUpdate.maxAssetBytes,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (payload, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw FetchError.http(http.statusCode)
            }
            if payload.count > maxBytes {
                throw FetchError.assetTooLarge(payload.count)
            }
            return payload
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
    }
}
