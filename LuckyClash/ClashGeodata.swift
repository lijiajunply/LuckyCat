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

    nonisolated private static let defaultGeoIP = URL(
        string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    )!
    nonisolated private static let defaultGeoSite = URL(
        string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    )!
    nonisolated private static let minimumBytes = 100 * 1024
    nonisolated private static let maximumBytes = 64 * 1024 * 1024

    nonisolated static func isRequired(_ yaml: String) -> Bool {
        let upper = yaml.uppercased()
        return upper.contains("GEOIP,") || upper.contains("GEOSITE,")
    }

    nonisolated static func ensure(yaml: String) async throws {
        guard isRequired(yaml) else { return }
        let directory = try workingDirectory()
        let endpoints = endpoints(from: yaml)

        for (url, name) in [
            (endpoints.geoIP, geoIPFileName),
            (endpoints.geoSite, geoSiteFileName)
        ] {
            let destination = directory.appending(path: name)
            if isUsable(destination) { continue }
            let data = try await download(url, name: name)
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    nonisolated private static func endpoints(from yaml: String) -> (geoIP: URL, geoSite: URL) {
        guard let box = ClashYamlToJSON(yaml, nil),
              let data = box.value.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let geox = document["geox-url"] as? [String: Any] else {
            return (defaultGeoIP, defaultGeoSite)
        }
        return (httpsURL(geox["geoip"]) ?? defaultGeoIP, httpsURL(geox["geosite"]) ?? defaultGeoSite)
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

    nonisolated private static func download(_ url: URL, name: String) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.download(name) }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  data.count >= minimumBytes, data.count <= maximumBytes,
                  http.url?.scheme?.lowercased() == "https" else {
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
