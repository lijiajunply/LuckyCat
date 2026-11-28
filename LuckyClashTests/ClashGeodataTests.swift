import Foundation
import Testing
@testable import LuckyClash

struct ClashGeodataTests {
    private enum TestFailure: Error { case download }

    @Test func validatesDownloadedGeodataBeforeReplacement() throws {
        // GeoIPList containing CN and 1.1.1.0/24 in protobuf form.
        let valid = Data([0x0a, 0x0e, 0x0a, 0x02, 0x43, 0x4e, 0x12, 0x08,
                          0x0a, 0x04, 0x01, 0x01, 0x01, 0x00, 0x10, 0x18])
        try ClashGeodata.validate(valid, name: ClashGeodata.geoIPFileName)
        #expect(throws: (any Error).self) {
            try ClashGeodata.validate(Data(repeating: 0x61, count: 1024), name: ClashGeodata.geoIPFileName)
        }
        #expect(throws: (any Error).self) {
            try ClashGeodata.validate(valid, name: "unexpected")
        }
    }

    @Test func detectsGeodataUsingCoreResourcePlan() {
        let dnsOnly = """
        dns:
          enable: true
          nameserver-policy:
            'geosite:cn': [223.5.5.5]
        rules:
          - MATCH,DIRECT
        """
        #expect(ClashGeodata.requirements(for: dnsOnly).map(\.kind) == ["geosite"])
        let ipDat = "geodata-mode: true\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,DIRECT"
        let ipDatabase = "geodata-mode: false\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,DIRECT"
        #expect(ClashGeodata.requirements(for: ipDat).first?.format == "dat")
        #expect(ClashGeodata.requirements(for: ipDatabase).first?.format == "mmdb")
        #expect(!ClashGeodata.isRequired("# GEOIP,CN,DIRECT\nrules:\n  - MATCH,DIRECT"))
    }

    @Test func automaticUpdateKeepsUsableResourceButExplicitUpdateReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(ClashGeodata.geoIPFileName)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = Data([0x0a, 0x0e, 0x0a, 0x02, 0x43, 0x4e, 0x12, 0x08,
                          0x0a, 0x04, 0x01, 0x01, 0x01, 0x00, 0x10, 0x18])
        var old = Data()
        for _ in 0..<7000 { old.append(entry) }
        try old.write(to: file)
        try await ClashGeodata.install(destination: file, canUseExistingOnFailure: true) {
            throw TestFailure.download
        }
        #expect(try Data(contentsOf: file) == old)
        do {
            try await ClashGeodata.install(destination: file, canUseExistingOnFailure: false) {
                throw TestFailure.download
            }
            Issue.record("An explicit update must report download failure")
        } catch TestFailure.download { }
        #expect(try Data(contentsOf: file) == old)
        try Data(repeating: 0x42, count: 110 * 1024).write(to: file, options: .atomic)
        do {
            try await ClashGeodata.install(destination: file, canUseExistingOnFailure: true) {
                throw TestFailure.download
            }
            Issue.record("Corrupt cached data must not satisfy the update")
        } catch TestFailure.download { }
        try FileManager.default.removeItem(at: file)
        do {
            try await ClashGeodata.install(destination: file, canUseExistingOnFailure: true) {
                throw TestFailure.download
            }
            Issue.record("A missing resource cannot satisfy the update")
        } catch TestFailure.download { }
    }
}
