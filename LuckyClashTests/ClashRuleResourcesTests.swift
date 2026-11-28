import CryptoKit
import Foundation
import Testing
@testable import LuckyClash

struct ClashRuleResourcesTests {
    @Test func synchronizesAndRemovesGeoSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let working = root.appendingPathComponent("matcher")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("GeoSite.dat")
        let destination = working.appendingPathComponent("GeoSite.dat")
        try Data("first".utf8).write(to: original, options: .atomic)
        let firstIdentity = try ClashRuleResources.syncGeodata(name: "GeoSite.dat", sourceDirectory: source, workingDirectory: working)
        let first = try #require(firstIdentity)
        #expect(try Data(contentsOf: destination) == Data("first".utf8))
        try Data("second".utf8).write(to: original, options: .atomic)
        let secondIdentity = try ClashRuleResources.syncGeodata(name: "GeoSite.dat", sourceDirectory: source, workingDirectory: working)
        let second = try #require(secondIdentity)
        #expect(first != second)
        #expect(try Data(contentsOf: destination) == Data("second".utf8))
        try FileManager.default.removeItem(at: original)
        #expect(try ClashRuleResources.syncGeodata(name: "GeoSite.dat", sourceDirectory: source, workingDirectory: working) == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func stagesProviderSnapshotsWithoutReadingOutsideWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let working = root.appendingPathComponent("matcher")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let address = "https://example.com/rules.yaml"
        let hash = Insecure.MD5.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data("payload: []".utf8).write(to: source.appendingPathComponent("rules/\(hash)"))
        try Data("payload: []".utf8).write(to: source.appendingPathComponent("local.yaml"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.yaml"))
        let yaml = """
        rule-providers:
          remote: {type: http, behavior: domain, url: https://example.com/rules.yaml}
          local: {type: file, behavior: domain, path: ./local.yaml}
          escape: {type: http, behavior: domain, url: https://example.com/escape, path: ../outside.yaml}
        rules: [MATCH,DIRECT]
        """
        let snapshot = try ClashRuleResources.stage(document: yaml, sourceDirectory: source, workingDirectory: working)
        let encoded = try #require(snapshot.resourceMap?.data(using: .utf8))
        let map = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: [String: String]])
        let paths = try #require(map["providerPaths"])
        #expect(paths["rule:remote"] != nil)
        #expect(paths["rule:escape"] == nil)
        #expect(snapshot.document.contains(snapshot.directory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshot.directory.path).count == 2)
    }
}
