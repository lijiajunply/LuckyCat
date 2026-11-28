import Clash
import Foundation

/// Stages the GeoIP / GeoSite files required by the effective configuration.
/// The files are shared by every imported profile and live in the extension's
/// Clash working directory so the core never has to download them while the
/// tunnel is coming up.
enum ClashGeodata {
    nonisolated static let geoIPFileName = "GeoIP.dat"
    nonisolated static let geoSiteFileName = "GeoSite.dat"
    nonisolated static let geoIPDatabaseFileName = "geoip.metadb"
    nonisolated static let geoIPSourceKey = "geoIPSource"
    nonisolated static let geoSiteSourceKey = "geoSiteSource"
    nonisolated static let updateIntervalKey = "geoUpdateIntervalDays"

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

    nonisolated struct Requirement: Decodable, Equatable {
        let kind: String
        let format: String
        let url: String?
    }

    private struct Plan: Decodable {
        let geodata: [Requirement]
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
        !requirements(for: yaml).isEmpty
    }

    nonisolated static func requirements(for yaml: String) -> [Requirement] {
        if let box = ClashPlanResourcesForIOS(yaml, nil),
           let plan = try? JSONDecoder().decode(Plan.self, from: Data(box.value.utf8)) {
            return plan.geodata.filter { $0.kind == "geoip" || $0.kind == "geosite" }
        }
        // A malformed or unsupported document should not silently omit a
        // resource that the old rule-based detection would have prepared.
        let upper = yaml.uppercased()
        var fallback: [Requirement] = []
        if upper.contains("GEOIP,") { fallback.append(.init(kind: "geoip", format: "dat", url: nil)) }
        if upper.contains("GEOSITE,") || upper.contains("GEOSITE:") {
            fallback.append(.init(kind: "geosite", format: "dat", url: nil))
        }
        return fallback
    }

    nonisolated static func ensure(yaml: String, force: Bool = false, allowAutomaticUpdate: Bool = false) async throws {
        let requirements = requirements(for: yaml)
        guard force || !requirements.isEmpty else { return }
        let directory = try workingDirectory()
        let endpoints = endpoints(from: yaml)
        let defaults = UserDefaults.standard
        let customIP = defaults.string(forKey: geoIPSourceKey) ?? ""
        let customSite = defaults.string(forKey: geoSiteSourceKey) ?? ""
        let interval = defaults.integer(forKey: updateIntervalKey)

        let needsIPDat = force || requirements.contains { $0.kind == "geoip" && $0.format == "dat" }
        let needsSite = force || requirements.contains { $0.kind == "geosite" }
        if needsIPDat && !customIP.isEmpty && httpsURL(customIP) == nil { throw Failure.invalid(geoIPFileName) }
        if needsSite && !customSite.isEmpty && httpsURL(customSite) == nil { throw Failure.invalid(geoSiteFileName) }
        var sources: [Resource] = []
        if needsIPDat {
            sources.append(Resource(
                name: geoIPFileName,
                urls: httpsURL(customIP).map { [$0] } ?? (endpoints.geoIP.isEmpty
                    ? [mirrorGeoIP, defaultGeoIP] : endpoints.geoIP)
            ))
        }
        if needsSite {
            sources.append(Resource(
                name: geoSiteFileName,
                urls: httpsURL(customSite).map { [$0] } ?? (endpoints.geoSite.isEmpty
                    ? [mirrorGeoSite, defaultGeoSite] : endpoints.geoSite)
            ))
        }
        if let database = requirements.first(where: { $0.kind == "geoip" && $0.format == "mmdb" }) {
            let defaultURL = URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb")!
            sources.append(Resource(name: geoIPDatabaseFileName, urls: httpsURL(database.url).map { [$0] } ?? [defaultURL]))
        }
        for source in sources {
            let destination = directory.appending(path: source.name)
            let existingUsable = isUsable(destination)
            var due = false
            if !force && existingUsable {
                let modified = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate]) as? Date
                due = allowAutomaticUpdate && interval > 0
                    && (modified.map { Date().timeIntervalSince($0) >= Double(interval) * 86400 } ?? true)
                if !due { continue }
            }
            try await install(destination: destination, canUseExistingOnFailure: !force && existingUsable && due) {
                try await download(source)
            }
        }
    }

    /// Atomic replacement leaves an existing resource usable when a scheduled
    /// refresh fails. Explicit updates and first downloads still report errors.
    nonisolated static func install(
        destination: URL, canUseExistingOnFailure: Bool, fetch: () async throws -> Data
    ) async throws {
        do {
            let data = try await fetch()
            try Task.checkCancellation()
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try Task.checkCancellation()
            guard canUseExistingOnFailure, isUsable(destination) else { throw error }
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
        return [geoIPFileName, geoSiteFileName, geoIPDatabaseFileName].map { name in
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
            try Task.checkCancellation()
            do {
                return try await fetch(url, name: source.name)
            } catch let failure as Failure {
                lastFailure = failure
            } catch {
                try Task.checkCancellation()
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
            try Task.checkCancellation()
            throw Failure.download(name)
        }
    }

    nonisolated static func workingDirectory() throws -> URL {
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
