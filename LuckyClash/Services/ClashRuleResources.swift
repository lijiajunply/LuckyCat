import Clash
import CryptoKit
import Darwin
import Foundation

/// Creates a private snapshot of rule providers for the app-process matcher.
/// The core only permits file providers beneath its own working directory.
nonisolated enum ClashRuleResources {
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }
    struct Snapshot {
        let document: String
        let resourceMap: String?
        let directory: URL
    }

    static func syncGeodata(name: String, sourceDirectory: URL, workingDirectory: URL) throws -> FileIdentity? {
        let destination = workingDirectory.appendingPathComponent(name)
        guard let source = containedFile(name, in: sourceDirectory), let sourceIdentity = identity(of: source) else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            return nil
        }
        if let existing = identity(of: destination), existing.device == sourceIdentity.device,
           existing.inode == sourceIdentity.inode { return sourceIdentity }
        let staging = workingDirectory.appendingPathComponent(".geo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do { try FileManager.default.linkItem(at: source, to: staging) }
        catch { try FileManager.default.copyItem(at: source, to: staging) }
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return sourceIdentity
    }

    private static func identity(of file: URL) -> FileIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value,
                            size: size.uint64Value, modified: modified)
    }

    static func stage(document: String, sourceDirectory: URL, workingDirectory: URL) throws -> Snapshot {
        let directory = workingDirectory.appendingPathComponent("match-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            guard let box = ClashYamlToJSON(document, nil),
                  var root = try JSONSerialization.jsonObject(with: Data(box.value.utf8)) as? [String: Any],
                  var providers = root["rule-providers"] as? [String: [String: Any]] else {
                return Snapshot(document: document, resourceMap: nil, directory: directory)
            }
            var paths: [String: String] = [:]
            var changed = false
            for name in providers.keys.sorted() {
                guard var provider = providers[name],
                      let kind = (provider["type"] as? String)?.lowercased(),
                      kind == "http" || kind == "file" else { continue }
                let configuredPath = (provider["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let relative: String
                if !configuredPath.isEmpty {
                    relative = configuredPath
                } else if kind == "http", let address = provider["url"] as? String, !address.isEmpty {
                    let hash = Insecure.MD5.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
                    relative = "rules/\(hash)"
                } else { continue }
                guard let source = containedFile(relative, in: sourceDirectory) else { continue }
                let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                let destination = directory.appendingPathComponent(UUID().uuidString + suffix)
                do { try FileManager.default.copyItem(at: source, to: destination) }
                catch { continue }
                if kind == "http" {
                    paths["rule:\(name)"] = destination.path
                } else {
                    provider["path"] = destination.path
                    providers[name] = provider
                    changed = true
                }
            }
            var stagedDocument = document
            if changed {
                root["rule-providers"] = providers
                let data = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
                var error: NSError?
                guard let converted = ClashJSONToYaml(String(decoding: data, as: UTF8.self), &error) else {
                    throw error ?? ClashImport.Failure.unreadable
                }
                stagedDocument = converted.value
            }
            let map: String?
            if paths.isEmpty { map = nil }
            else {
                let data = try JSONSerialization.data(withJSONObject: ["providerPaths": paths], options: .sortedKeys)
                map = String(decoding: data, as: UTF8.self)
            }
            return Snapshot(document: stagedDocument, resourceMap: map, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func containedFile(_ path: String, in root: URL) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let source = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(base.path + "/"),
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return source
    }
}
