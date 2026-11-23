import Clash
import Foundation

/// Stages the `.dat` GeoIP / GeoSite files that GEOIP and GEOSITE rules need.
/// The files are shared by every imported profile and live in the extension's
/// Clash working directory so the core never has to download them while the
/// tunnel is coming up.
enum ClashGeodata {
    nonisolated static let geoIPFileName = "GeoIP.dat"
    nonisolated static let geoSiteFileName = "GeoSite.dat"

    enum Failure: LocalizedError {
        case download(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .download(let name): "无法下载 \(name)，请检查网络后重试。"
            case .invalid(let name): "\(name) 内容无效，请重试。"
            }
        }
    }

    private struct Resource {
        let name: String
        let urls: [URL]
    }

    nonisolated private static let defaultGeoIP = URL(
        string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    )!
    nonisolated private static let defaultGeoSite = URL(
        string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    )!
    // GitHub release downloads are throttled or unreachable on some networks,
    // which left users stuck before the tunnel could even start. jsDelivr mirrors
    // the same `release` branch, so try it first and keep GitHub as a fallback.
    nonisolated private static let mirrorGeoIP = URL(
        string: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
    )!
    nonisolated private static let mirrorGeoSite = URL(
        string: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
    )!
    nonisolated private static let minimumBytes = 100 * 1024
    nonisolated private static let maximumBytes = 64 * 1024 * 1024
    nonisolated private static let requestTimeout: TimeInterval = 30
    nonisolated private static let resourceTimeout: TimeInterval = 120

    nonisolated static func isRequired(_ yaml: String) -> Bool {
        let upper = yaml.uppercased()
        return upper.contains("GEOIP,") || upper.contains("GEOSITE,")
    }

    nonisolated static func ensure(yaml: String, force: Bool = false) async throws {
        guard force || isRequired(yaml) else { return }
        let directory = try workingDirectory()
        let endpoints = endpoints(from: yaml)

        for source in [
            Resource(
                name: geoIPFileName,
                urls: endpoints.geoIP.isEmpty
                    ? [mirrorGeoIP, defaultGeoIP] : endpoints.geoIP
            ),
            Resource(
                name: geoSiteFileName,
                urls: endpoints.geoSite.isEmpty
                    ? [mirrorGeoSite, defaultGeoSite] : endpoints.geoSite
            )
        ] {
            let destination = directory.appending(path: source.name)
            if !force && isUsable(destination) { continue }
            let data = try await download(source)
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    struct Status: Identifiable {
        let name: String
        let size: Int64?
        let modified: Date?
        var id: String { name }
    }

    nonisolated static func status() throws -> [Status] {
        let directory = try workingDirectory()
        return [geoIPFileName, geoSiteFileName].map { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            return Status(name: name, size: size, modified: attributes?[.modificationDate] as? Date)
        }
    }

    nonisolated private static func endpoints(from yaml: String) -> (geoIP: [URL], geoSite: [URL]) {
        guard let box = ClashYamlToJSON(yaml, nil),
              let data = box.value.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let geox = document["geox-url"] as? [String: Any] else {
            return ([], [])
        }
        return (
            httpsURL(geox["geoip"]).map { [$0] } ?? [],
            httpsURL(geox["geosite"]).map { [$0] } ?? []
        )
    }

    nonisolated private static func httpsURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    nonisolated private static func isUsable(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue >= minimumBytes
    }

    /// Tries every mirror in order and reports the last failure only once all
    /// of them have been exhausted.
    nonisolated private static func download(_ source: Resource) async throws -> Data {
        var lastFailure: Failure = .download(source.name)
        for url in source.urls {
            do {
                return try await fetch(url, name: source.name)
            } catch let failure as Failure {
                lastFailure = failure
            } catch {
                lastFailure = .download(source.name)
            }
        }
        throw lastFailure
    }

    nonisolated private static func fetch(_ url: URL, name: String) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.invalid(name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            var request = URLRequest(url: url)
            request.setValue("LuckyClash/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https",
                  data.count >= minimumBytes, data.count <= maximumBytes else {
                throw Failure.invalid(name)
            }
            if http.mimeType?.lowercased().contains("html") == true {
                throw Failure.invalid(name)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(name)
        }
    }

    nonisolated private static func workingDirectory() throws -> URL {
        #if targetEnvironment(simulator)
        let root = URL.applicationSupportDirectory
        #else
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyClash"
        ) else {
            throw PrototypeError.sharedContainerUnavailable
        }
        #endif
        // Must match ClashEngine's working path: the core's Unix socket lives at
        // the container root, so no product subdirectory is used.
        let directory = root.appending(path: "working", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
