import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LuckyClash

@MainActor
struct ProfileShareTests {
    @Test func sharesSourceURLForURLSubscriptionWithoutLoadingYAML() throws {
        let subscriptionURL = try #require(URL(string: "https://sub.example.com/api/v1/subscribe?token=abc"))
        let profile = Profile(
            id: UUID(),
            name: "机场订阅",
            nodes: [],
            selectedNodeID: UUID(),
            sourceURL: subscriptionURL,
            engine: .clash,
            clashRevision: nil
        )

        var loadedYAML = false
        let payload = try ProfileShare.payload(for: profile) { _ in
            loadedYAML = true
            return "proxies: []\n"
        }

        #expect(payload == .url(subscriptionURL))
        #expect(!loadedYAML)
        #expect(ProfileShare.actionTitle(for: profile) == "分享订阅链接")
    }

    @Test func sharesYAMLDataForNonURLProfile() throws {
        let profileID = UUID()
        let revision = UUID()
        let yaml = "proxies:\n  - name: HK\n    type: ss\n"
        try ClashTunnelStore.save(yaml, profileID: profileID, revision: revision)
        defer { ClashTunnelStore.remove(revision: revision) }

        let profile = Profile(
            id: profileID,
            name: "本地测试节点",
            nodes: [],
            selectedNodeID: UUID(),
            sourceURL: nil,
            engine: .clash,
            clashRevision: revision
        )

        let payload = try ProfileShare.payload(for: profile)
        #expect(payload == .yaml(fileName: "本地测试节点.yaml", content: yaml))
        #expect(ProfileShare.actionTitle(for: profile) == "分享 YAML 配置")
    }

    @Test func failsWhenNonURLClashProfileHasNoRevision() {
        let profile = Profile(
            id: UUID(),
            name: "缺失配置",
            nodes: [],
            selectedNodeID: UUID(),
            sourceURL: nil,
            engine: .clash,
            clashRevision: nil
        )

        #expect(throws: PrototypeError.missingConfiguration) {
            _ = try ProfileShare.payload(for: profile)
        }
    }

    @Test func sanitizesExportedYAMLFileNames() {
        #expect(ProfileShare.fileName(for: "本地测试节点") == "本地测试节点.yaml")
        #expect(ProfileShare.fileName(for: "office.yaml") == "office.yaml")
        #expect(ProfileShare.fileName(for: "office.YML") == "office.yaml")
        #expect(ProfileShare.fileName(for: "香港 / 01:备用\\节点") == "香港 - 01-备用-节点.yaml")
        #expect(ProfileShare.fileName(for: "  .hidden.  ") == "hidden.yaml")
        #expect(ProfileShare.fileName(for: "   ...   ") == "LuckyClash.yaml")
    }

    @Test func writesTemporaryYAMLFileAndCleansUpExpiredFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ProfileShareTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let expiredDir = root.appending(path: "expired", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: expiredDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1200)],
            ofItemAtPath: expiredDir.path
        )

        let freshDir = root.appending(path: "fresh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: freshDir.path
        )

        let yaml = "proxies:\n  - name: Node1\n"
        let exported = try ProfileShare.writeTemporaryYAMLFile(
            yaml,
            fileName: "测试.yaml",
            in: root,
            now: now
        )

        #expect(exported.lastPathComponent == "测试.yaml")
        #expect(try String(contentsOf: exported, encoding: .utf8) == yaml)
        #expect(!FileManager.default.fileExists(atPath: expiredDir.path))
        #expect(FileManager.default.fileExists(atPath: freshDir.path))
    }

    @Test func transferableExportsYAMLData() async throws {
        let profileID = UUID()
        let revision = UUID()
        let yaml = "proxies:\n  - name: SG\n    type: trojan\n"
        try ClashTunnelStore.save(yaml, profileID: profileID, revision: revision)
        defer { ClashTunnelStore.remove(revision: revision) }

        let profile = Profile(
            id: profileID,
            name: "新加坡节点",
            nodes: [],
            selectedNodeID: UUID(),
            sourceURL: nil,
            engine: .clash,
            clashRevision: revision
        )

        let item = ProfileYAMLTransferable(profile: profile)
        let exportedData = try await item.exported(as: .yaml)
        #expect(String(decoding: exportedData, as: UTF8.self) == yaml)
    }
}
